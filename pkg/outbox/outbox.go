package outbox

import (
	"context"
	"encoding/json"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

type Record struct {
	ID        int64           `json:"id"`
	EventID   string          `json:"event_id"`
	Topic     string          `json:"topic"`
	Key       string          `json:"key"`
	Payload   json.RawMessage `json:"payload"`
	CreatedAt time.Time       `json:"created_at"`
	SentAt    *time.Time      `json:"sent_at"`
}

func Insert(ctx context.Context, pool *pgxpool.Pool, eventID, topic, key string, payload any) error {
	data, err := json.Marshal(payload)
	if err != nil {
		return err
	}
	_, err = pool.Exec(ctx, `INSERT INTO outbox(event_id, topic, key, payload) VALUES ($1, $2, $3, $4)`, eventID, topic, key, data)
	return err
}

func MarkSent(ctx context.Context, pool *pgxpool.Pool, id int64) error {
	_, err := pool.Exec(ctx, `UPDATE outbox SET sent_at=now() WHERE id=$1`, id)
	return err
}

func FetchPending(ctx context.Context, pool *pgxpool.Pool, limit int) ([]Record, error) {
	rows, err := pool.Query(ctx, `SELECT id, event_id, topic, key, payload, created_at, sent_at FROM outbox WHERE sent_at IS NULL ORDER BY id LIMIT $1`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []Record
	for rows.Next() {
		var rec Record
		if err := rows.Scan(&rec.ID, &rec.EventID, &rec.Topic, &rec.Key, &rec.Payload, &rec.CreatedAt, &rec.SentAt); err != nil {
			return nil, err
		}
		out = append(out, rec)
	}
	return out, rows.Err()
}
