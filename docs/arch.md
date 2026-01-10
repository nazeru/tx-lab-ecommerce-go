Ниже приведена рекомендуемая структура репозитория (mono-repo) и разбиение по пакетам так, чтобы вы могли **реализовать все 5 методов** (2PC, TCC, Outbox, Saga choreography, Saga orchestration), **гонять сценарии**, **масштабировать репликами**, **включать сетевые помехи**, и **снимать метрики** (latency/throughput/resources/network).

## Принципы структуры

1. **Сервисы остаются “тонкими”**, а вся логика методов транзакций переиспользуется из `pkg/tx/*`.
2. Для честного сравнения методы переключаются **конфигом**, без переписывания бизнес-кода.
3. Нагрузочные сценарии и fault-injection не смешиваются с сервисным кодом: отдельные каталоги `bench/` и `chaos/`.
4. Kubernetes/Helm — единственная точка управления масштабированием и экспериментами.

---

# Структура папок (mono-repo)

```text
tx-lab-ecommerce-go/
  cmd/
    order-service/
      main.go
    payment-service/
      main.go
    inventory-service/
      main.go
    shipping-service/
      main.go
    notification-service/
      main.go
    bench-runner/                 # генератор нагрузки/сценариев (внутри кластера)
      main.go
    tx-coordinator/               # опционально: координатор 2PC (если вы хотите отдельный процесс)
      main.go

  internal/
    order/
      api/                        # HTTP/gRPC handlers
      app/                        # use-cases (Checkout, Cancel, Compensate)
      domain/                     # модели, статусы, инварианты
      infra/
        db/                       # репозитории
        clients/                  # вызовы в payment/inventory/shipping
        outbox/                   # outbox worker (если в сервисе)
      tx/                         # адаптеры к общим методам (saga/tcc/2pc)
    payment/
      api/
      app/
      domain/
      infra/
        db/
        outbox/
      tx/
    inventory/
      api/
      app/
      domain/
      infra/
        db/
        outbox/
      tx/
    shipping/
      api/
      app/
      domain/
      infra/
        db/
        outbox/
      tx/
    notification/
      consumer/                   # Kafka consumer
      app/
      infra/

  pkg/
    api/                          # общие DTO, ошибки, middleware, корреляция
      http/
      ids/
    event/                        # единый event envelope, версии событий
      envelope.go
      types.go
    tx/
      common/                     # интерфейсы, модели, статусы шагов
        interfaces.go
        state.go
      outbox/
        writer.go                 # запись outbox в транзакции
        publisher.go              # публикация (Kafka)
        inbox.go                  # дедупликация по event_id
      saga/
        orchestration/            # оркестраторная сага (машина состояний + шаги)
          engine.go
          steps.go
          retry.go
        choreography/             # choreography: правила реакций на события
          handlers.go
          routing.go
      tcc/
        engine.go                 # общий TCC-движок (Try/Confirm/Cancel)
        store.go                  # хранение состояния TCC
      twopc/
        coordinator/              # 2PC coordinator (prepare/commit/abort)
        participant/              # обвязка участника (prepared log)
        store.go                  # журнал/таблицы
      faults/
        errors.go                 # управляемые “отказы” по сценарию
        toggles.go                # включение отказов через config/HTTP

    clients/                      # общий клиент для inter-service RPC
      paymentclient/
      inventoryclient/
      shippingclient/

    config/
      config.go                   # единая схема env-конфига
      flags.go

    telemetry/                    # метрики и сбор ресурсов (без конкретного вендора UI)
      metrics.go                  # Prometheus exporter
      runtime.go                  # CPU/mem goruntime
      net.go                      # сетевые счётчики (по возможности)
      labels.go

  deploy/
    helm/
      tx-lab-ecommerce-go/                      # umbrella chart
        Chart.yaml
        values.yaml
        values-experiments/       # набор профилей экспериментов
          saga-orch.yaml
          saga-chor.yaml
          tcc.yaml
          twopc.yaml
          outbox-only.yaml
          scale-1.yaml
          scale-3.yaml
          chaos-latency.yaml
        templates/
          order/
          payment/
          inventory/
          shipping/
          notification/
          bench-runner/
          kafka/
          postgres/
          redis/
          networkpolicy.yaml
          hpa.yaml
          servicemonitor.yaml     # если будете собирать метрики Prometheus
    k8s/
      kind-config.yaml            # конфиг kind (если нужен)
      manifests/                  # редкие ручные манифесты/CRD (например chaos)

  bench/
    k6/
      checkout.js                 # профиль нагрузки
      cancel.js
      failure-matrix.js
    scenarios/                    # сценарии как данные (JSON/YAML)
      happy-path.yaml
      fail-payment.yaml
      fail-inventory.yaml
      cancel-after-reserve.yaml
      cancel-after-pay.yaml
    runner/                       # генератор сценариев (если не k6)
      README.md

  chaos/
    toxiproxy/                    # если используете Toxiproxy как “сетевой прокси”
      docker-compose.yaml
      scripts/
        latency.sh
        jitter.sh
        reset.sh
    kubernetes/
      chaos-mesh/                 # если используете Chaos Mesh
        latency.yaml
        loss.yaml
        bandwidth.yaml
      tc/                         # вариант с privileged DaemonSet + tc netem
        daemonset.yaml
        apply-latency.sh
        clear.sh

  migrations/
    order/
    payment/
    inventory/
    shipping/
    twopc/                        # если 2PC требует отдельные таблицы/журнал

  scripts/
    up-kind.sh
    helm-install.sh
    helm-uninstall.sh
    create-topics.sh
    seed-cart.sh
    run-scenario.sh               # запускает выбранный сценарий
    bench.sh                      # запускает серию прогонов + сбор метрик
    collect.sh                    # собирает результаты в CSV/JSON
    chaos-on.sh
    chaos-off.sh

  results/
    raw/                          # сырые замеры
    reports/                      # агрегированные отчёты, графики

  docs/
    c4/                           # диаграммы C4
    adr/                          # ADR по архитектурным решениям
    experiments.md                # методика экспериментов

  Dockerfile
  Makefile
  go.mod
  README.md
```

---

# Как это удовлетворяет требованиям

## 1) Реализация методов (2PC, TCC, Outbox, Saga Chor, Saga Orch)

* Общая “транзакционная библиотека” находится в `pkg/tx/*`.
* Сервисный код (`internal/<service>/app`) вызывает **одни и те же use-cases**, а метод выбирается конфигом:

  * `TX_MODE=twopc|tcc|saga_orch|saga_chor`
* Outbox реализуется независимо и используется во всех режимах:

  * `pkg/tx/outbox` + `internal/<service>/infra/outbox`.

## 2) Бенчмарки: latency, throughput, ресурсы (cpu/mem/network)

* Нагрузчик внутри кластера: `cmd/bench-runner` (или `bench/k6`).
* Метрики:

  * latency: на gateway/order endpoint + end-to-end `saga_duration_ms`
  * throughput: успешные транзакции/сек (`orders_success_total` в rate)
  * CPU/Memory: Kubernetes metrics (metrics-server) + собственные runtime metrics (`pkg/telemetry/runtime.go`)
  * Network: по Kubernetes (cAdvisor) или CNI-метрики; минимум — request/response bytes на уровне приложения.

Практически: ставите Prometheus/Grafana как отдельный optional stack (можно в `deploy/helm/observability`), но даже без него `bench-runner` может писать CSV в `results/raw/`.

## 3) Горизонтальное масштабирование

* Helm `values-experiments/scale-*.yaml` задаёт `replicaCount` по каждому сервису.
* Для корректности:

  * все обработчики событий и шаги **идемпотентны** (inbox/outbox, unique constraints).
  * consumer group Kafka обеспечивает параллелизм notification/choreography.

## 4) Сетевые помехи (latency/jitter)

Два адекватных способа:

* **Chaos Mesh** (наиболее удобно в Kubernetes): манифесты в `chaos/kubernetes/chaos-mesh/*.yaml`.
* **tc netem** через privileged DaemonSet: `chaos/kubernetes/tc/daemonset.yaml` + скрипты `apply-latency.sh`.

Вы выбираете один (для отчёта лучше Chaos Mesh: воспроизводимо и декларативно).

## 5) Различные сценарии (success/fail/cancel)

* Сценарии описываются как данные в `bench/scenarios/*.yaml`.
* `bench-runner`/k6 читает сценарий и выполняет последовательность действий:

  * happy-path
  * failure в любом сервисе (через `pkg/tx/faults` — управляемые “аварии” по заголовку/конфигу/percent)
  * cancel на любом этапе (order-service запускает компенсации/Cancel в TCC/Abort в 2PC)

---

# Практическая детализация сценариев и fault injection

## Включение отказов без “ручного падения pod”

В каждом сервисе добавляется:

* `FAULT_MODE` (none|always|percent)
* `FAULT_POINT` (before_db|after_db|before_reply|after_event|during_try|during_confirm|during_cancel)
* `FAULT_PERCENT` (например, 10)

Это позволяет воспроизводимо валить конкретный шаг, не меняя инфраструктуру.

## Cancel-сценарии

* `POST /orders/{id}/cancel` в order-service.
* Реализация зависит от режима:

  * Saga Orch: запускает компенсационные шаги.
  * Saga Chor: публикует `OrderCancelRequested` → участники компенсируют и публикуют `...Cancelled`.
  * TCC: вызывает Cancel для тех шагов, которые успели пройти Try.
  * 2PC: если ещё до commit — Abort; если после — отдельная бизнес-компенсация.

---

# Минимальный набор Helm values для экспериментов

В `deploy/helm/tx-lab-ecommerce-go/values-experiments/` держите профили, например:

* `saga-orch.yaml` (TX_MODE=saga_orch)
* `saga-chor.yaml`
* `tcc.yaml`
* `twopc.yaml`
* `scale-1.yaml`, `scale-3.yaml`
* `chaos-latency.yaml` (включает манифест chaos или sidecar proxy, в зависимости от подхода)

---

Если вы подтвердите, что вы используете **Kafka + Postgres + Redis** и хотите именно **Kubernetes kind/Helm** как единственный способ запуска, я могу:

1. дать пример `values-experiments/*.yaml` для каждого метода,
2. предложить единый формат `bench/scenarios/*.yaml`,
3. описать “контракт метрик” (какие метрики и где измеряются) так, чтобы вы могли прямо перенести это в НИР.
