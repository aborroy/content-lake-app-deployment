# Deployment — RAG Service

The `rag-service` Spring Boot app provides semantic search, hybrid search, and RAG (Retrieval-
Augmented Generation) over content indexed by the Content Lake ingesters.

---

## What It Does

- **Semantic search** — kNN vector search against hxpr embeddings
- **Hybrid search** — combines kNN with BM25 keyword search using Reciprocal Rank Fusion (RRF)
- **RAG prompt** — retrieves context chunks and sends them with the user query to the configured LLM
- **Streaming RAG** — same as RAG prompt but streams the LLM response via SSE
- **Conversation memory** — maintains session state for multi-turn conversations

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
  base-url: http://hxpr-app:8082
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
    initial-candidates: 20
    final-results: 5

rag:
  max-chunks: 10
  chunk-overlap: 0
  rerank:
    enabled: false         # enable when a cross-encoder model is available
```

On Linux, override `MODEL_RUNNER_URL` (set as `spring.ai.openai.base-url`) to
`http://host.docker.internal:12434` in `.env.local`.

---

## REST API

All endpoints are under `/api/rag/` (proxied through nginx).

### Semantic search

```http
POST /api/rag/search/semantic
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
Content-Type: application/json

{
  "query": "document retention policy",
  "topK": 5
}
```

### RAG prompt

```http
POST /api/rag/prompt
Content-Type: application/json

{
  "query": "What is our document retention policy?",
  "topK": 5
}
```

### Streaming RAG (SSE)

```http
POST /api/rag/chat/stream
Content-Type: application/json
Accept: text/event-stream

{
  "sessionId": "optional-session-id",
  "query": "What is our document retention policy?"
}
```

---

## Security

The `rag-service` needs its own `SecurityConfig`. Current options:

**Option A (recommended for initial phase):** Permit-all behind network policy. The proxy and
network topology prevent direct public access to the rag-service port.

**Option B:** OAuth2/OIDC via the hxpr IDP. Requires configuring the rag-service as an OAuth2
resource server and issuing tokens through Keycloak.

The Alfresco-specific `SecurityConfig` (in `content-lake-source-alfresco`) does not apply to
`rag-service`. A minimal standalone `SecurityConfig` must be present in the `rag-service` module.

---

## Multi-Source Results

When results come from both Alfresco and Nuxeo, `SourceMetadataResolver` builds the "open in
source" link using `source_type` from `cin_ingestProperties`:

- `alfresco` → Alfresco Share URL: `{alfrescoBaseUrl}/share/page/document-details?nodeRef=workspace://...`
- `nuxeo` → Nuxeo Web UI URL: `{nuxeoBaseUrl}/nuxeo/ui/#!/doc/{uid}`

Permission filtering (`sys_acl`) works at the hxpr level and is already multi-source aware.

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

- `rag_requests_total` — total RAG requests
- `rag_latency_seconds` — end-to-end latency
- `search_results_count` — results returned per query
- `embedding_requests_total` — embedding API calls

Health: `/actuator/health` (public, no auth required).
Info: `/actuator/info` (public).
