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

## Verifying

Provisioning logs (idempotent - "Found existing ..." on subsequent runs):

```bash
docker logs content-lake-app-batch-ingester-1 2>&1 | grep -iE "graph|ontolog|provision"
```

Query the hxpr graph API directly (token via the IDP; run inside the hxpr-app container, which has
`curl`):

```bash
# from content-lake-app-deployment/ with the env sourced
set -a; . ./.env; [ -f ./.env.local ] && . ./.env.local; set +a
docker exec -e HXPR_IDP_CLIENT_ID -e HXPR_IDP_CLIENT_SECRET -e HXPR_IDP_USERNAME \
  -e HXPR_IDP_PASSWORD -e HXPR_REPOSITORY_ID content-lake-app-hxpr-app-1 sh -c '
    TOK=$(curl -s http://idp:8080/idp/connect/token -d grant_type=password \
      -d "scope=openid profile email" -d "client_id=$HXPR_IDP_CLIENT_ID" \
      -d "client_secret=$HXPR_IDP_CLIENT_SECRET" -d "username=$HXPR_IDP_USERNAME" \
      -d "password=$HXPR_IDP_PASSWORD" | sed -n "s/.*\"access_token\":\"\([^\"]*\)\".*/\1/p")
    curl -s -H "Authorization: Bearer $TOK" -H "HXCS-REPOSITORY: $HXPR_REPOSITORY_ID" \
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
- The hxpr service account (IDP client) must hold `content-lake-api.graph-configs.*` (or
  `hxpr.manage.everything`) for graphDB/ontology create and routing calls.
