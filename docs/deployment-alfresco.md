# Deployment — Alfresco Stack

This guide covers running Content Lake in any mode that includes Alfresco as a content source.
For Nuxeo-specific setup see [deployment-nuxeo.md](deployment-nuxeo.md).
For RAG service configuration see [deployment-rag.md](deployment-rag.md).

All commands run from `content-lake-app-deployment/`.

---

## Prerequisites

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
# 1. Authenticate to GitHub Container Registry
docker login ghcr.io

# 2. Enable Docker Model Runner in Docker Desktop

# 3. Export HXPR build credentials
export MAVEN_USERNAME=...
export MAVEN_PASSWORD=...
export NEXUS_USERNAME=...
export NEXUS_PASSWORD=...
# optional — only if needed:
export HXPR_GIT_AUTH_TOKEN=...

# 4. Pull the models (once)
docker model pull ai/mxbai-embed-large
docker model pull ai/qwen2.5

# 5. Start the Alfresco-only stack
STACK_MODE=alfresco docker compose up --build
```

Once healthy: [http://localhost](http://localhost)

## Other Modes

If you also want Nuxeo ingesters and routes, start the sibling Nuxeo stack first and use
`STACK_MODE=full`:

```bash
git clone https://github.com/aborroy/nuxeo-deployment.git ../nuxeo-deployment
(cd ../nuxeo-deployment && docker compose up -d)

STACK_MODE=full make up
```

---

## Compose Layout

Root entrypoint is `compose.yaml`, which uses `include` to pull in:

| File | Contents |
|---|---|
| `compose.alfresco.yaml` | ACS, Share, Control Center, Solr, Postgres, ActiveMQ, Transform Core AIO |
| `compose.hxpr.yaml` | hxpr-app, MongoDB, OpenSearch, IDP, LocalStack, Mockoon, router, REST |
| `compose.nuxeo.yaml` | Nuxeo ingesters (`profiles: ["full", "nuxeo"]`) |
| `compose.rag.yaml` | batch-ingester, live-ingester, rag-service, proxy, content-app |

Shared project name, network, and named volumes stay in the root file.

---

## Alfresco Requirements

The following Alfresco-side services are non-negotiable for Content Lake to work:

- **Alfresco Repository** with the `content-lake-repo-model` module installed so `cl:indexed` and
  `cl:excludeFromLake` aspects exist. The same module now also contains the repository-side ACL
  reconciliation hook that publishes permission changes to a persistent ActiveMQ queue. The ACS
  image is built locally in `acs/alfresco/`.
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
| `http://localhost/nuxeo/` | Nuxeo Web UI (only in `STACK_MODE=full` and when `nuxeo-deployment` is running) |
| `http://localhost/api/rag/` | RAG service |
| `http://localhost/api/sync/` | Sync API (Alfresco in `STACK_MODE=alfresco`, source-selecting in `STACK_MODE=full`) |
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
If you run `docker compose` directly: `STACK_MODE=alfresco docker compose --env-file .env.local up --build`.

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
| `CONTENT_LAKE_PERMISSION_SYNC_ENABLED` | `true` | Enable the Alfresco repository-side ACL publisher |
| `CONTENT_LAKE_PERMISSION_SYNC_BROKER_URL` | `tcp://activemq:61616` | ActiveMQ broker used for ACL change messages |
| `CONTENT_LAKE_PERMISSION_SYNC_QUEUE_NAME` | `contentlake.acl.changed` | Persistent queue consumed transactionally by `batch-ingester` |

On Linux, override `MODEL_RUNNER_URL` to `http://host.docker.internal:12434` in `.env.local`.

### Automatic ACL Reconciliation

When `CONTENT_LAKE_PERMISSION_SYNC_ENABLED=true`, Alfresco Repository records permission-affecting
changes after commit and publishes a persistent ActiveMQ message to
`CONTENT_LAKE_PERMISSION_SYNC_QUEUE_NAME`. `batch-ingester` consumes that queue and runs the same
ACL reconciliation logic exposed by `POST /api/sync/permissions`. This is the primary production
path for Alfresco ACL propagation because repository permission updates are not reliably emitted as
Event2 messages.

This catches permission changes made through:

- Alfresco UI
- Alfresco REST API
- repository-side rules, scripts, or admin tools

This flow is eventually consistent. A permission revocation is visible to search only after the
repository addon has published the queue message and `batch-ingester` has updated hxpr.

---

## Day-To-Day Commands

```bash
STACK_MODE=alfresco make up  # build and start the Alfresco-only stack
STACK_MODE=full make up      # include Nuxeo ingesters and routes
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

# Nuxeo full sync (requires `STACK_MODE=full`)
curl -u admin:admin -X POST 'http://localhost/api/sync/configured?sourceType=nuxeo'
```

---

## Deploying to AWS EC2

See [DEPLOY_EC2.md](../content-lake-app-deployment/DEPLOY_EC2.md) for a step-by-step guide to
running the full stack on an `r6i.xlarge` (4 vCPU / 32 GB RAM) Ubuntu instance, including Docker
Engine and Docker Model Runner installation, and cost-saving tips.
