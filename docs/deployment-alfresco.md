# Deployment — Alfresco Stack

This guide covers running the full Content Lake stack with Alfresco as a content source.
For Nuxeo-specific setup see [deployment-nuxeo.md](deployment-nuxeo.md).
For RAG service configuration see [deployment-rag.md](deployment-rag.md).

All commands run from `content-lake-app-deployment/`.

---

## Prerequisites

- **`nuxeo-deployment`** cloned at `../nuxeo-deployment` (sibling of this repo) — required even if
  you only use Alfresco; the Nuxeo service image is referenced by compose
- Docker Desktop with Docker Compose v2
- Docker Model Runner — enable in Docker Desktop settings, or install `docker-model-plugin` on Linux
- Access to `ghcr.io` for Hyland images
- Outbound access to GitHub (BuildKit fetches source contexts)
- HXPR build credentials (see below)

---

## Credentials

### HXPR build

| Variable | Source |
|---|---|
| `MAVEN_USERNAME` | Your GitHub username |
| `MAVEN_PASSWORD` | GitHub classic token with `read:packages` |
| `NEXUS_USERNAME` | Your Hyland Nexus account username |
| `NEXUS_PASSWORD` | Your Hyland Nexus account password |
| `HXPR_GIT_AUTH_TOKEN` | GitHub token scoped to `HylandSoftware/hxpr` (only if not cloneable anonymously) |

Create a classic token at [github.com/settings/tokens/new](https://github.com/settings/tokens/new)
with at least `read:packages`. If your org enforces SSO, authorize the token for SSO before using.

Hyland Nexus credentials are for `https://artifacts.alfresco.com/nexus/`. Request access from
the Hyland/Alfresco team if you do not already have them.

---

## First Run

```bash
# 1. Clone the Nuxeo sibling (required even if not using Nuxeo)
git clone https://github.com/aborroy/nuxeo-deployment.git ../nuxeo-deployment

# 2. Authenticate to GitHub Container Registry
docker login ghcr.io

# 3. Enable Docker Model Runner in Docker Desktop

# 4. Export HXPR build credentials
export MAVEN_USERNAME=...
export MAVEN_PASSWORD=...
export NEXUS_USERNAME=...
export NEXUS_PASSWORD=...
# optional — only if needed:
export HXPR_GIT_AUTH_TOKEN=...

# 5. Pull the models (once)
docker model pull ai/mxbai-embed-large
docker model pull ai/qwen2.5

# 6. Start the stack
docker compose up --build
```

Once healthy: [http://localhost](http://localhost)

---

## Compose Layout

Root entrypoint is `compose.yaml`, which uses `include` to pull in:

| File | Contents |
|---|---|
| `compose.alfresco.yaml` | ACS, Share, Control Center, Solr, Postgres, ActiveMQ, Transform Core AIO |
| `compose.hxpr.yaml` | hxpr-app, MongoDB, OpenSearch, IDP, LocalStack, Mockoon, router, REST |
| `compose.nuxeo.yaml` | Nuxeo server + Postgres (can be omitted if not using Nuxeo) |
| `compose.rag.yaml` | batch-ingester, live-ingester, nuxeo-batch-ingester, nuxeo-live-ingester, rag-service, proxy, content-app |

Shared project name, network, and named volumes stay in the root file.

---

## Alfresco Requirements

The following Alfresco-side services are non-negotiable for Content Lake to work:

- **Alfresco Repository** with the `content-lake-repo-model` module installed so `cl:indexed` and
  `cl:excludeFromLake` aspects exist. The ACS image is built locally in `acs/alfresco/`.
- **ActiveMQ** configured for Alfresco Event2 so `live-ingester` can consume `alfresco.repo.event2`
- **Alfresco Transform Core AIO** for text extraction during ingestion
- **Alfresco Search Services / Solr** wired with `secureComms=secret`

---

## Public Endpoints

Port `80` (configurable via `PUBLIC_PORT`):

| URL | Service |
|---|---|
| `http://localhost/` | ACA-based Content Lake UI |
| `http://localhost/alfresco/` | Alfresco Repository |
| `http://localhost/share/` | Alfresco Share |
| `http://localhost/admin/` | Alfresco Control Center |
| `http://localhost/api-explorer/` | API Explorer |
| `http://localhost/nuxeo/` | Nuxeo Web UI |
| `http://localhost/api/rag/` | RAG service |
| `http://localhost/api/sync/` | Sync API (defaults to Alfresco; add `?sourceType=nuxeo` for Nuxeo) |
| `http://localhost:5601/` | OpenSearch Dashboards (not through proxy) |

---

## Configuration

Defaults live in `.env`. Override locally in `.env.local` (git-ignored, never committed):

```bash
# Example .env.local
HXPR_GIT_REF=main
PUBLIC_PORT=9090
```

Docker Compose only auto-loads `.env`. The `Makefile` passes `--env-file .env.local` automatically.
If you run `docker compose` directly: `docker compose --env-file .env.local up --build`.

### Key variables

| Variable | Default | Purpose |
|---|---|---|
| `HXPR_GIT_URL` | `https://github.com/HylandSoftware/hxpr.git` | HXPR source repo |
| `HXPR_GIT_REF` | `feature/CIN-1509-CreateEmbeddingAPI` | HXPR branch/tag |
| `HXPR_GIT_SHA` | _(empty)_ | Pin to a specific commit for reproducible builds |
| `HXPR_LOCAL_IMAGE` | — | Local tag for the built HXPR app |
| `CONTENT_LAKE_GIT_CONTEXT` | `https://github.com/aborroy/alfresco-content-lake.git#main` | Content Lake source context |
| `CONTENT_LAKE_UI_GIT_CONTEXT` | `https://github.com/aborroy/alfresco-content-lake-ui.git#main` | UI source context |
| `ACA_TAG` | `7.3.0` | Alfresco Content App version |
| `PUBLIC_PORT` | `80` | Host port for the reverse proxy |
| `MODEL_RUNNER_URL` | `http://model-runner.docker.internal` | LLM inference backend |
| `EMBEDDING_MODEL` | `ai/mxbai-embed-large` | Embedding model |
| `LLM_MODEL` | `ai/qwen2.5` | LLM for RAG |

On Linux, override `MODEL_RUNNER_URL` to `http://host.docker.internal:12434` in `.env.local`.

---

## Day-To-Day Commands

```bash
make up       # build and start (auto-loads .env.local if present)
make down     # stop and remove containers
make logs     # follow logs for all services
make ps       # show running services
make config   # render the resolved compose configuration
```

---

## Triggering a Sync

```bash
# Alfresco full sync
curl -u admin:admin -X POST 'http://localhost/api/sync/configured'

# Nuxeo full sync
curl -u admin:admin -X POST 'http://localhost/api/sync/configured?sourceType=nuxeo'
```

---

## Deploying to AWS EC2

See [DEPLOY_EC2.md](../content-lake-app-deployment/DEPLOY_EC2.md) for a step-by-step guide to
running the full stack on an `r6i.xlarge` (4 vCPU / 32 GB RAM) Ubuntu instance, including Docker
Engine and Docker Model Runner installation, and cost-saving tips.
