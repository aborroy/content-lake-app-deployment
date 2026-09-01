# Knowledge Graph (GraphRAG) backend

The Content Lake GraphRAG features use the hxpr Graph API, which is backed by Dgraph. This stack
ships that backend so the graph API is functional end to end. It is off by default and adds no
overhead unless enabled.

## What the stack provides

- **Dgraph** (`compose.hxpr.yaml`): `dgraph-zero` + `dgraph-alpha` (multi-tenant, ACL enabled). The
  ACL HMAC secret is mounted from `hxpr/dgraph/acl-secret/hmac_secret_file` (demo secret, local only).
- **hxpr-app graph configuration** (`compose.hxpr.yaml`, via `JAVA_OPTIONS`):
  - The hxpr graph REST API is behind a feature flag; it is enabled with
    `-Dfeature.flag.default.flags.content-context-graph-api=${HXPR_GRAPH_API_FEATURE:-true}`.
  - `graphdb.enabled=true`, `graphdb.backend=dgraph`, and `graphdb.dgraph.multitenant.alpha.*`
    point hxpr at `dgraph-alpha` (gRPC `9080`, admin `8080`).
  - `ontology.s3.bucket=ontology-bucket-1` is where uploaded ontology YAML is stored.
- **LocalStack seeding** (`localstack/init-additional.sh`, with `secretsmanager` added to
  `SERVICES`):
  - Secret `dgraph/acl/credentials` = `{"root-username":"groot","root-password":"password"}`
    (Dgraph ACL root).
  - Secret `dgraph-namespace-credentials` = `{}` (hxpr writes per-namespace credentials here).
  - S3 bucket `ontology-bucket-1` (hxpr requires it to exist; it does not create it).
- **Client-side provisioning**: the Alfresco `batch-ingester` runs an idempotent startup step
  (`GraphProvisioningService`) that ensures the `content-lake` graphDB (schema version `v2`), the
  base ontology, and an ontology route exist. It is gated by `HXPR_GRAPH_ENABLED`
  (`compose.content-lake.yaml`).

## Enabling it

Bring the stack up with graph provisioning enabled:

```bash
HXPR_GRAPH_ENABLED=true make up-alfresco        # or: HXPR_GRAPH_ENABLED=true make up-alfresco local
```

`HXPR_GRAPH_ENABLED` (default `false`) toggles the batch-ingester provisioning step. The hxpr graph
API feature flag defaults to on (`HXPR_GRAPH_API_FEATURE=true`); set it to `false` to hide the API.

Because provisioning creates the graphDB in Dgraph, always start from clean volumes for a first run
(`make clean`), consistent with the rest of the stack.

### Entity extraction (asynchronous)

Entity extraction runs off the ingest hot path: each ingester submits the extraction LLM call to a
bounded background executor and returns immediately, so document ingestion latency is not dominated
by extraction. Graph population is therefore **eventually consistent** - a document is searchable
(vector/keyword) as soon as it is ingested, and its `GlobalEntity` nodes and `has_global_entity`
edges appear shortly after. Controls (bound on every ingester via relaxed binding, defaults shown):

```bash
HXPR_GRAPH_EXTRACTION_ASYNC=true            # false runs extraction inline on the ingest thread
HXPR_GRAPH_EXTRACTION_WORKER_THREADS=2      # background extraction workers
HXPR_GRAPH_EXTRACTION_QUEUE_CAPACITY=500    # on saturation, the ingest thread runs it inline (backpressure)
```

Note for the eval harness: because extraction no longer blocks ingestion, `cleval ingest` verifies
embeddings without waiting on entity extraction; allow a short delay after ingestion before relying
on `graphSources` in `/api/rag/graph-prompt`.

## Verifying

Provisioning logs (idempotent - "Found existing ..." on subsequent runs):

```bash
docker logs content-lake-app-batch-ingester-1 2>&1 | grep -iE "graph|ontolog|provision"
```

Query the engine graph API directly (HTTP Basic; run inside the hxpr-app container, which has
`curl`):

```bash
# from content-lake-app-deployment/ with the env sourced
set -a; . ./.env; [ -f ./.env.local ] && . ./.env.local; set +a
docker exec -e HXPR_USERNAME -e HXPR_PASSWORD -e HXPR_REPOSITORY_ID content-lake-app-hxpr-app-1 sh -c '
    curl -s -u "$HXPR_USERNAME:$HXPR_PASSWORD" -H "HXCS-REPOSITORY: $HXPR_REPOSITORY_ID" \
      "http://localhost:8080/api/graph/graphdbs?limit=100"'
```

Expected: one graphDB named `content-lake` with `version: v2`, one ontology `content-lake-base`, and
a `graphdbs/{id}/config` route mapping `content.sys_primaryType == "SysFile"` to that ontology.

## Notes and limitations

- The ACL secret and Dgraph root credentials here are **demo values for local use only**.
- hxpr owns the graph schema (fixed, versioned as `v2`, ACL-aware). Clients never push a schema;
  they select the version when creating the graphDB.
- The uploaded ontology YAML is stored verbatim by hxpr (no parse-time validation); it declares the
  base entity vocabulary (Document, Person, Organization, Location, Concept) and relationships.
- The engine user (`HXPR_USERNAME`) must hold `content-lake-api.graph-configs.*` (or
  `hxpr.manage.everything`) for graphDB/ontology create and routing calls.
