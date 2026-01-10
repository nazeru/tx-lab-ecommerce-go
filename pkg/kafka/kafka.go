package kafka

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"time"

	"github.com/segmentio/kafka-go"
)

type Client struct {
	Brokers []string
}

func NewClient(brokersCSV string) *Client {
	brokers := []string{}
	for _, b := range strings.Split(brokersCSV, ",") {
		b = strings.TrimSpace(b)
		if b != "" {
			brokers = append(brokers, b)
		}
	}
	return &Client{Brokers: brokers}
}

func (c *Client) Enabled() bool {
	return len(c.Brokers) > 0
}

func (c *Client) NewWriter(topic string) *kafka.Writer {
	return &kafka.Writer{
		Addr:         kafka.TCP(c.Brokers...),
		Topic:        topic,
		Balancer:     &kafka.Hash{},
		RequiredAcks: kafka.RequireOne,
	}
}

func (c *Client) NewReader(topic, groupID string) *kafka.Reader {
	return kafka.NewReader(kafka.ReaderConfig{
		Brokers:  c.Brokers,
		Topic:    topic,
		GroupID:  groupID,
		MinBytes: 10e3,
		MaxBytes: 10e6,
	})
}

func PublishJSON(ctx context.Context, writer *kafka.Writer, key string, payload any) error {
	data, err := json.Marshal(payload)
	if err != nil {
		return err
	}
	return writer.WriteMessages(ctx, kafka.Message{Key: []byte(key), Value: data, Time: time.Now().UTC()})
}

var ErrDisabled = errors.New("kafka disabled")
