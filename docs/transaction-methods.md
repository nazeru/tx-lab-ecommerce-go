# Реализация методов транзакций (2PC, TCC, Saga, Outbox)

Документ описывает, как в проекте реализованы методы 2PC, TCC, Saga (оркестрация/хореография) и Outbox, а также где смотреть ключевые участки кода.

## 2PC (Two-Phase Commit)

**Назначение:** синхронно координировать несколько сервисов через фазы prepare/commit/abort.

**Где реализовано:**

- Координатор: `cmd/order-service/main.go` (эндпоинт `/checkout`, режим `TX_MODE=twopc`).
- Участники: `cmd/inventory-service/main.go`, `cmd/payment-service/main.go`, `cmd/shipping-service/main.go` (`/2pc/prepare`, `/2pc/commit`, `/2pc/abort`).
- База координатора: `deploy/sql/order.sql` (`twopc_tx_log`).

**Поток:**

1. `order-service` создает заказ и, при 2PC, пишет запись в `twopc_tx_log` со статусом `STARTED`.
2. Далее выполняется `prepare` на каждом участнике (`/2pc/prepare`).
3. При успехе всех `prepare` выполняется `commit` (`/2pc/commit`).
4. При ошибке на любом этапе выполняется `abort` (`/2pc/abort`).
5. Итоговый статус заказа обновляется в `orders`.

## TCC (Try-Confirm-Cancel)

**Назначение:** разбить шаги на попытку (Try), подтверждение (Confirm) и компенсацию (Cancel).

**Где реализовано:**

- Координатор: `cmd/order-service/main.go` (режим `TX_MODE=tcc`).
- Участники: `cmd/inventory-service/main.go`, `cmd/payment-service/main.go`, `cmd/shipping-service/main.go` (`/tcc/try`, `/tcc/confirm`, `/tcc/cancel`).
- Хранилища: таблицы `tcc_operations` в `deploy/sql/*`.

**Поток:**

1. `order-service` формирует шаги TCC и последовательно вызывает `try` у всех участников.
2. Если все `try` успешны, выполняется `confirm` для каждого шага.
3. При ошибке `try` или `confirm` выполняется `cancel` в обратном порядке для уже прошедших шагов.
4. Итоговый статус заказа обновляется.

## Saga (Orchestration)

**Назначение:** последовательное выполнение действий с компенсацией на уровне оркестратора.

**Где реализовано:**

- Оркестратор: `cmd/order-service/main.go` (режим `TX_MODE=saga-orch`).
- Участники: те же TCC-эндпоинты (`/tcc/try`, `/tcc/cancel`), используются как «действие/компенсация».

**Поток:**

1. `order-service` вызывает «действия» шагов через `tcc/try`.
2. При ошибке запускается компенсация (`tcc/cancel`) в обратном порядке.
3. При успехе всех шагов — заказ подтверждается.

## Saga (Choreography)

**Назначение:** взаимодействие через события без центрального оркестратора.

**Где реализовано:**

- Публикация события: `cmd/order-service/main.go` (режим `TX_MODE=saga-chor`).
- Транспорт событий: Kafka/Redpanda через Outbox (`pkg/outbox`).
- Потребители: например, `cmd/notification-service/main.go`.

**Поток:**

1. `order-service` создает заказ и кладет событие `OrderCreated` в outbox.
2. Фоновый relay публикует событие в Kafka.
3. Сервисы‑участники обрабатывают события и публикуют свои.

## Outbox

**Назначение:** надежная доставка событий из транзакций базы данных.

**Где реализовано:**

- Outbox операции: `pkg/outbox/outbox.go`.
- Таблицы outbox/inbox: `deploy/sql/*`.
- Фоновая публикация: `cmd/order-service/main.go` (relay, опционально для других сервисов).

**Поток:**

1. Внутри транзакции бизнес‑операции сохраняется событие в таблицу `outbox`.
2. Фоновый процесс периодически читает `outbox` и публикует сообщения в Kafka.
3. После успешной публикации ставится `sent_at`.

## Связь режимов с конфигурацией

- `TX_MODE=twopc` — 2PC.
- `TX_MODE=tcc` — TCC.
- `TX_MODE=saga-orch` — Saga (оркестрация).
- `TX_MODE=saga-chor` — Saga (хореография).
- `TX_MODE=outbox` — публикация события через outbox без выполнения распределенной координации.

## Переменные окружения (ключевые)

- `TX_MODE` — выбор режима транзакции.
- `MOCK_2PC` — включение mock-режима участников 2PC.
- `KAFKA_BROKERS` — список брокеров Kafka/Redpanda.
- `KAFKA_TOPIC` — топик событий (по умолчанию `txlab.events`).
- `OUTBOX_POLL_MS` — интервал опроса outbox.
- `OUTBOX_BATCH` — пакетная выборка для outbox.
