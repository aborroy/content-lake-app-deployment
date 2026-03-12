# =============================================================
# Alfresco Content Lake — Unified Stack Makefile
# =============================================================

export DOCKER_BUILDKIT=1
export COMPOSE_DOCKER_CLI_BUILD=1

# If .env.local exists:
#  1. Pass --env-file so its values are used for compose-file interpolation.
#  2. Prefix every compose command with "set -a && . .env.local && set +a &&"
#     so Docker secrets (which read os.Getenv, not the --env-file context)
#     can find MAVEN_USERNAME, MAVEN_PASSWORD, NEXUS_* and HXPR_GIT_AUTH_TOKEN.
ifneq (,$(wildcard .env.local))
  ENV_ARGS  := --env-file .env.local
  LOAD_ENV  := set -a && . ./.env.local && set +a &&
else
  ENV_ARGS  :=
  LOAD_ENV  :=
endif

DC := $(LOAD_ENV) docker compose $(ENV_ARGS)

.PHONY: help up down logs ps config clean

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' Makefile | \
	  awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

up: ## Build images (if needed) and start all services
	$(DC) up --build -d
	@echo ""
	@echo "Stack is starting. Key endpoints (once healthy):"
	@echo "  ACA / Content Lake UI → http://localhost:$${PUBLIC_PORT:-8080}/"
	@echo "  Alfresco             → http://localhost:$${PUBLIC_PORT:-8080}/alfresco"
	@echo "  Share                → http://localhost:$${PUBLIC_PORT:-8080}/share"
	@echo "  Control Center       → http://localhost:$${PUBLIC_PORT:-8080}/admin"
	@echo "  RAG Service          → http://localhost:$${PUBLIC_PORT:-8080}/api/rag"
	@echo ""

down: ## Stop and remove containers (preserves volumes)
	$(DC) down

logs: ## Follow logs for all services
	$(DC) logs -f

ps: ## Show running services and their status
	$(DC) ps

config: ## Render the resolved docker compose configuration
	$(DC) config

clean: ## Stop containers and remove all volumes (DESTRUCTIVE)
	@echo "WARNING: This removes all persistent data (Alfresco, MongoDB, OpenSearch, etc.)"
	@read -p "Are you sure? [y/N] " confirm && [ "$$confirm" = "y" ] || exit 1
	$(DC) down -v
