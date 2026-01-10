.PHONY: \
  help \
  kind-create kind-delete kind-context \
  k8s-apply-order k8s-delete \
  docker-build kind-load \
  docker-build-order kind-load-order k8s-apply-order-service migrate-order \
  logs-order pf-order \
  not-implemented

# ----------------------------
# Project settings
# ----------------------------
PROJECT ?= tx-lab-ecommerce-go
KIND_CLUSTER ?= shop-demo
NS ?= txlab

# Docker images
REGISTRY ?=
TAG ?= latest

# Services list (future-ready)
SERVICES := order-service payment-service inventory-service shipping-service notification-service

# For now only order-service is implemented/deployed
IMPLEMENTED := order-service

# K8s naming: keep consistent and explicit
ORDER_DEPLOY := order
ORDER_SVC := order

# ----------------------------
# Help
# ----------------------------
help:
	@echo "Targets:"
	@echo "  kind-create            Create kind cluster ($(KIND_CLUSTER))"
	@echo "  kind-delete            Delete kind cluster ($(KIND_CLUSTER))"
	@echo "  kind-context           Show current kube context"
	@echo "  docker-build-order     Build docker image for order-service"
	@echo "  kind-load-order        Load order-service image into kind"
	@echo "  k8s-apply-order-service   Apply k8s manifests for Postgres + order-service"
	@echo "  migrate-order          Apply SQL migration for orderdb"
	@echo "  logs-order             Tail logs of order-service"
	@echo "  pf-order               Port-forward order-service to localhost:8080"
	@echo ""
	@echo "Future-ready (stubs):"
	@echo "  docker-build           Build images for all services (only order is active now)"
	@echo "  kind-load              Load images for all services (only order is active now)"

# ----------------------------
# kind helpers
# ----------------------------
kind-create:
	@kind get clusters | grep -qx "$(KIND_CLUSTER)" && \
		echo "kind cluster '$(KIND_CLUSTER)' already exists" || \
		kind create cluster --name $(KIND_CLUSTER)

kind-delete:
	kind delete cluster --name $(KIND_CLUSTER)

kind-context:
	kubectl config current-context
	kubectl cluster-info || true

# ----------------------------
# Docker build/load (generic, future-ready)
# Currently only builds/loads IMPLEMENTED services to avoid confusion.
# ----------------------------
docker-build:
	@for svc in $(IMPLEMENTED); do \
		echo "Building $$svc..."; \
		docker build --build-arg SERVICE=$$svc -t $(PROJECT)/$$svc:$(TAG) . ; \
	done

kind-load:
	@for svc in $(IMPLEMENTED); do \
		echo "Loading $$svc into kind cluster $(KIND_CLUSTER)..."; \
		kind load docker-image $(PROJECT)/$$svc:$(TAG) --name $(KIND_CLUSTER); \
	done

# ----------------------------
# order-service concrete targets
# ----------------------------
docker-build-order:
	docker build --build-arg SERVICE=order-service -t $(PROJECT)/order-service:$(TAG) .

kind-load-order:
	kind load docker-image $(PROJECT)/order-service:$(TAG) --name $(KIND_CLUSTER)

# Apply minimal k8s manifests for ONLY Postgres + order-service
# (You keep deploy/k8s/order-service.yaml as the single source)
k8s-apply-order-service:
	kubectl apply -f deploy/k8s/order-service.yaml

k8s-delete:
	kubectl delete ns $(NS) --ignore-not-found=true

migrate-order:
	kubectl cp deploy/sql/order.sql $(NS)/postgres-0:/tmp/order.sql
	kubectl exec -n $(NS) postgres-0 -- sh -c "psql -U postgres -d orderdb -v ON_ERROR_STOP=1 -f /tmp/order.sql"

logs-order:
	kubectl logs -n $(NS) deploy/$(ORDER_DEPLOY) --tail=200 -f

pf-order:
	kubectl port-forward -n $(NS) svc/$(ORDER_SVC) 8080:8080

# ----------------------------
# Explicit stubs for other services (so Makefile is for whole project)
# ----------------------------
not-implemented:
	@echo "This target is a placeholder. Only order-service is implemented right now."
	@exit 0
