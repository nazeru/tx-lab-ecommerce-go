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

	"github.com/nazeru/tx-lab-ecommerce-go/pkg/kafka"
	"github.com/nazeru/tx-lab-ecommerce-go/pkg/logging"
	"github.com/nazeru/tx-lab-ecommerce-go/pkg/metrics"
)

type cfg struct {
	Port         string
	DatabaseURL  string
	KafkaBrokers string
	Topic        string
	GroupID      string
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

	srvMetrics := metrics.NewServerMetrics("notification_service")

	kafkaClient := kafka.NewClient(cfg.KafkaBrokers)
	if kafkaClient.Enabled() {
		go consumeEvents(pool, kafkaClient, cfg)
	}

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

	srv := &http.Server{Addr: ":" + cfg.Port, Handler: mux, ReadHeaderTimeout: 5 * time.Second}
	log.Printf("notification-service listening on :%s", cfg.Port)
	log.Fatal(srv.ListenAndServe())
}

func readCfg() (cfg, error) {
	port := getenv("PORT", "8080")
	db := strings.TrimSpace(os.Getenv("DATABASE_URL"))
	if db == "" {
		return cfg{}, errors.New("DATABASE_URL is required")
	}
	return cfg{
		Port:         port,
		DatabaseURL:  db,
		KafkaBrokers: getenv("KAFKA_BROKERS", ""),
		Topic:        getenv("KAFKA_TOPIC", "txlab.events"),
		GroupID:      getenv("KAFKA_GROUP_ID", "notification-service"),
	}, nil
}

func consumeEvents(pool *pgxpool.Pool, client *kafka.Client, cfg cfg) {
	reader := client.NewReader(cfg.Topic, cfg.GroupID)
	defer reader.Close()
	for {
		msg, err := reader.ReadMessage(context.Background())
		if err != nil {
			log.Printf("kafka read error: %v", err)
			time.Sleep(2 * time.Second)
			continue
		}
		var evt Event
		if err := json.Unmarshal(msg.Value, &evt); err != nil {
			log.Printf("event decode error: %v", err)
			continue
		}
		if evt.EventID == "" {
			continue
		}
		if err := saveNotification(context.Background(), pool, evt); err != nil {
			log.Printf("notification save error: %v", err)
			continue
		}
		logging.Log(logging.Fields{Service: "notification-service", TxID: evt.TxID, OrderID: evt.OrderID, EventID: evt.EventID, Step: evt.Type, Status: "emitted"})
	}
}

func saveNotification(ctx context.Context, pool *pgxpool.Pool, evt Event) error {
	_, err := pool.Exec(ctx, `INSERT INTO inbox(event_id, received_at)
		VALUES ($1, now()) ON CONFLICT (event_id) DO NOTHING`, evt.EventID)
	if err != nil {
		return err
	}

	data, _ := json.Marshal(evt.Payload)
	_, err = pool.Exec(ctx, `INSERT INTO notifications(event_id, order_id, txid, type, payload)
		VALUES ($1, $2, $3, $4, $5) ON CONFLICT (event_id) DO NOTHING`, evt.EventID, evt.OrderID, evt.TxID, evt.Type, string(data))
	return err
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
