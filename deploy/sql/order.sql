-- order.sql
-- База order-service (координатор 2PC внутри order-service)

BEGIN;

-- Заказы
CREATE TABLE IF NOT EXISTS orders (
  id           TEXT PRIMARY KEY,
  status       TEXT NOT NULL CHECK (status IN ('PENDING','PROCESSING','CONFIRMED','REJECTED','CANCELLED')),
  total        BIGINT NOT NULL CHECK (total >= 0),
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_orders_status ON orders(status);

-- Позиции заказа (товары и количество)
CREATE TABLE IF NOT EXISTS order_items (
  order_id    TEXT NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
  product_id  TEXT NOT NULL,
  quantity    INT  NOT NULL CHECK (quantity > 0),
  PRIMARY KEY (order_id, product_id)
);

CREATE INDEX IF NOT EXISTS idx_order_items_product_id ON order_items(product_id);

-- Идемпотентность checkout (рекомендуется для реплик и повторов запросов)
CREATE TABLE IF NOT EXISTS order_idempotency (
  idempotency_key TEXT PRIMARY KEY,
  order_id        TEXT NOT NULL,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Журнал координатора 2PC
CREATE TABLE IF NOT EXISTS twopc_tx_log (
  txid          TEXT PRIMARY KEY,
  order_id      TEXT NOT NULL,
  status        TEXT NOT NULL CHECK (status IN ('STARTED','PREPARING','COMMITTING','ABORTING','COMMITTED','ABORTED')),
  participants  JSONB NOT NULL DEFAULT '[]'::jsonb,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_twopc_tx_log_order_id ON twopc_tx_log(order_id);
CREATE INDEX IF NOT EXISTS idx_twopc_tx_log_status   ON twopc_tx_log(status);

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
