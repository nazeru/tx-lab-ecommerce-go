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
make kind-up
```

Команда поднимает все сервисы через Helm-чарт, а также Kafka/Redis/Postgres в namespace `txlab`.

Миграции всех сервисов:

```bash
make migrate-all
```

Пробросить порты всех сервисов и Postgres на localhost:

```bash
make pf-all
```

Миграции вручную (по месту, через kubectl exec в каждый postgres pod):

```bash
kubectl exec -it deploy/$(kubectl get deploy -n txlab -o name | grep postgres-order) -n txlab -- sh
# внутри pod
psql -U postgres -d orderdb -f /tmp/order.sql
```

SQL файлы находятся в `deploy/sql/*.sql`.

## Локальный запуск order-service

```bash
make run-order
```

## Makefile: быстрый запуск и тесты

Загрузить зависимости:

```bash
make deps
```

Запуск order-service с возможностью переопределить переменные:

```bash
make run-order TX_MODE=tcc DATABASE_URL=postgres://postgres:postgres@localhost:5432/orderdb?sslmode=disable
```

Запуск CLI:

```bash
make run-cli
```

Запуск тестов:

```bash
make test
```

## CLI (TUI)

```bash
go run ./cmd/cli
```

CLI позволяет выбирать режим и сценарий (success/fail/cancel/bench). Для сценариев `fail` и `cancel` необходимо настроить соответствующие failpoints в сервисах.

## Метрики

Каждый сервис публикует Prometheus-метрики по `/metrics`.

## Бенчмарки

Единичный прогон нагрузки (checkout):

```bash
go run ./cmd/bench-runner -base-url http://localhost:8080 -scenario checkout -total 1000 -concurrency 10
```

Единичный прогон всех методов распределённых транзакций (2PC + TCC):

```bash
go run ./cmd/bench-runner \
  -scenario all \
  -inventory-url http://localhost:8081 \
  -payment-url http://localhost:8082 \
  -shipping-url http://localhost:8083 \
  -total 1000 \
  -concurrency 10
```

Матрица прогонов (replicas/transactions/latency/jitter) с сохранением результатов в `results/`:

```bash
./scripts/bench-matrix.sh
```

Настраиваемые параметры (переменные окружения):

```bash
NAMESPACE=txlab \
DEPLOYMENT=order \
APP_LABEL=order \
ORDER_BASE_URL=http://localhost:8080 \
INVENTORY_BASE_URL=http://localhost:8081 \
PAYMENT_BASE_URL=http://localhost:8082 \
SHIPPING_BASE_URL=http://localhost:8083 \
BENCH_SCENARIO=all \
CONCURRENCY=10 \
RESULTS_DIR=results \
./scripts/bench-matrix.sh
```

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
