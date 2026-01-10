package metrics

import (
	"net/http"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

type ServerMetrics struct {
	Requests  *prometheus.CounterVec
	LatencyMS *prometheus.HistogramVec
}

func NewServerMetrics(service string) *ServerMetrics {
	requests := prometheus.NewCounterVec(prometheus.CounterOpts{
		Namespace: "txlab",
		Subsystem: service,
		Name:      "http_requests_total",
		Help:      "Total number of HTTP requests.",
	}, []string{"handler", "status"})
	latency := prometheus.NewHistogramVec(prometheus.HistogramOpts{
		Namespace: "txlab",
		Subsystem: service,
		Name:      "http_request_duration_ms",
		Help:      "HTTP request latency in milliseconds.",
		Buckets:   []float64{5, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000},
	}, []string{"handler"})

	prometheus.MustRegister(requests, latency)
	return &ServerMetrics{Requests: requests, LatencyMS: latency}
}

func Handler() http.Handler {
	return promhttp.Handler()
}
