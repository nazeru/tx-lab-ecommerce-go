-- shipping.sql
-- База shipping-service (участник 2PC)

BEGIN;

-- Журнал подготовленных транзакций 2PC (участник)
CREATE TABLE IF NOT EXISTS twopc_prepared_tx (
  txid          TEXT PRIMARY KEY,
  order_id      TEXT NOT NULL,
  step          TEXT NOT NULL, -- например 'create_shipment'
  status        TEXT NOT NULL CHECK (status IN ('PREPARED','COMMITTED','ABORTED')),
  payload       JSONB NOT NULL DEFAULT '{}'::jsonb,
  expires_at    TIMESTAMPTZ NULL,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_twopc_prepared_tx_order_id ON twopc_prepared_tx(order_id);
CREATE INDEX IF NOT EXISTS idx_twopc_prepared_tx_status   ON twopc_prepared_tx(status);

-- Отгрузки (минимально для демо)
CREATE TABLE IF NOT EXISTS shipments (
  id           BIGSERIAL PRIMARY KEY,
  order_id     TEXT NOT NULL,
  txid         TEXT NOT NULL UNIQUE,
  status       TEXT NOT NULL CHECK (status IN ('PREPARED','COMMITTED','ABORTED')),
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_shipments_order_id ON shipments(order_id);
CREATE INDEX IF NOT EXISTS idx_shipments_status   ON shipments(status);

-- TCC operations
CREATE TABLE IF NOT EXISTS tcc_operations (
  txid        TEXT PRIMARY KEY,
  order_id    TEXT NOT NULL,
  step        TEXT NOT NULL,
  status      TEXT NOT NULL CHECK (status IN ('TRY','CONFIRM','CANCEL')),
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Outbox / inbox for Kafka delivery
CREATE TABLE IF NOT EXISTS outbox (
  id         BIGSERIAL PRIMARY KEY,
  event_id   TEXT NOT NULL UNIQUE,
  topic      TEXT NOT NULL,
  key        TEXT NOT NULL,
  payload    JSONB NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  sent_at    TIMESTAMPTZ NULL
);

CREATE TABLE IF NOT EXISTS inbox (
  event_id    TEXT PRIMARY KEY,
  received_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMIT;
