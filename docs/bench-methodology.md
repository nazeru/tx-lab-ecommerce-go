# Методика корректного бенчмарка

Документ описывает, как запускать воспроизводимые прогоны и как интерпретировать метрики для режимов `twopc/saga-orch/saga-chor/tcc/outbox`.

## Что измеряется

`bench-runner` в режиме `checkout` измеряет **ack-latency** — время до ответа `/checkout` (client-ack). Это не всегда равно времени «до финального бизнес-статуса» для асинхронных режимов (например, `saga-chor`).

Для приближения к end-to-end метрике используйте ожидание финального статуса:

```bash
./cmd/bench-runner \
  -base-url http://localhost:8080 \
  -scenario checkout \
  -total 1000 \
  -concurrency 10 \
  -await-final \
  -final-timeout 30s \
  -final-interval 500ms \
  -final-statuses CONFIRMED,COMMITTED
```

`bench-runner` опрашивает `GET /orders/{id}` и считает `final_*` метрики (сколько заказов дошли до финального статуса и сколько истекло по таймауту). Для режимов, где статус не изменяется после `PENDING`, метрика `final_timeouts` покажет, что финальное состояние недостижимо в текущей реализации.

## Валидность сетевых профилей (netem)

Профили `lossy/congested` должны отражаться на межсервисных RTT/потерях. Скрипт `bench-matrix.sh`:

* Применяет `tc netem` на целевые поды (`NETEM_TARGET_SELECTORS`).
* Перед каждым прогоном сохраняет вывод `tc qdisc show` и сетевые пробы во внешний лог (`netem_validation_log`).
* Опционально запускает краткие `ping` из временного pod’а к критическим сервисам (`PROBE_SERVICES`).

> ⚠️ Поды должны содержать утилиту `tc` (обычно пакет `iproute2`). По умолчанию отсутствие `tc` считается ошибкой. Чтобы пропустить netem для таких pod’ов и продолжить прогон, установите `NETEM_REQUIRE_TC=0`.

Пример:

```bash
NETEM_TARGET_SELECTORS="app=order;app=inventory;app=payment;app=shipping" \
PROBE_SERVICES="order inventory payment shipping" \
NETEM_VALIDATE=1 \
./scripts/bench-matrix.sh
```

**Важно:** если нагрузка идёт через `port-forward` на `127.0.0.1`, то эффект netem проявится только если `/checkout` синхронно ждёт межсервисные запросы внутри кластера. Для полного влияния сетевых профилей на клиентскую задержку рекомендуется запускать генератор **внутри кластера** (например, как Job/Pod), либо измерять отдельную метрику межсервисной задержки.

## Стабильность прогонов

`bench-matrix.sh` делает:

* `kubectl rollout status` + `kubectl wait` для всех deployment’ов из `READINESS_DEPLOYMENTS`.
* `/health` и `POST /checkout` warm-up до стабильного ответа 2xx.
* Автоматическую повторную попытку при транспортных ошибках (EOF/connection reset).

## Классификация ошибок

Результат `bench-runner` содержит `error_classes`:

* `transport` — проблемы соединения (EOF, reset и т.п.)
* `http_5xx` — инфраструктурные 5xx
* `business_rejected` — бизнес-отказ (например, `status=REJECTED/ABORTED`)
* `http_4xx` — прочие 4xx

Это позволяет разделять технические сбои и бизнес-ошибки.

## Ресурсы

`bench-matrix.sh` собирает `kubectl top` несколькими сэмплами и сохраняет **avg/max** по CPU/RAM в поле `resources`, чтобы избежать случайных нулей.

## Нагрузка

Рекомендуется запускать матрицу по нескольким уровням нагрузки и повторять прогоны:

```bash
CONCURRENCY_LIST="10 25 50 100" \
BENCH_RUNS_PER_POINT=3 \
WARMUP_TX=200 \
./scripts/bench-matrix.sh
```

В результатах сохраняются `p50/p90/p95/p99` и значения `final_*` (при `AWAIT_FINAL=1`).

## Проверка бизнес-семантики

Перед нагрузочными прогонами следует выполнить smoke-тесты (`scripts/smoke-checkout.sh`), чтобы убедиться, что:

* `/checkout` возвращает ожидаемый статус.
* `GET /orders/{id}` отражает корректный статус.
* Идемпотентность выдерживается (повторный `Idempotency-Key` возвращает тот же `order_id`).

Если сценарии `fail/cancel` настроены через failpoints, добавьте их в smoke-набор и останавливайте бенч при ошибках.
