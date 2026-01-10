-- inventory.sql
-- База inventory-service (участник 2PC)

BEGIN;

-- Журнал подготовленных транзакций 2PC (участник)
CREATE TABLE IF NOT EXISTS twopc_prepared_tx (
  txid          TEXT PRIMARY KEY,
  order_id      TEXT NOT NULL,
  step          TEXT NOT NULL, -- например 'reserve_inventory'
  status        TEXT NOT NULL CHECK (status IN ('PREPARED','COMMITTED','ABORTED')),
  payload       JSONB NOT NULL DEFAULT '{}'::jsonb,
  expires_at    TIMESTAMPTZ NULL,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_twopc_prepared_tx_order_id ON twopc_prepared_tx(order_id);
CREATE INDEX IF NOT EXISTS idx_twopc_prepared_tx_status   ON twopc_prepared_tx(status);

-- Остатки (для демо можно заранее seed'ить)
CREATE TABLE IF NOT EXISTS inventory_stock (
  product_id   TEXT PRIMARY KEY,
  available    INT NOT NULL CHECK (available >= 0),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Резервы под заказ (создаются на PREPARE, финализируются на COMMIT, снимаются на ABORT)
CREATE TABLE IF NOT EXISTS inventory_reservations (
  id           BIGSERIAL PRIMARY KEY,
  order_id     TEXT NOT NULL,
  txid         TEXT NOT NULL,
  product_id   TEXT NOT NULL,
  quantity     INT NOT NULL CHECK (quantity > 0),
  status       TEXT NOT NULL CHECK (status IN ('PREPARED','COMMITTED','ABORTED')),
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (txid, product_id)
);

CREATE INDEX IF NOT EXISTS idx_inventory_reservations_order_id ON inventory_reservations(order_id);
CREATE INDEX IF NOT EXISTS idx_inventory_reservations_status   ON inventory_reservations(status);
CREATE INDEX IF NOT EXISTS idx_inventory_reservations_product  ON inventory_reservations(product_id);

COMMIT;
