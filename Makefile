.PHONY: \
  help \
  kind-create kind-delete kind-context \
  docker-build kind-load \
  helm-install helm-uninstall \
  migrate \
  cli-run bench \
  logs-order pf-order

# ----------------------------
# Project settings
# ----------------------------
PROJECT ?= tx-lab-ecommerce-go
KIND_CLUSTER ?= shop-demo
NS ?= txlab

# Docker images
REGISTRY ?=
TAG ?= latest

# Services list
SERVICES := order-service payment-service inventory-service shipping-service notification-service cli

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
# Docker build/load
# ----------------------------
docker-build:
	@for svc in $(SERVICES); do \
		echo "Building $$svc..."; \
		docker build --build-arg SERVICE=$$svc -t $(PROJECT)/$$svc:$(TAG) . ; \
	done

kind-load:
	@for svc in $(SERVICES); do \
		echo "Loading $$svc into kind cluster $(KIND_CLUSTER)..."; \
		kind load docker-image $(PROJECT)/$$svc:$(TAG) --name $(KIND_CLUSTER); \
	done

helm-install:
	helm upgrade --install $(PROJECT) deploy/helm/txlab --namespace $(NS) --create-namespace \
		--set image.repository=$(PROJECT) --set image.tag=$(TAG)

helm-uninstall:
	helm uninstall $(PROJECT) --namespace $(NS) || true

migrate:
	@echo "Apply SQL migrations inside each Postgres pod." 
	@echo "Use kubectl exec into the postgres pods and run /tmp/*.sql from deploy/sql."

cli-run:
	go run ./cmd/cli

bench:
	go run ./cmd/cli -run bench -mode twopc

logs-order:
	kubectl logs -n $(NS) deploy/$(ORDER_DEPLOY) --tail=200 -f

pf-order:
	kubectl port-forward -n $(NS) svc/$(ORDER_SVC) 8080:8080
