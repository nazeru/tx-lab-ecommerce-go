package main

import (
	"context"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

var errIdempotencyRace = errors.New("idempotency race")

type cfg struct {
	Port              string
	DatabaseURL        string
	TxMode             string // twopc | none
	RequestTimeout     time.Duration
	Mock2PCParticipants bool
	InventoryBaseURL   string
	PaymentBaseURL     string
	ShippingBaseURL    string
}

func readCfg() (cfg, error) {
	port := getenv("PORT", "8080")
	db := strings.TrimSpace(os.Getenv("DATABASE_URL"))
	if db == "" {
		return cfg{}, errors.New("DATABASE_URL is required")
	}
	mode := getenv("TX_MODE", "twopc")
	toutMS, _ := strconv.Atoi(getenv("REQUEST_TIMEOUT_MS", "2500"))
	mock := strings.ToLower(getenv("MOCK_2PC", "true"))

	return cfg{
		Port:               port,
		DatabaseURL:         db,
		TxMode:              mode,
		RequestTimeout:      time.Duration(toutMS) * time.Millisecond,
		Mock2PCParticipants: mock == "1" || mock == "true" || mock == "yes",
		InventoryBaseURL:    strings.TrimRight(getenv("INVENTORY_BASE_URL", ""), "/"),
		PaymentBaseURL:      strings.TrimRight(getenv("PAYMENT_BASE_URL", ""), "/"),
		ShippingBaseURL:     strings.TrimRight(getenv("SHIPPING_BASE_URL", ""), "/"),
	}, nil
}

type Item struct {
	ProductID string `json:"product_id"`
	Quantity  int    `json:"quantity"`
}

type CheckoutRequest struct {
	OrderID string `json:"order_id"`
	Items   []Item `json:"items"`
	Total   int64  `json:"total"`
}

type CheckoutResponse struct {
	OrderID string `json:"order_id"`
	TxID    string `json:"txid,omitempty"`
	Status  string `json:"status"`
}

func main() {
	cfg, err := readCfg()
	if err != nil {
		log.Fatalf("config error: %v", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	pool, err := pgxpool.New(ctx, cfg.DatabaseURL)
	if err != nil {
		log.Fatalf("db connect error: %v", err)
	}
	defer pool.Close()

	// smoke-check DB
	if err := pingDB(ctx, pool); err != nil {
		log.Fatalf("db ping error: %v", err)
	}

	client := &http.Client{Timeout: cfg.RequestTimeout}

	mux := http.NewServeMux()
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"status":"ok"}`))
	})
	mux.HandleFunc("/checkout", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"error": "method not allowed"})
			return
		}
		var req CheckoutRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]any{"error": "invalid json"})
			return
		}
		if len(req.Items) == 0 {
			writeJSON(w, http.StatusBadRequest, map[string]any{"error": "items is required"})
			return
		}
		if req.Total < 0 {
			writeJSON(w, http.StatusBadRequest, map[string]any{"error": "total must be >= 0"})
			return
		}
		for _, it := range req.Items {
			if strings.TrimSpace(it.ProductID) == "" || it.Quantity <= 0 {
				writeJSON(w, http.StatusBadRequest, map[string]any{"error": "each item must have product_id and quantity > 0"})
				return
			}
		}

		orderID := strings.TrimSpace(req.OrderID)
		if orderID == "" {
			orderID = uuid.NewString()
		}

		idemKey := strings.TrimSpace(r.Header.Get("Idempotency-Key"))
		ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
		defer cancel()

		// Идемпотентность: если ключ уже есть, вернём существующий order_id.
		if idemKey != "" {
			if existing, err := getOrderByIdempotency(ctx, pool, idemKey); err == nil && existing != "" {
				writeJSON(w, http.StatusOK, CheckoutResponse{OrderID: existing, Status: "IDEMPOTENT_REPLAY"})
				return
			}
		}

		// 1) Создаём заказ + позиции + (опционально) лог 2PC (STARTED)
		txid := ""
		if strings.EqualFold(cfg.TxMode, "twopc") {
			txid = uuid.NewString()
		}

		if err := createOrder(ctx, pool, orderID, idemKey, req.Items, req.Total, txid, cfg); err != nil {
			if errors.Is(err, errIdempotencyRace) && idemKey != "" {
				if existing, qerr := getOrderByIdempotency(ctx, pool, idemKey); qerr == nil && existing != "" {
					writeJSON(w, http.StatusOK, CheckoutResponse{OrderID: existing, Status: "IDEMPOTENT_REPLAY"})
					return
				}
			}
			writeJSON(w, http.StatusInternalServerError, map[string]any{"error": err.Error()})
			return
		}

		// 2) Если не 2PC — сразу подтверждаем
		if !strings.EqualFold(cfg.TxMode, "twopc") {
			_ = updateOrderStatus(ctx, pool, orderID, "CONFIRMED")
			writeJSON(w, http.StatusOK, CheckoutResponse{OrderID: orderID, Status: "CONFIRMED"})
			return
		}

		// 3) 2PC: prepare -> commit/abort
		participants := buildParticipants(cfg)
		_ = updateTxStatus(ctx, pool, txid, "PREPARING")

		ok := true
		if !cfg.Mock2PCParticipants {
			ok = twopcPrepare(ctx, client, txid, orderID, req, participants)
		}

		if !ok {
			_ = updateTxStatus(ctx, pool, txid, "ABORTING")
			if !cfg.Mock2PCParticipants {
				_ = twopcAbort(ctx, client, txid, orderID, participants)
			}
			_ = updateOrderStatus(ctx, pool, orderID, "REJECTED")
			_ = updateTxStatus(ctx, pool, txid, "ABORTED")
			writeJSON(w, http.StatusBadGateway, CheckoutResponse{OrderID: orderID, TxID: txid, Status: "ABORTED"})
			return
		}

		_ = updateTxStatus(ctx, pool, txid, "COMMITTING")
		if !cfg.Mock2PCParticipants {
			if err := twopcCommit(ctx, client, txid, orderID, participants); err != nil {
				_ = updateTxStatus(ctx, pool, txid, "ABORTING")
				_ = twopcAbort(ctx, client, txid, orderID, participants)
				_ = updateOrderStatus(ctx, pool, orderID, "REJECTED")
				_ = updateTxStatus(ctx, pool, txid, "ABORTED")
				writeJSON(w, http.StatusBadGateway, CheckoutResponse{OrderID: orderID, TxID: txid, Status: "ABORTED"})
				return
			}
		}

		_ = updateOrderStatus(ctx, pool, orderID, "CONFIRMED")
		_ = updateTxStatus(ctx, pool, txid, "COMMITTED")
		writeJSON(w, http.StatusOK, CheckoutResponse{OrderID: orderID, TxID: txid, Status: "COMMITTED"})
	})

	srv := &http.Server{
		Addr:              ":" + cfg.Port,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}

	log.Printf("order-service listening on :%s (TX_MODE=%s, MOCK_2PC=%v)", cfg.Port, cfg.TxMode, cfg.Mock2PCParticipants)
	if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatalf("http server error: %v", err)
	}
}

func pingDB(ctx context.Context, pool *pgxpool.Pool) error {
	ctx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	return pool.Ping(ctx)
}

func createOrder(ctx context.Context, pool *pgxpool.Pool, orderID, idemKey string, items []Item, total int64, txid string, cfg cfg) error {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	tx, err := pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback(ctx) }()

	_, err = tx.Exec(ctx,
		`INSERT INTO orders(id, status, total) VALUES($1, $2, $3)`,
		orderID, "PROCESSING", total,
	)
	if err != nil {
		return err
	}

	for _, it := range items {
		_, err = tx.Exec(ctx,
			`INSERT INTO order_items(order_id, product_id, quantity) VALUES($1, $2, $3)` ,
			orderID, it.ProductID, it.Quantity,
		)
		if err != nil {
			return err
		}
	}

	if idemKey != "" {
		_, err = tx.Exec(ctx,
			`INSERT INTO order_idempotency(idempotency_key, order_id) VALUES($1, $2)`,
			idemKey, orderID,
		)
		if err != nil {
			// конфликт — значит повтор (в другой реплике) или гонка.
			if isUniqueViolation(err) {
				return errIdempotencyRace
			}
			return err
		}
	}

	if txid != "" {
		parts := buildParticipants(cfg)
		participantsJSON, _ := json.Marshal(parts)
		_, err = tx.Exec(ctx,
			`INSERT INTO twopc_tx_log(txid, order_id, status, participants) VALUES($1, $2, $3, $4)` ,
			txid, orderID, "STARTED", participantsJSON,
		)
		if err != nil {
			return err
		}
	}

	if err := tx.Commit(ctx); err != nil {
		return err
	}
	return nil
}

func getOrderByIdempotency(ctx context.Context, pool *pgxpool.Pool, key string) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	var orderID string
	err := pool.QueryRow(ctx, `SELECT order_id FROM order_idempotency WHERE idempotency_key=$1`, key).Scan(&orderID)
	if err != nil {
		return "", err
	}
	return orderID, nil
}

func updateOrderStatus(ctx context.Context, pool *pgxpool.Pool, orderID, status string) error {
	_, err := pool.Exec(ctx, `UPDATE orders SET status=$2, updated_at=now() WHERE id=$1`, orderID, status)
	return err
}

func updateTxStatus(ctx context.Context, pool *pgxpool.Pool, txid, status string) error {
	_, err := pool.Exec(ctx, `UPDATE twopc_tx_log SET status=$2, updated_at=now() WHERE txid=$1`, txid, status)
	return err
}

type participant struct {
	Name string `json:"name"`
	URL  string `json:"url"`
}

func buildParticipants(cfg cfg) []participant {
	var ps []participant
	if cfg.InventoryBaseURL != "" {
		ps = append(ps, participant{Name: "inventory", URL: cfg.InventoryBaseURL})
	}
	if cfg.PaymentBaseURL != "" {
		ps = append(ps, participant{Name: "payment", URL: cfg.PaymentBaseURL})
	}
	if cfg.ShippingBaseURL != "" {
		ps = append(ps, participant{Name: "shipping", URL: cfg.ShippingBaseURL})
	}
	return ps
}

func twopcPrepare(ctx context.Context, client *http.Client, txid, orderID string, req CheckoutRequest, participants []participant) bool {
	body := map[string]any{"txid": txid, "order_id": orderID, "items": req.Items, "total": req.Total}
	for _, p := range participants {
		if err := postJSON(ctx, client, p.URL+"/2pc/prepare", body); err != nil {
			log.Printf("2PC prepare failed for %s: %v", p.Name, err)
			return false
		}
	}
	return true
}

func twopcCommit(ctx context.Context, client *http.Client, txid, orderID string, participants []participant) error {
	body := map[string]any{"txid": txid, "order_id": orderID}
	for _, p := range participants {
		if err := postJSON(ctx, client, p.URL+"/2pc/commit", body); err != nil {
			return fmt.Errorf("commit failed for %s: %w", p.Name, err)
		}
	}
	return nil
}

func twopcAbort(ctx context.Context, client *http.Client, txid, orderID string, participants []participant) error {
	body := map[string]any{"txid": txid, "order_id": orderID}
	for _, p := range participants {
		_ = postJSON(ctx, client, p.URL+"/2pc/abort", body)
	}
	return nil
}

func postJSON(ctx context.Context, client *http.Client, url string, body any) error {
	data, _ := json.Marshal(body)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(data))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("status %d", resp.StatusCode)
	}
	return nil
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

func getenv(k, def string) string {
	v := strings.TrimSpace(os.Getenv(k))
	if v == "" {
		return def
	}
	return v
}

// isUniqueViolation: минимальная проверка на нарушение UNIQUE.
// Для pgx это может быть *pgconn.PgError с Code "23505", но в демо достаточно строки.
func isUniqueViolation(err error) bool {
	if err == nil {
		return false
	}
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) {
		return pgErr.Code == "23505"
	}
	// fallback
	if strings.Contains(strings.ToLower(err.Error()), "duplicate") || strings.Contains(strings.ToLower(err.Error()), "unique") {
		return true
	}
	return false
}
