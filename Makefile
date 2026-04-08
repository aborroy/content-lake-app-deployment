# =============================================================
# Content Lake — Deployment Makefile
# =============================================================
# Usage:
#   make up-alfresco        Alfresco + HXPR + RAG + ACA UI  (~17 services)
#   make up-nuxeo           Nuxeo + HXPR + RAG  (~13 services)
#   make up-full            Alfresco + Nuxeo + HXPR + RAG  (~19 services)
#   make up-demo            Full + standalone demo UI at /  (~20 services)
#   make down               Stop all services
#   make logs               Follow logs
#   make ps                 Show service status
#   make config             Dry-run: render resolved compose configuration
#   make clean              Stop + remove all volumes  [DESTRUCTIVE]
# =============================================================

export DOCKER_BUILDKIT=1
export COMPOSE_DOCKER_CLI_BUILD=1

LOAD_ENV := set -a && . ./.env && if [ -f ./.env.local ]; then . ./.env.local; fi && set +a &&

ifneq (,$(wildcard .env.local))
  ENV_ARGS := --env-file .env.local
else
  ENV_ARGS :=
endif

DC := $(LOAD_ENV) docker compose $(ENV_ARGS)

.PHONY: help up-alfresco up-nuxeo up-full up-demo down logs ps config clean

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' Makefile | \
	  awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

up-alfresco: ## Alfresco source — core services (~17)
	$(LOAD_ENV) \
	  NGINX_SYNC_DEFAULT_BACKEND=batch-ingester:9090 \
	  NGINX_ROOT_DIRECTIVE="return 302 /aca/;" \
	  RAG_PERMISSION_SOURCE_IDS="$${RAG_PERMISSION_SOURCE_IDS:-$${HXPR_REPOSITORY_ID:-default}}" \
	  docker compose $(ENV_ARGS) --profile alfresco up --build -d
	@$(call _urls,alfresco)

up-nuxeo: ## Nuxeo source — start ../nuxeo-deployment first, then this
	@echo "→ Bringing up Nuxeo server (../nuxeo-deployment)..."
	$(LOAD_ENV) docker compose -f ../nuxeo-deployment/compose.yaml up -d
	$(LOAD_ENV) \
	  NGINX_SYNC_DEFAULT_BACKEND=nuxeo-batch-ingester:9093 \
	  NGINX_ROOT_DIRECTIVE="return 302 /nuxeo/;" \
	  RAG_PERMISSION_SOURCE_IDS="$${RAG_PERMISSION_SOURCE_IDS:-$${NUXEO_SOURCE_ID:-local}}" \
	  docker compose $(ENV_ARGS) --profile nuxeo up --build -d
	@$(call _urls,nuxeo)

up-full: ## Alfresco + Nuxeo — start ../nuxeo-deployment first, then this
	@echo "→ Bringing up Nuxeo server (../nuxeo-deployment)..."
	$(LOAD_ENV) docker compose -f ../nuxeo-deployment/compose.yaml up -d
	$(LOAD_ENV) \
	  NGINX_SYNC_DEFAULT_BACKEND=batch-ingester:9090 \
	  NGINX_ROOT_DIRECTIVE="return 302 /aca/;" \
	  RAG_PERMISSION_SOURCE_IDS="$${RAG_PERMISSION_SOURCE_IDS:-$${HXPR_REPOSITORY_ID:-default},$${NUXEO_SOURCE_ID:-local}}" \
	  docker compose $(ENV_ARGS) --profile full up --build -d
	@$(call _urls,full)

up-demo: ## Full stack + demo UI at / — start ../nuxeo-deployment first, then this
	@echo "→ Bringing up Nuxeo server (../nuxeo-deployment)..."
	$(LOAD_ENV) docker compose -f ../nuxeo-deployment/compose.yaml up -d
	$(LOAD_ENV) \
	  NGINX_SYNC_DEFAULT_BACKEND=batch-ingester:9090 \
	  NGINX_ROOT_DIRECTIVE="proxy_pass http://content-lake-app-ui:80;" \
	  RAG_PERMISSION_SOURCE_IDS="$${RAG_PERMISSION_SOURCE_IDS:-$${HXPR_REPOSITORY_ID:-default},$${NUXEO_SOURCE_ID:-local}}" \
	  docker compose $(ENV_ARGS) --profile demo up --build -d
	@$(call _urls,demo)

down: ## Stop and remove containers (data volumes preserved)
	$(DC) --profile '*' down
	$(LOAD_ENV) docker compose -f ../nuxeo-deployment/compose.yaml down 2>/dev/null || true

logs: ## Follow logs for all running services
	$(DC) logs -f

ps: ## Show running services and health status
	$(DC) ps

config: ## Dry-run: render the resolved compose configuration
	$(LOAD_ENV) \
	  NGINX_SYNC_DEFAULT_BACKEND=batch-ingester:9090 \
	  NGINX_ROOT_DIRECTIVE="return 302 /aca/;" \
	  docker compose $(ENV_ARGS) config

clean: ## Stop containers and remove ALL volumes [DESTRUCTIVE — wipes all data]
	@echo "WARNING: This removes all persistent data (Alfresco, MongoDB, OpenSearch, etc.)"
	@read -p "Are you sure? [y/N] " confirm && [ "$$confirm" = "y" ] || exit 1
	$(DC) --profile '*' down -v
	$(LOAD_ENV) docker compose -f ../nuxeo-deployment/compose.yaml down -v 2>/dev/null || true

# ── Internal ──────────────────────────────────────────────────────────────────

define _urls
	@set -a; . ./.env; if [ -f ./.env.local ]; then . ./.env.local; fi; set +a; \
	  base="http://$${SERVER_NAME:-localhost}"; \
	  p="$${PUBLIC_PORT:-80}"; \
	  [ "$$p" != "80" ] && base="$$base:$$p"; \
	  echo ""; \
	  echo "Stack starting ($(1)). Endpoints once healthy:"; \
	  echo "  RAG API  → $$base/api/rag"; \
	  if [ "$(1)" != "nuxeo" ]; then \
	    echo "  ACA      → $$base/aca/"; \
	    echo "  Alfresco → $$base/alfresco"; \
	  fi; \
	  if [ "$(1)" != "alfresco" ]; then \
	    echo "  Nuxeo    → $$base/nuxeo/ui/"; \
	  fi; \
	  if [ "$(1)" = "demo" ]; then \
	    echo "  Demo UI  → $$base/"; \
	  fi; \
	  echo ""
endef
