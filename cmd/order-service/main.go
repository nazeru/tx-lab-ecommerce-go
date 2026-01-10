package main

import (
	"bytes"
	"context"
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
	segmentkafka "github.com/segmentio/kafka-go"

	"github.com/nazeru/tx-lab-ecommerce-go/pkg/idempotency"
	"github.com/nazeru/tx-lab-ecommerce-go/pkg/kafka"
	"github.com/nazeru/tx-lab-ecommerce-go/pkg/logging"
	"github.com/nazeru/tx-lab-ecommerce-go/pkg/metrics"
	"github.com/nazeru/tx-lab-ecommerce-go/pkg/outbox"
)

var errIdempotencyRace = errors.New("idempotency race")

type cfg struct {
	Port                string
	DatabaseURL         string
	TxMode              string // twopc | none
	RequestTimeout      time.Duration
	Mock2PCParticipants bool
	InventoryBaseURL    string
	PaymentBaseURL      string
	ShippingBaseURL     string
	KafkaBrokers        string
	KafkaTopic          string
	OutboxPollInterval  time.Duration
	OutboxBatchSize     int
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
	outboxPollMS, _ := strconv.Atoi(getenv("OUTBOX_POLL_MS", "500"))
	outboxBatch, _ := strconv.Atoi(getenv("OUTBOX_BATCH", "100"))

	return cfg{
		Port:                port,
		DatabaseURL:         db,
		TxMode:              mode,
		RequestTimeout:      time.Duration(toutMS) * time.Millisecond,
		Mock2PCParticipants: mock == "1" || mock == "true" || mock == "yes",
		InventoryBaseURL:    strings.TrimRight(getenv("INVENTORY_BASE_URL", ""), "/"),
		PaymentBaseURL:      strings.TrimRight(getenv("PAYMENT_BASE_URL", ""), "/"),
		ShippingBaseURL:     strings.TrimRight(getenv("SHIPPING_BASE_URL", ""), "/"),
		KafkaBrokers:        getenv("KAFKA_BROKERS", ""),
		KafkaTopic:          getenv("KAFKA_TOPIC", "txlab.events"),
		OutboxPollInterval:  time.Duration(outboxPollMS) * time.Millisecond,
		OutboxBatchSize:     outboxBatch,
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

type Event struct {
	EventID string         `json:"event_id"`
	TxID    string         `json:"txid"`
	OrderID string         `json:"order_id"`
	Type    string         `json:"type"`
	Payload map[string]any `json:"payload"`
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
	kafkaClient := kafka.NewClient(cfg.KafkaBrokers)
	if kafkaClient.Enabled() {
		startOutboxRelay(context.Background(), pool, kafkaClient, cfg)
	}

	srvMetrics := metrics.NewServerMetrics("order_service")
	mux := http.NewServeMux()
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"status":"ok"}`))
		srvMetrics.Requests.WithLabelValues("health", "200").Inc()
		srvMetrics.LatencyMS.WithLabelValues("health").Observe(float64(time.Since(start).Milliseconds()))
	})
	mux.Handle("/metrics", metrics.Handler())
	mux.HandleFunc("/checkout", func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		if r.Method != http.MethodPost {
			writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"error": "method not allowed"})
			srvMetrics.Requests.WithLabelValues("checkout", "405").Inc()
			srvMetrics.LatencyMS.WithLabelValues("checkout").Observe(float64(time.Since(start).Milliseconds()))
			return
		}
		var req CheckoutRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]any{"error": "invalid json"})
			srvMetrics.Requests.WithLabelValues("checkout", "400").Inc()
			srvMetrics.LatencyMS.WithLabelValues("checkout").Observe(float64(time.Since(start).Milliseconds()))
			return
		}
		if len(req.Items) == 0 {
			writeJSON(w, http.StatusBadRequest, map[string]any{"error": "items is required"})
			srvMetrics.Requests.WithLabelValues("checkout", "400").Inc()
			srvMetrics.LatencyMS.WithLabelValues("checkout").Observe(float64(time.Since(start).Milliseconds()))
			return
		}
		if req.Total < 0 {
			writeJSON(w, http.StatusBadRequest, map[string]any{"error": "total must be >= 0"})
			srvMetrics.Requests.WithLabelValues("checkout", "400").Inc()
			srvMetrics.LatencyMS.WithLabelValues("checkout").Observe(float64(time.Since(start).Milliseconds()))
			return
		}
		for _, it := range req.Items {
			if strings.TrimSpace(it.ProductID) == "" || it.Quantity <= 0 {
				writeJSON(w, http.StatusBadRequest, map[string]any{"error": "each item must have product_id and quantity > 0"})
				srvMetrics.Requests.WithLabelValues("checkout", "400").Inc()
				srvMetrics.LatencyMS.WithLabelValues("checkout").Observe(float64(time.Since(start).Milliseconds()))
				return
			}
		}

		orderID := strings.TrimSpace(req.OrderID)
		if orderID == "" {
			orderID = uuid.NewString()
		}

		idemKey := idempotency.Key(r)
		ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
		defer cancel()

		// Идемпотентность: если ключ уже есть, вернём существующий order_id.
		if idemKey != "" {
			if existing, err := getOrderByIdempotency(ctx, pool, idemKey); err == nil && existing != "" {
				logging.Log(logging.Fields{
					Service:    "order-service",
					OrderID:    existing,
					Step:       "checkout",
					Status:     "idempotent_replay",
					DurationMS: time.Since(start).Milliseconds(),
				})
				writeJSON(w, http.StatusOK, CheckoutResponse{OrderID: existing, Status: "IDEMPOTENT_REPLAY"})
				srvMetrics.Requests.WithLabelValues("checkout", "200").Inc()
				srvMetrics.LatencyMS.WithLabelValues("checkout").Observe(float64(time.Since(start).Milliseconds()))
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
					logging.Log(logging.Fields{
						Service:    "order-service",
						OrderID:    existing,
						Step:       "checkout",
						Status:     "idempotent_race",
						DurationMS: time.Since(start).Milliseconds(),
					})
					writeJSON(w, http.StatusOK, CheckoutResponse{OrderID: existing, Status: "IDEMPOTENT_REPLAY"})
					srvMetrics.Requests.WithLabelValues("checkout", "200").Inc()
					srvMetrics.LatencyMS.WithLabelValues("checkout").Observe(float64(time.Since(start).Milliseconds()))
					return
				}
			}
			writeJSON(w, http.StatusInternalServerError, map[string]any{"error": err.Error()})
			srvMetrics.Requests.WithLabelValues("checkout", "500").Inc()
			srvMetrics.LatencyMS.WithLabelValues("checkout").Observe(float64(time.Since(start).Milliseconds()))
			return
		}

		// 2) Non-2PC modes
		switch strings.ToLower(cfg.TxMode) {
		case "tcc":
			txid := uuid.NewString()
			if err := runTCC(ctx, client, pool, cfg, txid, orderID, req); err != nil {
				_ = updateOrderStatus(ctx, pool, orderID, "REJECTED")
				logging.Log(logging.Fields{
					Service:    "order-service",
					TxID:       txid,
					OrderID:    orderID,
					Step:       "tcc",
					Status:     "rejected",
					DurationMS: time.Since(start).Milliseconds(),
				})
				writeJSON(w, http.StatusBadGateway, CheckoutResponse{OrderID: orderID, TxID: txid, Status: "REJECTED"})
				srvMetrics.Requests.WithLabelValues("checkout", "502").Inc()
				srvMetrics.LatencyMS.WithLabelValues("checkout").Observe(float64(time.Since(start).Milliseconds()))
				return
			}
			_ = updateOrderStatus(ctx, pool, orderID, "CONFIRMED")
			logging.Log(logging.Fields{
				Service:    "order-service",
				TxID:       txid,
				OrderID:    orderID,
				Step:       "tcc",
				Status:     "confirmed",
				DurationMS: time.Since(start).Milliseconds(),
			})
			writeJSON(w, http.StatusOK, CheckoutResponse{OrderID: orderID, TxID: txid, Status: "CONFIRMED"})
			srvMetrics.Requests.WithLabelValues("checkout", "200").Inc()
			srvMetrics.LatencyMS.WithLabelValues("checkout").Observe(float64(time.Since(start).Milliseconds()))
			return
		case "saga-orch":
			txid := uuid.NewString()
			if err := runSagaOrch(ctx, client, pool, cfg, txid, orderID, req); err != nil {
				_ = updateOrderStatus(ctx, pool, orderID, "REJECTED")
				logging.Log(logging.Fields{
					Service:    "order-service",
					TxID:       txid,
					OrderID:    orderID,
					Step:       "saga_orch",
					Status:     "rejected",
					DurationMS: time.Since(start).Milliseconds(),
				})
				writeJSON(w, http.StatusBadGateway, CheckoutResponse{OrderID: orderID, TxID: txid, Status: "REJECTED"})
				srvMetrics.Requests.WithLabelValues("checkout", "502").Inc()
				srvMetrics.LatencyMS.WithLabelValues("checkout").Observe(float64(time.Since(start).Milliseconds()))
				return
			}
			_ = updateOrderStatus(ctx, pool, orderID, "CONFIRMED")
			logging.Log(logging.Fields{
				Service:    "order-service",
				TxID:       txid,
				OrderID:    orderID,
				Step:       "saga_orch",
				Status:     "confirmed",
				DurationMS: time.Since(start).Milliseconds(),
			})
			writeJSON(w, http.StatusOK, CheckoutResponse{OrderID: orderID, TxID: txid, Status: "CONFIRMED"})
			srvMetrics.Requests.WithLabelValues("checkout", "200").Inc()
			srvMetrics.LatencyMS.WithLabelValues("checkout").Observe(float64(time.Since(start).Milliseconds()))
			return
		case "saga-chor":
			txid := uuid.NewString()
			if err := enqueueOrderEvent(ctx, pool, cfg, txid, orderID, "OrderCreated", req); err != nil {
				writeJSON(w, http.StatusInternalServerError, map[string]any{"error": err.Error()})
				srvMetrics.Requests.WithLabelValues("checkout", "500").Inc()
				srvMetrics.LatencyMS.WithLabelValues("checkout").Observe(float64(time.Since(start).Milliseconds()))
				return
			}
			_ = updateOrderStatus(ctx, pool, orderID, "PENDING")
			logging.Log(logging.Fields{
				Service:    "order-service",
				TxID:       txid,
				OrderID:    orderID,
				Step:       "saga_chor",
				Status:     "pending",
				DurationMS: time.Since(start).Milliseconds(),
			})
			writeJSON(w, http.StatusOK, CheckoutResponse{OrderID: orderID, TxID: txid, Status: "PENDING"})
			srvMetrics.Requests.WithLabelValues("checkout", "200").Inc()
			srvMetrics.LatencyMS.WithLabelValues("checkout").Observe(float64(time.Since(start).Milliseconds()))
			return
		case "outbox":
			txid := uuid.NewString()
			if err := enqueueOrderEvent(ctx, pool, cfg, txid, orderID, "OrderConfirmed", req); err != nil {
				writeJSON(w, http.StatusInternalServerError, map[string]any{"error": err.Error()})
				srvMetrics.Requests.WithLabelValues("checkout", "500").Inc()
				srvMetrics.LatencyMS.WithLabelValues("checkout").Observe(float64(time.Since(start).Milliseconds()))
				return
			}
			_ = updateOrderStatus(ctx, pool, orderID, "CONFIRMED")
			logging.Log(logging.Fields{
				Service:    "order-service",
				TxID:       txid,
				OrderID:    orderID,
				Step:       "outbox",
				Status:     "confirmed",
				DurationMS: time.Since(start).Milliseconds(),
			})
			writeJSON(w, http.StatusOK, CheckoutResponse{OrderID: orderID, TxID: txid, Status: "CONFIRMED"})
			srvMetrics.Requests.WithLabelValues("checkout", "200").Inc()
			srvMetrics.LatencyMS.WithLabelValues("checkout").Observe(float64(time.Since(start).Milliseconds()))
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
			logging.Log(logging.Fields{
				Service:    "order-service",
				TxID:       txid,
				OrderID:    orderID,
				Step:       "twopc",
				Status:     "aborted",
				DurationMS: time.Since(start).Milliseconds(),
			})
			writeJSON(w, http.StatusBadGateway, CheckoutResponse{OrderID: orderID, TxID: txid, Status: "ABORTED"})
			srvMetrics.Requests.WithLabelValues("checkout", "502").Inc()
			srvMetrics.LatencyMS.WithLabelValues("checkout").Observe(float64(time.Since(start).Milliseconds()))
			return
		}

		_ = updateTxStatus(ctx, pool, txid, "COMMITTING")
		if !cfg.Mock2PCParticipants {
			if err := twopcCommit(ctx, client, txid, orderID, participants); err != nil {
				_ = updateTxStatus(ctx, pool, txid, "ABORTING")
				_ = twopcAbort(ctx, client, txid, orderID, participants)
				_ = updateOrderStatus(ctx, pool, orderID, "REJECTED")
				_ = updateTxStatus(ctx, pool, txid, "ABORTED")
				logging.Log(logging.Fields{
					Service:    "order-service",
					TxID:       txid,
					OrderID:    orderID,
					Step:       "twopc",
					Status:     "abort_after_commit_fail",
					DurationMS: time.Since(start).Milliseconds(),
				})
				writeJSON(w, http.StatusBadGateway, CheckoutResponse{OrderID: orderID, TxID: txid, Status: "ABORTED"})
				srvMetrics.Requests.WithLabelValues("checkout", "502").Inc()
				srvMetrics.LatencyMS.WithLabelValues("checkout").Observe(float64(time.Since(start).Milliseconds()))
				return
			}
		}

		_ = updateOrderStatus(ctx, pool, orderID, "CONFIRMED")
		_ = updateTxStatus(ctx, pool, txid, "COMMITTED")
		logging.Log(logging.Fields{
			Service:    "order-service",
			TxID:       txid,
			OrderID:    orderID,
			Step:       "twopc",
			Status:     "committed",
			DurationMS: time.Since(start).Milliseconds(),
		})
		writeJSON(w, http.StatusOK, CheckoutResponse{OrderID: orderID, TxID: txid, Status: "COMMITTED"})
		srvMetrics.Requests.WithLabelValues("checkout", "200").Inc()
		srvMetrics.LatencyMS.WithLabelValues("checkout").Observe(float64(time.Since(start).Milliseconds()))
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
			`INSERT INTO order_items(order_id, product_id, quantity) VALUES($1, $2, $3)`,
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
			`INSERT INTO twopc_tx_log(txid, order_id, status, participants) VALUES($1, $2, $3, $4)`,
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

type tccStep struct {
	Name string
	URL  string
	Step string
}

func buildTCCSteps(cfg cfg) []tccStep {
	var steps []tccStep
	if cfg.InventoryBaseURL != "" {
		steps = append(steps, tccStep{Name: "inventory", URL: cfg.InventoryBaseURL, Step: "reserve_inventory"})
	}
	if cfg.PaymentBaseURL != "" {
		steps = append(steps, tccStep{Name: "payment", URL: cfg.PaymentBaseURL, Step: "charge_payment"})
	}
	if cfg.ShippingBaseURL != "" {
		steps = append(steps, tccStep{Name: "shipping", URL: cfg.ShippingBaseURL, Step: "arrange_shipping"})
	}
	return steps
}

func runTCC(ctx context.Context, client *http.Client, pool *pgxpool.Pool, cfg cfg, txid, orderID string, req CheckoutRequest) error {
	steps := buildTCCSteps(cfg)
	body := func(step string) map[string]any {
		return map[string]any{"txid": txid, "order_id": orderID, "step": step, "items": req.Items, "total": req.Total}
	}
	var completed []tccStep
	for _, step := range steps {
		if err := postJSON(ctx, client, step.URL+"/tcc/try", body(step.Step)); err != nil {
			_ = compensateTCC(ctx, client, completed, txid, orderID)
			return fmt.Errorf("tcc try failed for %s: %w", step.Name, err)
		}
		completed = append(completed, step)
	}
	for _, step := range completed {
		if err := postJSON(ctx, client, step.URL+"/tcc/confirm", body(step.Step)); err != nil {
			_ = compensateTCC(ctx, client, completed, txid, orderID)
			return fmt.Errorf("tcc confirm failed for %s: %w", step.Name, err)
		}
	}
	_ = enqueueOrderEvent(ctx, pool, cfg, txid, orderID, "OrderConfirmed", req)
	return nil
}

func compensateTCC(ctx context.Context, client *http.Client, steps []tccStep, txid, orderID string) error {
	for i := len(steps) - 1; i >= 0; i-- {
		step := steps[i]
		body := map[string]any{"txid": txid, "order_id": orderID, "step": step.Step}
		_ = postJSON(ctx, client, step.URL+"/tcc/cancel", body)
	}
	return nil
}

func runSagaOrch(ctx context.Context, client *http.Client, pool *pgxpool.Pool, cfg cfg, txid, orderID string, req CheckoutRequest) error {
	steps := buildTCCSteps(cfg)
	body := func(step string) map[string]any {
		return map[string]any{"txid": txid, "order_id": orderID, "step": "saga_orch_" + step, "items": req.Items, "total": req.Total}
	}
	var completed []tccStep
	for _, step := range steps {
		if err := postJSON(ctx, client, step.URL+"/tcc/try", body(step.Step)); err != nil {
			_ = compensateSaga(ctx, client, completed, txid, orderID)
			return fmt.Errorf("saga action failed for %s: %w", step.Name, err)
		}
		completed = append(completed, step)
	}
	_ = enqueueOrderEvent(ctx, pool, cfg, txid, orderID, "OrderConfirmed", req)
	return nil
}

func compensateSaga(ctx context.Context, client *http.Client, steps []tccStep, txid, orderID string) error {
	for i := len(steps) - 1; i >= 0; i-- {
		step := steps[i]
		body := map[string]any{"txid": txid, "order_id": orderID, "step": "saga_orch_" + step.Step}
		_ = postJSON(ctx, client, step.URL+"/tcc/cancel", body)
	}
	return nil
}

func enqueueOrderEvent(ctx context.Context, pool *pgxpool.Pool, cfg cfg, txid, orderID, eventType string, req CheckoutRequest) error {
	payload := map[string]any{
		"items": req.Items,
		"total": req.Total,
	}
	eventID := uuid.NewString()
	event := Event{
		EventID: eventID,
		TxID:    txid,
		OrderID: orderID,
		Type:    eventType,
		Payload: payload,
	}
	return outbox.Insert(ctx, pool, eventID, cfg.KafkaTopic, orderID, event)
}

func startOutboxRelay(ctx context.Context, pool *pgxpool.Pool, client *kafka.Client, cfg cfg) {
	writer := client.NewWriter(cfg.KafkaTopic)
	go func() {
		ticker := time.NewTicker(cfg.OutboxPollInterval)
		defer ticker.Stop()
		defer writer.Close()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				records, err := outbox.FetchPending(ctx, pool, cfg.OutboxBatchSize)
				if err != nil {
					log.Printf("outbox fetch error: %v", err)
					continue
				}
				for _, rec := range records {
					msg := segmentkafka.Message{Key: []byte(rec.Key), Value: rec.Payload, Time: time.Now().UTC()}
					if err := writer.WriteMessages(ctx, msg); err != nil {
						log.Printf("outbox publish error: %v", err)
						break
					}
					_ = outbox.MarkSent(ctx, pool, rec.ID)
				}
			}
		}
	}()
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
