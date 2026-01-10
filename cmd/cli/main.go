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

	tea "github.com/charmbracelet/bubbletea"
	"github.com/google/uuid"
)

type scenario struct {
	Name        string
	Description string
}

type mode struct {
	Name string
}

type model struct {
	modes        []mode
	scenarios    []scenario
	selectedMode int
	selectedScn  int
	status       string
	metrics      string
	busy         bool
}

func initialModel() model {
	return model{
		modes:     []mode{{"twopc"}, {"tcc"}, {"outbox"}, {"saga-orch"}, {"saga-chor"}},
		scenarios: []scenario{{"success", "Successful checkout"}, {"fail", "Fail at step"}, {"cancel", "Cancel at step"}, {"bench", "Run benchmark"}},
		status:    "Ready",
	}
}

func (m model) Init() tea.Cmd {
	return nil
}

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.KeyMsg:
		switch msg.String() {
		case "ctrl+c", "q":
			return m, tea.Quit
		case "up":
			if m.selectedMode > 0 {
				m.selectedMode--
			}
		case "down":
			if m.selectedMode < len(m.modes)-1 {
				m.selectedMode++
			}
		case "left":
			if m.selectedScn > 0 {
				m.selectedScn--
			}
		case "right":
			if m.selectedScn < len(m.scenarios)-1 {
				m.selectedScn++
			}
		case "enter":
			if m.busy {
				return m, nil
			}
			m.busy = true
			m.status = "Running..."
			mode := m.modes[m.selectedMode].Name
			scn := m.scenarios[m.selectedScn].Name
			return m, runScenarioCmd(mode, scn)
		}
	case scenarioResult:
		m.busy = false
		m.status = msg.status
		m.metrics = msg.metrics
	}
	return m, nil
}

func (m model) View() string {
	b := &strings.Builder{}
	fmt.Fprintln(b, "tx-lab-ecommerce-go CLI")
	fmt.Fprintln(b, "")
	fmt.Fprintln(b, "Modes:")
	for i, mode := range m.modes {
		marker := " "
		if i == m.selectedMode {
			marker = ">"
		}
		fmt.Fprintf(b, " %s %s\n", marker, mode.Name)
	}
	fmt.Fprintln(b, "")
	fmt.Fprintln(b, "Scenarios (use left/right):")
	for i, scn := range m.scenarios {
		marker := " "
		if i == m.selectedScn {
			marker = "*"
		}
		fmt.Fprintf(b, " %s %s - %s\n", marker, scn.Name, scn.Description)
	}
	fmt.Fprintln(b, "")
	fmt.Fprintf(b, "Status: %s\n", m.status)
	if m.metrics != "" {
		fmt.Fprintf(b, "Metrics: %s\n", m.metrics)
	}
	fmt.Fprintln(b, "\nControls: up/down select mode, left/right select scenario, enter to run, q to quit")
	return b.String()
}

type scenarioResult struct {
	status  string
	metrics string
}

func runScenarioCmd(mode, scn string) tea.Cmd {
	return func() tea.Msg {
		baseURL := getenv("ORDER_BASE_URL", "http://localhost:8080")
		switch scn {
		case "bench":
			metrics := runBenchmark(baseURL)
			return scenarioResult{status: "Benchmark finished", metrics: metrics}
		case "fail":
			return scenarioResult{status: fmt.Sprintf("Fail scenario requested (mode=%s). Configure failpoint in services.", mode)}
		case "cancel":
			return scenarioResult{status: fmt.Sprintf("Cancel scenario requested (mode=%s). Configure cancel in order-service.", mode)}
		default:
			req := map[string]any{
				"order_id": "",
				"total":    1200,
				"items":    []map[string]any{{"product_id": "sku-1", "quantity": 1}},
			}
			resp, err := doCheckout(baseURL, req)
			if err != nil {
				return scenarioResult{status: fmt.Sprintf("Checkout failed: %v", err)}
			}
			return scenarioResult{status: fmt.Sprintf("Checkout OK: %s", resp)}
		}
	}
}

func doCheckout(baseURL string, payload any) (string, error) {
	data, _ := json.Marshal(payload)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	url := strings.TrimRight(baseURL, "/") + "/checkout"
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(data))
	if err != nil {
		return "", err
	}
	idemKey := uuid.NewString()
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Idempotency-Key", idemKey)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return "", fmt.Errorf("status %d: %s", resp.StatusCode, string(body))
	}
	return string(body), nil
}

func runBenchmark(baseURL string) string {
	duration := 5 * time.Second
	vus := 5
	var mu sync.Mutex
	var total time.Duration
	var count int
	var errors int
	ctx, cancel := context.WithTimeout(context.Background(), duration)
	defer cancel()

	var wg sync.WaitGroup
	for i := 0; i < vus; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for {
				select {
				case <-ctx.Done():
					return
				default:
					start := time.Now()
					_, err := doCheckout(baseURL, map[string]any{
						"order_id": "",
						"total":    1200,
						"items":    []map[string]any{{"product_id": "sku-1", "quantity": 1}},
					})
					mu.Lock()
					if err != nil {
						errors++
					} else {
						count++
						total += time.Since(start)
					}
					mu.Unlock()
				}
			}
		}()
	}
	wg.Wait()

	avg := time.Duration(0)
	if count > 0 {
		avg = total / time.Duration(count)
	}
	throughput := float64(count) / duration.Seconds()
	return fmt.Sprintf("count=%d errors=%d avg=%s throughput=%.2f tx/s", count, errors, avg, throughput)
}

func main() {
	runCmd := flag.String("run", "", "run scenario: success|fail|cancel|bench")
	mode := flag.String("mode", "twopc", "mode to run")
	flag.Parse()

	if *runCmd != "" {
		res := runScenarioCmd(*mode, *runCmd)().(scenarioResult)
		fmt.Println(res.status)
		if res.metrics != "" {
			fmt.Println(res.metrics)
		}
		return
	}

	p := tea.NewProgram(initialModel())
	if _, err := p.Run(); err != nil {
		fmt.Println("error:", err)
		os.Exit(1)
	}
}

func getenv(k, def string) string {
	v := strings.TrimSpace(os.Getenv(k))
	if v == "" {
		return def
	}
	return v
}
