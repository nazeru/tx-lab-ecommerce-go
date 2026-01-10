package main

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/nazeru/tx-lab-ecommerce-go/pkg/logging"
	"github.com/nazeru/tx-lab-ecommerce-go/pkg/metrics"
)

type cfg struct {
	Port        string
	DatabaseURL string
}

type PrepareRequest struct {
	TxID    string `json:"txid"`
	OrderID string `json:"order_id"`
	Total   int64  `json:"total"`
}

type TCCRequest struct {
	TxID    string `json:"txid"`
	OrderID string `json:"order_id"`
	Step    string `json:"step"`
	Amount  int64  `json:"amount"`
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

	srvMetrics := metrics.NewServerMetrics("payment_service")

	mux := http.NewServeMux()
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		if err := pool.Ping(r.Context()); err != nil {
			writeJSON(w, http.StatusServiceUnavailable, map[string]any{"status": "db_error"})
			srvMetrics.Requests.WithLabelValues("health", "503").Inc()
			srvMetrics.LatencyMS.WithLabelValues("health").Observe(float64(time.Since(start).Milliseconds()))
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"status": "ok"})
		srvMetrics.Requests.WithLabelValues("health", "200").Inc()
		srvMetrics.LatencyMS.WithLabelValues("health").Observe(float64(time.Since(start).Milliseconds()))
	})
	mux.Handle("/metrics", metrics.Handler())

	mux.HandleFunc("/2pc/prepare", func(w http.ResponseWriter, r *http.Request) {
		handle2PC(pool, srvMetrics, "prepare", w, r)
	})
	mux.HandleFunc("/2pc/commit", func(w http.ResponseWriter, r *http.Request) {
		handle2PC(pool, srvMetrics, "commit", w, r)
	})
	mux.HandleFunc("/2pc/abort", func(w http.ResponseWriter, r *http.Request) {
		handle2PC(pool, srvMetrics, "abort", w, r)
	})

	mux.HandleFunc("/tcc/try", func(w http.ResponseWriter, r *http.Request) {
		handleTCC(pool, srvMetrics, "try", w, r)
	})
	mux.HandleFunc("/tcc/confirm", func(w http.ResponseWriter, r *http.Request) {
		handleTCC(pool, srvMetrics, "confirm", w, r)
	})
	mux.HandleFunc("/tcc/cancel", func(w http.ResponseWriter, r *http.Request) {
		handleTCC(pool, srvMetrics, "cancel", w, r)
	})

	srv := &http.Server{Addr: ":" + cfg.Port, Handler: mux, ReadHeaderTimeout: 5 * time.Second}
	log.Printf("payment-service listening on :%s", cfg.Port)
	log.Fatal(srv.ListenAndServe())
}

func readCfg() (cfg, error) {
	port := getenv("PORT", "8080")
	db := strings.TrimSpace(os.Getenv("DATABASE_URL"))
	if db == "" {
		return cfg{}, errors.New("DATABASE_URL is required")
	}
	return cfg{Port: port, DatabaseURL: db}, nil
}

func handle2PC(pool *pgxpool.Pool, metrics *metrics.ServerMetrics, action string, w http.ResponseWriter, r *http.Request) {
	start := time.Now()
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"error": "method not allowed"})
		metrics.Requests.WithLabelValues("2pc_"+action, "405").Inc()
		metrics.LatencyMS.WithLabelValues("2pc_" + action).Observe(float64(time.Since(start).Milliseconds()))
		return
	}

	var req PrepareRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "invalid json"})
		metrics.Requests.WithLabelValues("2pc_"+action, "400").Inc()
		metrics.LatencyMS.WithLabelValues("2pc_" + action).Observe(float64(time.Since(start).Milliseconds()))
		return
	}

	switch action {
	case "prepare":
		if err := preparePayment(r.Context(), pool, req); err != nil {
			writeJSON(w, http.StatusConflict, map[string]any{"error": err.Error()})
			metrics.Requests.WithLabelValues("2pc_"+action, "409").Inc()
			metrics.LatencyMS.WithLabelValues("2pc_" + action).Observe(float64(time.Since(start).Milliseconds()))
			return
		}
		logging.Log(logging.Fields{Service: "payment-service", TxID: req.TxID, OrderID: req.OrderID, Step: "2pc_prepare", Status: "prepared"})
	case "commit":
		_ = update2PCStatus(r.Context(), pool, req.TxID, "COMMITTED")
		logging.Log(logging.Fields{Service: "payment-service", TxID: req.TxID, OrderID: req.OrderID, Step: "2pc_commit", Status: "committed"})
	case "abort":
		_ = update2PCStatus(r.Context(), pool, req.TxID, "ABORTED")
		logging.Log(logging.Fields{Service: "payment-service", TxID: req.TxID, OrderID: req.OrderID, Step: "2pc_abort", Status: "aborted"})
	}

	writeJSON(w, http.StatusOK, map[string]any{"status": "ok"})
	metrics.Requests.WithLabelValues("2pc_"+action, "200").Inc()
	metrics.LatencyMS.WithLabelValues("2pc_" + action).Observe(float64(time.Since(start).Milliseconds()))
}

func preparePayment(ctx context.Context, pool *pgxpool.Pool, req PrepareRequest) error {
	tx, err := pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback(ctx) }()

	_, err = tx.Exec(ctx, `INSERT INTO twopc_prepared_tx(txid, order_id, step, status, payload)
		VALUES ($1, $2, 'authorize_payment', 'PREPARED', $3)
		ON CONFLICT (txid) DO NOTHING`, req.TxID, req.OrderID, jsonPayload(req))
	if err != nil {
		return err
	}

	_, err = tx.Exec(ctx, `INSERT INTO payment_operations(order_id, txid, amount, status)
		VALUES ($1, $2, $3, 'PREPARED')
		ON CONFLICT (txid) DO NOTHING`, req.OrderID, req.TxID, req.Total)
	if err != nil {
		return err
	}

	return tx.Commit(ctx)
}

func update2PCStatus(ctx context.Context, pool *pgxpool.Pool, txid, status string) error {
	_, _ = pool.Exec(ctx, `UPDATE twopc_prepared_tx SET status=$2, updated_at=now() WHERE txid=$1`, txid, status)
	_, _ = pool.Exec(ctx, `UPDATE payment_operations SET status=$2, updated_at=now() WHERE txid=$1`, txid, status)
	return nil
}

func handleTCC(pool *pgxpool.Pool, metrics *metrics.ServerMetrics, action string, w http.ResponseWriter, r *http.Request) {
	start := time.Now()
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"error": "method not allowed"})
		metrics.Requests.WithLabelValues("tcc_"+action, "405").Inc()
		metrics.LatencyMS.WithLabelValues("tcc_" + action).Observe(float64(time.Since(start).Milliseconds()))
		return
	}
	var req TCCRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "invalid json"})
		metrics.Requests.WithLabelValues("tcc_"+action, "400").Inc()
		metrics.LatencyMS.WithLabelValues("tcc_" + action).Observe(float64(time.Since(start).Milliseconds()))
		return
	}

	status := strings.ToUpper(action)
	_, _ = pool.Exec(r.Context(), `INSERT INTO tcc_operations(txid, order_id, step, status, amount)
		VALUES ($1, $2, $3, $4, $5)
		ON CONFLICT (txid) DO UPDATE SET status=EXCLUDED.status, updated_at=now()`, req.TxID, req.OrderID, req.Step, status, req.Amount)

	logging.Log(logging.Fields{Service: "payment-service", TxID: req.TxID, OrderID: req.OrderID, Step: "tcc_" + action, Status: status})
	writeJSON(w, http.StatusOK, map[string]any{"status": status})
	metrics.Requests.WithLabelValues("tcc_"+action, "200").Inc()
	metrics.LatencyMS.WithLabelValues("tcc_" + action).Observe(float64(time.Since(start).Milliseconds()))
}

func jsonPayload(req any) string {
	data, _ := json.Marshal(req)
	return string(data)
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
