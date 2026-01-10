package main

import (
	"bytes"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"math"
	"net/http"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/google/uuid"
)

type benchResult struct {
	Timestamp          string         `json:"timestamp"`
	BaseURL            string         `json:"base_url"`
	Scenario           string         `json:"scenario"`
	Transactions       int            `json:"transactions"`
	Concurrency        int            `json:"concurrency"`
	OperationsPerTx    int            `json:"operations_per_transaction"`
	TotalRequests      int            `json:"total_requests"`
	TotalOperations    int            `json:"total_operations"`
	SuccessfulRequests int            `json:"successful_requests"`
	ErrorRequests      int            `json:"error_requests"`
	DurationSeconds    float64        `json:"duration_seconds"`
	AvgLatencyMs       float64        `json:"avg_latency_ms"`
	MinLatencyMs       float64        `json:"min_latency_ms"`
	MaxLatencyMs       float64        `json:"max_latency_ms"`
	P50LatencyMs       float64        `json:"p50_latency_ms"`
	P90LatencyMs       float64        `json:"p90_latency_ms"`
	P95LatencyMs       float64        `json:"p95_latency_ms"`
	P99LatencyMs       float64        `json:"p99_latency_ms"`
	ThroughputRPS      float64        `json:"throughput_rps"`
	StatusCounts       map[string]int `json:"status_counts"`
	ErrorClasses       map[string]int `json:"error_classes"`
	FirstError         string         `json:"first_error"`
	FinalizedRequests  int            `json:"finalized_requests"`
	FinalTimeouts      int            `json:"final_timeouts"`
	FinalAvgLatencyMs  float64        `json:"final_avg_latency_ms"`
	FinalP50LatencyMs  float64        `json:"final_p50_latency_ms"`
	FinalP90LatencyMs  float64        `json:"final_p90_latency_ms"`
	FinalP95LatencyMs  float64        `json:"final_p95_latency_ms"`
	FinalP99LatencyMs  float64        `json:"final_p99_latency_ms"`
}

type operation struct {
	name    string
	url     string
	payload func(txid, orderID string) any
}

type metrics struct {
	mu           sync.Mutex
	success      int
	errors       int
	total        time.Duration
	minLatency   time.Duration
	maxLatency   time.Duration
	latenciesMs  []float64
	finalMs      []float64
	finalTimeout int
	statusCounts map[string]int
	errorClasses map[string]int
	firstError   string
}

func newMetrics() *metrics {
	return &metrics{
		statusCounts: make(map[string]int),
		errorClasses: make(map[string]int),
	}
}

func (m *metrics) recordTransaction(latency time.Duration, err error) {
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
	m.latenciesMs = append(m.latenciesMs, float64(latency.Milliseconds()))
}

func (m *metrics) recordFinal(latency time.Duration, reached bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if !reached {
		m.finalTimeout++
		return
	}
	m.finalMs = append(m.finalMs, float64(latency.Milliseconds()))
}

func (m *metrics) recordStatus(status int, err error, class string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.statusCounts[strconv.Itoa(status)]++
	if class != "" {
		m.errorClasses[class]++
	}
	if err != nil && m.firstError == "" {
		m.firstError = err.Error()
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
	awaitFinal := flag.Bool("await-final", false, "wait for final order status after /checkout (checkout scenario only)")
	finalTimeout := flag.Duration("final-timeout", 30*time.Second, "timeout for final status polling")
	finalInterval := flag.Duration("final-interval", 500*time.Millisecond, "poll interval for final status")
	finalStatuses := flag.String("final-statuses", "CONFIRMED,COMMITTED", "comma-separated list of final order statuses")
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
	m := newMetrics()
	client := &http.Client{}
	finalStatusSet := parseFinalStatuses(*finalStatuses)

	start := time.Now()
	for i := 0; i < *concurrency; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for range tasks {
				txid := uuid.NewString()
				orderID := uuid.NewString()
				latency, err := runTransaction(ops, txid, orderID, client, *timeout, *awaitFinal, *finalTimeout, *finalInterval, *baseURL, finalStatusSet, m)
				m.recordTransaction(latency, err)
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
	p50, p90, p95, p99 := calcPercentiles(m.latenciesMs)
	finalAvg, finalP50, finalP90, finalP95, finalP99 := calcFinalPercentiles(m.finalMs)

	result := benchResult{
		Timestamp:          time.Now().UTC().Format(time.RFC3339),
		BaseURL:            *baseURL,
		Scenario:           *scenario,
		Transactions:       *total,
		Concurrency:        *concurrency,
		OperationsPerTx:    len(ops),
		TotalRequests:      *total,
		TotalOperations:    *total * len(ops),
		SuccessfulRequests: m.success,
		ErrorRequests:      m.errors,
		DurationSeconds:    duration.Seconds(),
		AvgLatencyMs:       avgLatency,
		MinLatencyMs:       minLatency,
		MaxLatencyMs:       maxLatency,
		P50LatencyMs:       p50,
		P90LatencyMs:       p90,
		P95LatencyMs:       p95,
		P99LatencyMs:       p99,
		ThroughputRPS:      float64(m.success) / duration.Seconds(),
		StatusCounts:       m.statusCounts,
		ErrorClasses:       m.errorClasses,
		FirstError:         m.firstError,
		FinalizedRequests:  len(m.finalMs),
		FinalTimeouts:      m.finalTimeout,
		FinalAvgLatencyMs:  finalAvg,
		FinalP50LatencyMs:  finalP50,
		FinalP90LatencyMs:  finalP90,
		FinalP95LatencyMs:  finalP95,
		FinalP99LatencyMs:  finalP99,
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

func runTransaction(ops []operation, txid, orderID string, client *http.Client, timeout time.Duration, awaitFinal bool, finalTimeout, finalInterval time.Duration, baseURL string, finalStatusSet map[string]struct{}, m *metrics) (time.Duration, error) {
	start := time.Now()
	var checkoutOrderID string
	var checkoutStatus string
	for _, op := range ops {
		info, class, err := doCheckout(op.url, op.payload(txid, orderID), client, timeout)
		m.recordStatus(info.StatusCode, err, class)
		if err != nil {
			return time.Since(start), fmt.Errorf("%s: %w", op.name, err)
		}
		if op.name == "checkout" {
			checkoutOrderID = info.OrderID
			checkoutStatus = info.OrderStatus
		}
	}
	if awaitFinal && len(ops) == 1 && ops[0].name == "checkout" && checkoutOrderID != "" {
		finalLatency, reached := waitForFinalStatus(client, baseURL, checkoutOrderID, checkoutStatus, finalStatusSet, finalTimeout, finalInterval)
		m.recordFinal(finalLatency, reached)
	}
	return time.Since(start), nil
}

type responseInfo struct {
	StatusCode  int
	Body        string
	OrderID     string
	OrderStatus string
}

func doCheckout(url string, payload any, client *http.Client, timeout time.Duration) (responseInfo, string, error) {
	data, _ := json.Marshal(payload)
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(data))
	if err != nil {
		return responseInfo{}, "transport", err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Idempotency-Key", uuid.NewString())
	resp, err := client.Do(req)
	if err != nil {
		return responseInfo{StatusCode: 0}, "transport", err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	bodyStr := strings.TrimSpace(string(body))
	orderID, status := parseCheckoutBody(bodyStr)
	info := responseInfo{
		StatusCode:  resp.StatusCode,
		Body:        bodyStr,
		OrderID:     orderID,
		OrderStatus: status,
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		class := classifyError(resp.StatusCode, bodyStr)
		return info, class, fmt.Errorf("status %d: %s", resp.StatusCode, bodyStr)
	}
	return info, "", nil
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

func classifyError(status int, body string) string {
	if isBusinessRejection(body) {
		return "business_rejected"
	}
	switch {
	case status >= 500:
		return "http_5xx"
	case status >= 400:
		return "http_4xx"
	default:
		return ""
	}
}

func isBusinessRejection(body string) bool {
	if body == "" {
		return false
	}
	var payload map[string]any
	if err := json.Unmarshal([]byte(body), &payload); err != nil {
		return false
	}
	status, _ := payload["status"].(string)
	status = strings.ToUpper(strings.TrimSpace(status))
	return status == "REJECTED" || status == "ABORTED"
}

func parseCheckoutBody(body string) (string, string) {
	if body == "" {
		return "", ""
	}
	var payload map[string]any
	if err := json.Unmarshal([]byte(body), &payload); err != nil {
		return "", ""
	}
	orderID, _ := payload["order_id"].(string)
	status, _ := payload["status"].(string)
	return orderID, status
}

func parseFinalStatuses(input string) map[string]struct{} {
	result := map[string]struct{}{}
	for _, part := range strings.Split(input, ",") {
		name := strings.ToUpper(strings.TrimSpace(part))
		if name == "" {
			continue
		}
		result[name] = struct{}{}
	}
	return result
}

func waitForFinalStatus(client *http.Client, baseURL, orderID, initialStatus string, finals map[string]struct{}, timeout, interval time.Duration) (time.Duration, bool) {
	start := time.Now()
	initialStatus = strings.ToUpper(strings.TrimSpace(initialStatus))
	if _, ok := finals[initialStatus]; ok {
		return time.Since(start), true
	}
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		status, err := fetchOrderStatus(client, baseURL, orderID)
		if err == nil {
			status = strings.ToUpper(strings.TrimSpace(status))
			if _, ok := finals[status]; ok {
				return time.Since(start), true
			}
		}
		time.Sleep(interval)
	}
	return time.Since(start), false
}

func fetchOrderStatus(client *http.Client, baseURL, orderID string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	url := strings.TrimRight(baseURL, "/") + "/orders/" + orderID
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return "", err
	}
	resp, err := client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("status %d", resp.StatusCode)
	}
	body, _ := io.ReadAll(resp.Body)
	var payload map[string]any
	if err := json.Unmarshal(body, &payload); err != nil {
		return "", err
	}
	status, _ := payload["status"].(string)
	return status, nil
}

func calcPercentiles(values []float64) (float64, float64, float64, float64) {
	if len(values) == 0 {
		return 0, 0, 0, 0
	}
	sort.Float64s(values)
	return percentile(values, 0.50), percentile(values, 0.90), percentile(values, 0.95), percentile(values, 0.99)
}

func calcFinalPercentiles(values []float64) (float64, float64, float64, float64, float64) {
	if len(values) == 0 {
		return 0, 0, 0, 0, 0
	}
	sort.Float64s(values)
	avg := 0.0
	for _, v := range values {
		avg += v
	}
	avg = avg / float64(len(values))
	return avg, percentile(values, 0.50), percentile(values, 0.90), percentile(values, 0.95), percentile(values, 0.99)
}

func percentile(sorted []float64, p float64) float64 {
	if len(sorted) == 0 {
		return 0
	}
	if p <= 0 {
		return sorted[0]
	}
	if p >= 1 {
		return sorted[len(sorted)-1]
	}
	rank := int(math.Ceil(p*float64(len(sorted)))) - 1
	if rank < 0 {
		rank = 0
	}
	if rank >= len(sorted) {
		rank = len(sorted) - 1
	}
	return sorted[rank]
}
