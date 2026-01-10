package logging

import (
	"encoding/json"
	"log"
	"time"
)

type Fields struct {
	Service    string `json:"service"`
	TxID       string `json:"txid,omitempty"`
	OrderID    string `json:"order_id,omitempty"`
	EventID    string `json:"event_id,omitempty"`
	Step       string `json:"step,omitempty"`
	Status     string `json:"status,omitempty"`
	DurationMS int64  `json:"duration_ms,omitempty"`
	Message    string `json:"message,omitempty"`
}

func Log(fields Fields) {
	payload := map[string]any{
		"service":     fields.Service,
		"txid":        fields.TxID,
		"order_id":    fields.OrderID,
		"event_id":    fields.EventID,
		"step":        fields.Step,
		"status":      fields.Status,
		"duration_ms": fields.DurationMS,
		"message":     fields.Message,
		"timestamp":   time.Now().UTC().Format(time.RFC3339Nano),
	}
	data, err := json.Marshal(payload)
	if err != nil {
		log.Printf("{\"service\":%q,\"status\":\"log_error\",\"error\":%q}", fields.Service, err.Error())
		return
	}
	log.Print(string(data))
}
