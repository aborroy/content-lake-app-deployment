# Deployment -- RAG Service

The `rag-service` Spring Boot app provides semantic search, hybrid search, and RAG (Retrieval-
Augmented Generation) over content indexed by the Content Lake ingesters.

---

## What It Does

- **Semantic search** -- kNN vector search against hxpr embeddings
- **Hybrid search** -- combines kNN with BM25 keyword search using Reciprocal Rank Fusion (RRF)
- **RAG prompt** -- retrieves context chunks and sends them with the user query to the configured LLM
- **Streaming RAG** -- same as RAG prompt but streams the LLM response via SSE
- **Conversation memory** -- maintains session state for multi-turn conversations

The service is nearly source-agnostic: it queries hxpr directly and uses `source_type` from
`cin_ingestProperties` to construct source-specific "open document" links (Alfresco Share URL vs.
Nuxeo Web UI URL).

---

## Dependencies

- `content-lake-core` (hxpr client, data model, chunking)
- `content-lake-spi` (SPI interfaces)
- hxpr platform (MongoDB + OpenSearch + embedding API)
- LLM inference backend (Docker Model Runner by default)

---

## Configuration

```yaml
hxpr:
  base-url: http://hxpr-app:8080
  token-url: http://idp:8080/realms/hyland/protocol/openid-connect/token
  client-id: content-lake-client
  client-secret: ...

spring:
  ai:
    openai:
      base-url: http://model-runner.docker.internal  # Docker Model Runner
      api-key: ignored                               # required by Spring AI client but unused
      embedding:
        model: ai/mxbai-embed-large
      chat:
        model: ai/qwen2.5

search:
  hybrid:
    enabled: true
    strategy: rrf          # rrf or weighted
    vector-weight: 0.7
    text-weight: 0.3
    initial-candidates: 75
    final-results: 20

rag:
  default-top-k: 15
  default-min-score: 0.01
  max-context-length: 20000
  reranker:
    enabled: false         # enable when a reranker endpoint is available
```

On Linux, override `MODEL_RUNNER_URL` (set as `spring.ai.openai.base-url`) to
`http://host.docker.internal:12434` in `.env.local`.

---

## Authentication

All `/api/rag/**` endpoints except `/api/rag/health` require **HTTP Basic Auth**. Credentials are
validated against the configured content source(s):

1. **Alfresco** -- via `POST .../authentication/versions/1/tickets` (tried first)
2. **Nuxeo** -- via `GET .../api/v1/me` (tried if Alfresco is unreachable or unconfigured)

The authenticated username is then used to resolve the caller's group memberships (via the service
account) and build the `sys_racl` permission filter passed to hxpr. This ensures search results are
scoped to documents the caller is actually allowed to read.

`/api/rag/health` and `/actuator/**` are public (no credentials required).

### Unauthenticated requests

Requests without a valid `Authorization: Basic ...` header receive **HTTP 401**.

```bash
# Correct -- with credentials
curl -u admin:admin -X POST http://localhost/api/rag/search/semantic \
  -H 'Content-Type: application/json' \
  -d '{"query": "retention policy", "topK": 5}'

# Rejected -- no credentials → 401
curl -X POST http://localhost/api/rag/search/semantic \
  -H 'Content-Type: application/json' \
  -d '{"query": "retention policy", "topK": 5}'
```

---

## REST API

All endpoints are under `/api/rag/` (proxied through nginx). Include Basic Auth on every request
(see [Authentication](#authentication) above).

### Semantic search

```http
POST /api/rag/search/semantic
Authorization: Basic <base64(user:password)>
Content-Type: application/json

{
  "query": "document retention policy",
  "topK": 5,
  "minScore": 0.7
}
```

### Hybrid search

```http
POST /api/rag/search/hybrid
Authorization: Basic <base64(user:password)>
Content-Type: application/json

{
  "query": "document retention policy",
  "topK": 5
}
```

### RAG prompt

```http
POST /api/rag/prompt
Authorization: Basic <base64(user:password)>
Content-Type: application/json

{
  "question": "What is our document retention policy?",
  "topK": 5
}
```

### Streaming RAG (SSE)

```http
POST /api/rag/chat/stream
Authorization: Basic <base64(user:password)>
Content-Type: application/json
Accept: text/event-stream

{
  "sessionId": "optional-session-id",
  "question": "What is our document retention policy?"
}
```

### Evaluation smoke check (opt-in)

```http
POST /api/rag/evaluate
Authorization: Basic <base64(user:password)>
Content-Type: application/json

[
  {"question": "...", "expectedAnswer": "...", "expectedSourceIds": ["policy.txt"]}
]
```

Runs a small caller-supplied sample set through the pipeline and returns coarse retrieval-hit and
faithfulness signals. Disabled unless `RAG_EVALUATION_ENABLED=true`. This is a quick in-cluster sanity
check, not the quality gate: the `content-lake-eval` harness (`cleval run` / `cleval compare`) remains
the authoritative RAGAS-style measurement.

`compose.content-lake.yaml` exposes the rag-service retrieval and generation knobs as environment
variables, all **default off**, so the baseline pipeline is unchanged unless a flag is set:

- Re-ranking and diversification: `RAG_RERANKER_ENABLED` (`RAG_RERANKER_URL`, `RAG_RERANKER_TOP_N`),
  `RAG_MMR_ENABLED` (`RAG_MMR_LAMBDA`, `RAG_MMR_POOL_SIZE`).
- Query expansion and self-RAG: `RAG_MULTI_QUERY_ENABLED`, `RAG_HYDE_ENABLED`,
  `RAG_QUERY_DECOMPOSITION_ENABLED`, and the relevance gate `RAG_RETRIEVAL_GRADING_ENABLED`.
- Context and generation: `RAG_RETRIEVAL_SMALL_TO_BIG_ENABLED` (expand a hit to its parent section),
  `RAG_CITATION_VERIFY_ENABLED` (flag answer claims unsupported by the cited context, adding
  `verified` / `unsupportedClaims` to the prompt response), `RAG_CONVERSATION_SUMMARY_ENABLED`
  (persistent running summary under the hxpr `_sessions/` folder), and per-request `inferFilters` on
  `/api/rag/prompt` (LLM-inferred date/mime/path filters).
- Graph-augmented retrieval: `RAG_GRAPH_ENABLED` turns on the rag-service `/api/rag/graph-prompt`
  endpoint and graph expansion; the graph backend and provisioning are covered in
  [deployment-graph.md](deployment-graph.md).

### Health check (public)

```http
GET /api/rag/health
```

---

## Security

`RagSecurityConfig` enforces HTTP Basic Auth for all search and prompt endpoints. The
`MultiSourceAuthenticationProvider` validates incoming credentials by calling the upstream
repository (Alfresco tickets API, then Nuxeo `/me`) with a 3 s connect timeout. Connection
failures are treated as "source unavailable" and the next source is tried; if all sources fail
or reject the credentials, a `401 Unauthorized` is returned.

The service account credentials (`ALFRESCO_INTERNAL_USERNAME` / `ALFRESCO_INTERNAL_PASSWORD`,
`NUXEO_USERNAME` / `NUXEO_PASSWORD`) are used only for internal operations (group membership
lookups, metadata enrichment) -- they are never used to validate incoming requests.

---

## Multi-Source Results

When results come from both Alfresco and Nuxeo, `SourceMetadataResolver` builds the "open in
source" link using `source_type` from `cin_ingestProperties`:

- `alfresco` → Alfresco Share URL: `{alfrescoBaseUrl}/share/page/document-details?nodeRef=workspace://...`
- `nuxeo` → Nuxeo Web UI URL: `{nuxeoBaseUrl}/nuxeo/ui/#!/doc/{uid}`

Permission filtering (`sys_racl`) works at the hxpr level and is already multi-source aware.

---

## Conversation Memory

The `ConversationMemoryService` maintains session state in `InMemoryConversationMemoryStore`.
Sessions are keyed by `sessionId` (UUID). Each session stores a list of `ConversationTurn` (user
query + assistant response).

For production, replace `InMemoryConversationMemoryStore` with a Redis or database-backed
implementation if multiple rag-service instances or pod restarts are expected.

---

## Observability

Metrics are exposed via Micrometer at `/actuator/prometheus`. Key metrics:

- `rag_requests_total` -- total RAG requests
- `rag_latency_seconds` -- end-to-end latency
- `search_results_count` -- results returned per query
- `embedding_requests_total` -- embedding API calls

Health: `/actuator/health` (public, no auth required).
Info: `/actuator/info` (public).
