-- payment.sql
-- База payment-service (участник 2PC)

BEGIN;

-- Журнал подготовленных транзакций 2PC (участник)
CREATE TABLE IF NOT EXISTS twopc_prepared_tx (
  txid          TEXT PRIMARY KEY,
  order_id      TEXT NOT NULL,
  step          TEXT NOT NULL,  -- например 'authorize_payment'
  status        TEXT NOT NULL CHECK (status IN ('PREPARED','COMMITTED','ABORTED')),
  payload       JSONB NOT NULL DEFAULT '{}'::jsonb,
  expires_at    TIMESTAMPTZ NULL,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_twopc_prepared_tx_order_id ON twopc_prepared_tx(order_id);
CREATE INDEX IF NOT EXISTS idx_twopc_prepared_tx_status   ON twopc_prepared_tx(status);

-- Платёжные операции (минимально для демо)
-- В 2PC на PREPARE создаём запись со статусом PREPARED, на COMMIT -> COMMITTED, на ABORT -> ABORTED
CREATE TABLE IF NOT EXISTS payment_operations (
  id            BIGSERIAL PRIMARY KEY,
  order_id      TEXT NOT NULL,
  txid          TEXT NOT NULL UNIQUE,
  amount        BIGINT NOT NULL CHECK (amount >= 0),
  status        TEXT NOT NULL CHECK (status IN ('PREPARED','COMMITTED','ABORTED')),
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_payment_operations_order_id ON payment_operations(order_id);
CREATE INDEX IF NOT EXISTS idx_payment_operations_status   ON payment_operations(status);

-- TCC operations
CREATE TABLE IF NOT EXISTS tcc_operations (
  txid        TEXT PRIMARY KEY,
  order_id    TEXT NOT NULL,
  step        TEXT NOT NULL,
  status      TEXT NOT NULL CHECK (status IN ('TRY','CONFIRM','CANCEL')),
  amount      BIGINT NOT NULL DEFAULT 0,
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
