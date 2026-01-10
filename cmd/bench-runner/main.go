package main

import (
	"bytes"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/google/uuid"
)

type benchResult struct {
	Timestamp          string  `json:"timestamp"`
	BaseURL            string  `json:"base_url"`
	Scenario           string  `json:"scenario"`
	Transactions       int     `json:"transactions"`
	OperationsPerTx    int     `json:"operations_per_transaction"`
	TotalRequests      int     `json:"total_requests"`
	TotalOperations    int     `json:"total_operations"`
	SuccessfulRequests int     `json:"successful_requests"`
	ErrorRequests      int     `json:"error_requests"`
	DurationSeconds    float64 `json:"duration_seconds"`
	AvgLatencyMs       float64 `json:"avg_latency_ms"`
	MinLatencyMs       float64 `json:"min_latency_ms"`
	MaxLatencyMs       float64 `json:"max_latency_ms"`
	ThroughputRPS      float64 `json:"throughput_rps"`
}

type operation struct {
	name    string
	url     string
	payload func(txid, orderID string) any
}

type metrics struct {
	mu         sync.Mutex
	success    int
	errors     int
	total      time.Duration
	minLatency time.Duration
	maxLatency time.Duration
}

func (m *metrics) record(latency time.Duration, err error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if err != nil {
		m.errors++
		return
	}
	m.success++
	m.total += latency
	if m.minLatency == 0 || latency < m.minLatency {
		m.minLatency = latency
	}
	if latency > m.maxLatency {
		m.maxLatency = latency
	}
}

func main() {
	baseURL := flag.String("base-url", getenv("ORDER_BASE_URL", "http://localhost:8080"), "order-service base URL")
	inventoryURL := flag.String("inventory-url", getenv("INVENTORY_BASE_URL", ""), "inventory-service base URL")
	paymentURL := flag.String("payment-url", getenv("PAYMENT_BASE_URL", ""), "payment-service base URL")
	shippingURL := flag.String("shipping-url", getenv("SHIPPING_BASE_URL", ""), "shipping-service base URL")
	scenario := flag.String("scenario", "checkout", "scenario to run: checkout|2pc|tcc|all")
	total := flag.Int("total", 1000, "total number of transactions")
	concurrency := flag.Int("concurrency", 10, "number of concurrent workers")
	timeout := flag.Duration("timeout", 10*time.Second, "per-request timeout")
	output := flag.String("output", "", "optional output path for JSON result")
	flag.Parse()

	if *total <= 0 {
		fmt.Fprintln(os.Stderr, "total must be > 0")
		os.Exit(1)
	}
	if *concurrency <= 0 {
		fmt.Fprintln(os.Stderr, "concurrency must be > 0")
		os.Exit(1)
	}

	ops, err := buildOperations(*scenario, *baseURL, *inventoryURL, *paymentURL, *shippingURL)
	if err != nil {
		fmt.Fprintln(os.Stderr, err.Error())
		os.Exit(1)
	}

	tasks := make(chan struct{})
	var wg sync.WaitGroup
	m := &metrics{}
	client := &http.Client{}

	start := time.Now()
	for i := 0; i < *concurrency; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for range tasks {
				txid := uuid.NewString()
				orderID := uuid.NewString()
				latency, err := runTransaction(ops, txid, orderID, client, *timeout)
				m.record(latency, err)
			}
		}()
	}

	for i := 0; i < *total; i++ {
		tasks <- struct{}{}
	}
	close(tasks)
	wg.Wait()

	duration := time.Since(start)
	avgLatency := 0.0
	minLatency := 0.0
	maxLatency := 0.0
	if m.success > 0 {
		avgLatency = float64(m.total.Milliseconds()) / float64(m.success)
		minLatency = float64(m.minLatency.Milliseconds())
		maxLatency = float64(m.maxLatency.Milliseconds())
	}

	result := benchResult{
		Timestamp:          time.Now().UTC().Format(time.RFC3339),
		BaseURL:            *baseURL,
		Scenario:           *scenario,
		Transactions:       *total,
		OperationsPerTx:    len(ops),
		TotalRequests:      *total,
		TotalOperations:    *total * len(ops),
		SuccessfulRequests: m.success,
		ErrorRequests:      m.errors,
		DurationSeconds:    duration.Seconds(),
		AvgLatencyMs:       avgLatency,
		MinLatencyMs:       minLatency,
		MaxLatencyMs:       maxLatency,
		ThroughputRPS:      float64(m.success) / duration.Seconds(),
	}

	encoder := json.NewEncoder(os.Stdout)
	encoder.SetIndent("", "  ")
	if err := encoder.Encode(result); err != nil {
		fmt.Fprintf(os.Stderr, "failed to encode result: %v\n", err)
		os.Exit(1)
	}

	if *output != "" {
		if err := writeJSON(*output, result); err != nil {
			fmt.Fprintf(os.Stderr, "failed to write output: %v\n", err)
			os.Exit(1)
		}
	}
}

func buildOperations(scenario, orderURL, inventoryURL, paymentURL, shippingURL string) ([]operation, error) {
	switch scenario {
	case "checkout":
		return []operation{
			{
				name: "checkout",
				url:  strings.TrimRight(orderURL, "/") + "/checkout",
				payload: func(txid, orderID string) any {
					return map[string]any{
						"order_id": orderID,
						"total":    1200,
						"items":    []map[string]any{{"product_id": "sku-1", "quantity": 1}},
					}
				},
			},
		}, nil
	case "2pc", "tcc", "all":
		if inventoryURL == "" || paymentURL == "" || shippingURL == "" {
			return nil, fmt.Errorf("inventory-url, payment-url, and shipping-url are required for scenario %q", scenario)
		}
	default:
		return nil, fmt.Errorf("unknown scenario: %s", scenario)
	}

	ops := []operation{}
	if scenario == "2pc" || scenario == "all" {
		ops = append(ops,
			operation{
				name: "inventory-2pc-prepare",
				url:  strings.TrimRight(inventoryURL, "/") + "/2pc/prepare",
				payload: func(txid, orderID string) any {
					return map[string]any{
						"txid":     txid,
						"order_id": orderID,
						"items":    []map[string]any{{"product_id": "sku-1", "quantity": 1}},
					}
				},
			},
			operation{
				name: "inventory-2pc-commit",
				url:  strings.TrimRight(inventoryURL, "/") + "/2pc/commit",
				payload: func(txid, orderID string) any {
					return map[string]any{"txid": txid, "order_id": orderID}
				},
			},
			operation{
				name: "inventory-2pc-abort",
				url:  strings.TrimRight(inventoryURL, "/") + "/2pc/abort",
				payload: func(txid, orderID string) any {
					return map[string]any{"txid": txid, "order_id": orderID}
				},
			},
			operation{
				name: "payment-2pc-prepare",
				url:  strings.TrimRight(paymentURL, "/") + "/2pc/prepare",
				payload: func(txid, orderID string) any {
					return map[string]any{"txid": txid, "order_id": orderID, "total": int64(1200)}
				},
			},
			operation{
				name: "payment-2pc-commit",
				url:  strings.TrimRight(paymentURL, "/") + "/2pc/commit",
				payload: func(txid, orderID string) any {
					return map[string]any{"txid": txid, "order_id": orderID}
				},
			},
			operation{
				name: "payment-2pc-abort",
				url:  strings.TrimRight(paymentURL, "/") + "/2pc/abort",
				payload: func(txid, orderID string) any {
					return map[string]any{"txid": txid, "order_id": orderID}
				},
			},
			operation{
				name: "shipping-2pc-prepare",
				url:  strings.TrimRight(shippingURL, "/") + "/2pc/prepare",
				payload: func(txid, orderID string) any {
					return map[string]any{"txid": txid, "order_id": orderID}
				},
			},
			operation{
				name: "shipping-2pc-commit",
				url:  strings.TrimRight(shippingURL, "/") + "/2pc/commit",
				payload: func(txid, orderID string) any {
					return map[string]any{"txid": txid, "order_id": orderID}
				},
			},
			operation{
				name: "shipping-2pc-abort",
				url:  strings.TrimRight(shippingURL, "/") + "/2pc/abort",
				payload: func(txid, orderID string) any {
					return map[string]any{"txid": txid, "order_id": orderID}
				},
			},
		)
	}

	if scenario == "tcc" || scenario == "all" {
		ops = append(ops,
			operation{
				name: "inventory-tcc-try",
				url:  strings.TrimRight(inventoryURL, "/") + "/tcc/try",
				payload: func(txid, orderID string) any {
					return map[string]any{"txid": txid, "order_id": orderID, "step": "reserve_inventory"}
				},
			},
			operation{
				name: "inventory-tcc-confirm",
				url:  strings.TrimRight(inventoryURL, "/") + "/tcc/confirm",
				payload: func(txid, orderID string) any {
					return map[string]any{"txid": txid, "order_id": orderID, "step": "reserve_inventory"}
				},
			},
			operation{
				name: "inventory-tcc-cancel",
				url:  strings.TrimRight(inventoryURL, "/") + "/tcc/cancel",
				payload: func(txid, orderID string) any {
					return map[string]any{"txid": txid, "order_id": orderID, "step": "reserve_inventory"}
				},
			},
			operation{
				name: "payment-tcc-try",
				url:  strings.TrimRight(paymentURL, "/") + "/tcc/try",
				payload: func(txid, orderID string) any {
					return map[string]any{"txid": txid, "order_id": orderID, "step": "authorize_payment", "amount": int64(1200)}
				},
			},
			operation{
				name: "payment-tcc-confirm",
				url:  strings.TrimRight(paymentURL, "/") + "/tcc/confirm",
				payload: func(txid, orderID string) any {
					return map[string]any{"txid": txid, "order_id": orderID, "step": "authorize_payment", "amount": int64(1200)}
				},
			},
			operation{
				name: "payment-tcc-cancel",
				url:  strings.TrimRight(paymentURL, "/") + "/tcc/cancel",
				payload: func(txid, orderID string) any {
					return map[string]any{"txid": txid, "order_id": orderID, "step": "authorize_payment", "amount": int64(1200)}
				},
			},
			operation{
				name: "shipping-tcc-try",
				url:  strings.TrimRight(shippingURL, "/") + "/tcc/try",
				payload: func(txid, orderID string) any {
					return map[string]any{"txid": txid, "order_id": orderID, "step": "create_shipment"}
				},
			},
			operation{
				name: "shipping-tcc-confirm",
				url:  strings.TrimRight(shippingURL, "/") + "/tcc/confirm",
				payload: func(txid, orderID string) any {
					return map[string]any{"txid": txid, "order_id": orderID, "step": "create_shipment"}
				},
			},
			operation{
				name: "shipping-tcc-cancel",
				url:  strings.TrimRight(shippingURL, "/") + "/tcc/cancel",
				payload: func(txid, orderID string) any {
					return map[string]any{"txid": txid, "order_id": orderID, "step": "create_shipment"}
				},
			},
		)
	}
	return ops, nil
}

func runTransaction(ops []operation, txid, orderID string, client *http.Client, timeout time.Duration) (time.Duration, error) {
	start := time.Now()
	for _, op := range ops {
		if err := postJSON(op.url, op.payload(txid, orderID), client, timeout); err != nil {
			return time.Since(start), fmt.Errorf("%s: %w", op.name, err)
		}
	}
	return time.Since(start), nil
}

func postJSON(url string, payload any, client *http.Client, timeout time.Duration) error {
	data, _ := json.Marshal(payload)
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(data))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Idempotency-Key", uuid.NewString())
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("status %d: %s", resp.StatusCode, string(body))
	}
	return nil
}

func writeJSON(path string, result benchResult) error {
	data, err := json.MarshalIndent(result, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, data, 0o644)
}

func getenv(key, def string) string {
	v := strings.TrimSpace(os.Getenv(key))
	if v == "" {
		return def
	}
	return v
}
