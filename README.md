# tx-lab-ecommerce-go

Демо mono-repo для сравнения 2PC, TCC, Outbox, Saga Orchestration и Saga Choreography на одном бизнес-процессе оформления заказа. Коммуникация асинхронная через Kafka (Redpanda), хранение данных — отдельные PostgreSQL на сервис, корзина предполагается в Redis.

## Состав сервисов

- **order-service** — API оформления заказа, координатор 2PC и Saga Orch.
- **inventory-service** — soft/hard reserve, списание.
- **payment-service** — создание платежа, подтверждение, компенсации.
- **shipping-service** — создание/отмена доставки.
- **notification-service** — подписчик событий, выводит уведомления в stdout и таблицу.

## Быстрый старт (kind)

```bash
make kind-create
make docker-build
make kind-load
make helm-install
```

Миграции (по месту, через kubectl exec в каждый postgres pod):

```bash
kubectl exec -it deploy/$(kubectl get deploy -n txlab -o name | grep postgres-order) -n txlab -- sh
# внутри pod
psql -U postgres -d orderdb -f /tmp/order.sql
```

SQL файлы находятся в `deploy/sql/*.sql`.

## Локальный запуск order-service

```bash
export DATABASE_URL=postgres://postgres:postgres@localhost:5432/orderdb?sslmode=disable
export TX_MODE=twopc
export INVENTORY_BASE_URL=http://localhost:8081
export PAYMENT_BASE_URL=http://localhost:8082
export SHIPPING_BASE_URL=http://localhost:8083

go run ./cmd/order-service
```

## CLI (TUI)

```bash
go run ./cmd/cli
```

CLI позволяет выбирать режим и сценарий (success/fail/cancel/bench). Для сценариев `fail` и `cancel` необходимо настроить соответствующие failpoints в сервисах.

## Метрики

Каждый сервис публикует Prometheus-метрики по `/metrics`.

## Сетевые помехи

Пример включения netem:

```bash
scripts/netem-delay.sh
scripts/netem-loss.sh
scripts/netem-clear.sh
```

## Helm

Чарт находится в `deploy/helm/txlab`. В `values.yaml` можно менять replicaCount и включать/выключать Kafka/Redis/Postgres.

## Dockerfile

Общий Dockerfile использует `--build-arg SERVICE=...` для сборки нужного сервиса.
