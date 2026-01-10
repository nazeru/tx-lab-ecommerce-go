-- notification.sql
-- База notification-service

BEGIN;

CREATE TABLE IF NOT EXISTS inbox (
  event_id    TEXT PRIMARY KEY,
  received_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS notifications (
  event_id   TEXT PRIMARY KEY,
  order_id   TEXT NOT NULL,
  txid       TEXT NOT NULL,
  type       TEXT NOT NULL,
  payload    JSONB NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMIT;
