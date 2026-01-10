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
	TotalRequests      int     `json:"total_requests"`
	SuccessfulRequests int     `json:"successful_requests"`
	ErrorRequests      int     `json:"error_requests"`
	DurationSeconds    float64 `json:"duration_seconds"`
	AvgLatencyMs       float64 `json:"avg_latency_ms"`
	MinLatencyMs       float64 `json:"min_latency_ms"`
	MaxLatencyMs       float64 `json:"max_latency_ms"`
	ThroughputRPS      float64 `json:"throughput_rps"`
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

	tasks := make(chan struct{})
	var wg sync.WaitGroup
	m := &metrics{}
	client := &http.Client{}
	payload := map[string]any{
		"order_id": "",
		"total":    1200,
		"items":    []map[string]any{{"product_id": "sku-1", "quantity": 1}},
	}

	start := time.Now()
	for i := 0; i < *concurrency; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for range tasks {
				begin := time.Now()
				err := doCheckout(*baseURL, payload, client, *timeout)
				m.record(time.Since(begin), err)
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
		TotalRequests:      *total,
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

func doCheckout(baseURL string, payload any, client *http.Client, timeout time.Duration) error {
	data, _ := json.Marshal(payload)
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	url := strings.TrimRight(baseURL, "/") + "/checkout"
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
