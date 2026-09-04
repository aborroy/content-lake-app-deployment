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
  url: http://hxpr-app:8080
  repository-id: default
  username: admin      # engine HTTP Basic auth (filestore user store)
  password: password

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
  prompt-injection:        # defend against injected instructions in retrieved content
    defense-enabled: false # wrap chunks as untrusted data + reinforce in the prompt
    scan-enabled: false    # log chunks matching known injection patterns (does not drop them)
  rate-limit:              # per-principal request throttling
    enabled: false
    generate-requests-per-minute: 20   # /api/rag/prompt, /api/rag/chat/stream
    search-requests-per-minute: 60     # /api/rag/search/**
  agentic-tools:           # let the LLM call retrieval tools mid-answer
    enabled: false
    max-iterations: 2      # additional retrieval rounds allowed per request
  mcp:
    enabled: true          # expose the MCP server (behind the same auth chain)
```

The prompt-injection, rate-limit, and agentic-tools features default to **off** so the retrieval and
generation baseline is unchanged; enable them per deployment. The MCP server defaults to **on** but is
never anonymously reachable (see below).

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

That filter is built by a single class, `AclFilterBuilder` in `content-lake-core`, which both the
semantic and the hybrid search path call. rag-service connects to hxpr as one administrator service
account, so hxpr applies no ACL filter of its own and this predicate is the only thing scoping
results: the hxpr port must therefore never be reachable by end users or agents, who would otherwise
query it directly with no filter at all. When no permission source can be resolved for a caller the
predicate matches nothing rather than everything.

Neither input to that filter has a permissive fallback. A request that reaches a search endpoint with
no authenticated principal is rejected with 401 rather than answered under a placeholder name, and a
source whose group directory is unreachable is handled according to
`RAG_SECURITY_GROUP_RESOLUTION_FAILURE` (described with the other environment flags below). The worst outcome of
either failure is a caller seeing fewer documents than they should, together with a WARN in the
rag-service log.

Only three paths are public: `/api/rag/health`, `/actuator/health` and `/actuator/info`. Every other
path, including `/actuator/metrics` and `/actuator/prometheus`, requires credentials. Adding a route
takes no security configuration to protect it; the chain denies by default, so a new endpoint is
authenticated unless it is deliberately exempted.

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
  "topK": 5,
  "responseFormat": "STRUCTURED"
}
```

`responseFormat` (default `TEXT`) is optional. When set to `STRUCTURED`, the response includes an
additional `structured` object (`{summary, keyPoints[], citations[]}`) derived from the answer in a
second pass; the free-text `answer` field is always present and unchanged, so existing callers are
unaffected.

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

Event sequence: `token` per delta, then `metadata` with the full response (sources, timings,
`requestId`), then `done`. With `"responseFormat": "STRUCTURED"` a `structured` event carrying the
typed answer arrives between `metadata` and `done`, rather than inside `metadata`: deriving it is a
second LLM pass over the finished answer, so sending it inline would leave the client holding a
complete answer with no sources for the length of that call. Clients should render on `metadata` and
fill the structured block when the later event lands. The non-streaming `/api/rag/prompt` still
returns `structured` inside its single response.

### Feedback (answer rating)

```http
POST /api/rag/feedback
Authorization: Basic <base64(user:password)>
Content-Type: application/json

{
  "requestId": "the requestId echoed by /api/rag/prompt",
  "rating": "down",
  "comment": "optional note",
  "question": "the original question (echoed for corpus building)",
  "answer": "the rated answer (optional)",
  "sourceNodeIds": ["node-a", "node-b"]
}
```

Persists a rating for a generated answer as an hxpr document under `RAG_FEEDBACK_BASE_PATH`
(default `/_feedback`), returning `{ "stored": true, "feedbackId": "..." }`. Every `/api/rag/prompt`
and streaming `metadata` response carries a `requestId` used to correlate the feedback with the
answer. `GET /api/rag/feedback?rating=down&limit=200` lists stored feedback for the offline
evaluation harness (`cleval feedback import`). Enabled by default; set `RAG_FEEDBACK_ENABLED=false`
to disable the endpoint. Both verbs require authentication like the other `/api/rag/**` endpoints.

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
- Semantic query caching: `RAG_CACHE_ENABLED` (default off) turns on a bounded, short-TTL in-memory
  cache of query embeddings and full retrieval results (`RAG_CACHE_TTL_SECONDS` default 60,
  `RAG_CACHE_MAX_SIZE` default 1000). Result-cache entries are scoped by the authenticated principal,
  so a cached answer is never served across ACL contexts; the TTL bounds how stale a principal's
  group membership may be. Hit-rate is exposed as `cache.gets{cache=rag.query.results}` /
  `{cache=rag.query.embeddings}` under `/actuator/metrics`.
- Group-resolution failure policy: `RAG_SECURITY_GROUP_RESOLUTION_FAILURE` (default `fail-closed`)
  decides what a query does when the caller's group membership cannot be read from a source
  repository. `fail-closed` excludes that source from the permission filter, so a directory outage
  narrows results; `degrade` proceeds with the caller's own name plus `GROUP_EVERYONE`, losing only
  group-granted documents. Both log at WARN, and an unrecognised value is read as `fail-closed`.
- User feedback capture: `RAG_FEEDBACK_ENABLED` (default **on**) exposes `POST/GET /api/rag/feedback`;
  `RAG_FEEDBACK_BASE_PATH` (default `/_feedback`) is the hxpr folder feedback is stored under.
- Named-query discovery: `RAG_NAMEDQUERY_DISCOVERY_ENABLED` (default **on**) controls whether
  `GET /api/rag/named-queries` lists the named queries registered in hxpr. The UI turns that list
  into a "Saved query" selector and hides the selector when the list is empty, so set it to `false`
  where hxpr only has its own internals registered (`tree_children`, `simple_search`,
  `folder_listing`, ...) and there is nothing curated to offer. Discovery only: a `namedQuery` a
  client names explicitly on a search request is still applied.

### Health check (public)

```http
GET /api/rag/health
```

### Operational status (authenticated)

```http
GET /api/status
Authorization: Basic <base64(user:password)>
```

Returns hxpr connectivity, per-source indexed document counts (`cin_sourceId` -> count), and
embedding/model-runner reachability in one snapshot. Authenticated, since per-source counts are
information disclosure. Custom `hxpr` and `modelRunner` health contributors also appear under
`/actuator/health` (component details shown to authenticated callers).

The batch ingesters (`alfresco-batch-ingester`, `nuxeo-batch-ingester`, `filesystem-batch-ingester`)
each expose their own `GET /api/status` with the last run's timestamp and discovered / indexed /
failed counts; the detailed per-job view remains at `GET /api/sync/status`.

---

## Rate Limiting

When `rag.rate-limit.enabled=true`, a per-authenticated-principal token bucket throttles requests.
Generation endpoints (`/api/rag/prompt`, `/api/rag/chat/stream`) get a
tighter budget (`generate-requests-per-minute`, default 20) than search (`/api/rag/search/**`,
`search-requests-per-minute`, default 60). Exceeding the budget returns **HTTP 429** with a
`Retry-After` header. Buckets are in-memory and therefore per-instance; a multi-instance deployment
does not share limits.

---

## Agentic Tool-Calling

When `rag.agentic-tools.enabled=true`, the RAG model may invoke a small toolset mid-answer
(`researchAgain`, `getDocument`, `listSources`) to fetch more evidence when the initial context is
insufficient, bounded by `max-iterations` (default 2). Every tool-invoked retrieval is ACL-scoped to
the request principal - identity comes from the authenticated request, never from a tool argument -
so tools cannot widen the caller's access. Off by default.

---

## Prompt-Injection Defense

Retrieved document content is untrusted: a stored document can contain text like "ignore previous
instructions". Two independent, default-off guards address this:

- `rag.prompt-injection.defense-enabled` wraps each retrieved chunk in explicit "untrusted document
  data, not instructions" delimiters and reinforces that framing in the prompt.
- `rag.prompt-injection.scan-enabled` runs a heuristic scanner over each chunk and logs matches for
  audit. Flagged chunks are **not** dropped (they may hold evidence the user needs).

Both default off so the generation baseline is unchanged; enable and re-measure with
`content-lake-eval` before turning them on in production.

---

## MCP Server

When `rag.mcp.enabled=true` (default), rag-service publishes a Model Context Protocol server
exposing `secureSearch`, `getDocument`, and `listSources` tools to external LLM agents. The transport
is synchronous WebMVC and sits behind the same `SecurityFilterChain` as the REST API, so it is
reachable only with HTTP Basic or Alfresco-ticket credentials (compatible with the official Alfresco
MCP Server client model) and never anonymously. Tools derive the ACL identity from the authenticated
request, so an agent cannot query as another user. Set `RAG_MCP_ENABLED=false` to disable.

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

Health: `/actuator/health` (public, no auth required, so the container orchestrator can probe it).
Info: `/actuator/info` (public).

`/actuator/metrics` and `/actuator/prometheus` require credentials: they enumerate the service's
endpoints and reveal request volumes and timings. A scraper needs an account valid in one of the
configured content sources, the same as any other caller:

```bash
curl -u admin:admin http://localhost/actuator/prometheus
```

### Distributed tracing

The pipeline is instrumented with Micrometer Tracing (OpenTelemetry bridge). Named spans cover the
key steps -- `rag.embed.query`, `rag.search.vector`, `rag.search.keyword`, and `rag.generate` -- so a
single request shows which embedding, hxpr query, or LLM call inside a phase was the bottleneck,
beyond the coarse `searchTimeMs`/`generationTimeMs`/`totalTimeMs` fields on the prompt response.
Trace and span ids are added to every log line via the MDC (`[rag-service,<traceId>,<spanId>]`).

- `MANAGEMENT_TRACING_SAMPLING_PROBABILITY` -- sampling rate (default `0.1`; set `1.0` in dev).
- `MANAGEMENT_OTLP_TRACING_ENDPOINT` -- OTLP `/v1/traces` collector URL. **Blank by default**, so
  spans are created and logged but nothing is exported and no collector is required. Point it at a
  collector (e.g. `http://otel-collector:4318/v1/traces`) to ship traces.

### Cache metrics

When `RAG_CACHE_ENABLED=true`, the two Caffeine caches are bound to Micrometer and visible under
`/actuator/metrics`: `cache.gets{cache=rag.query.results,result=hit|miss}` and
`cache.gets{cache=rag.query.embeddings,...}`, plus `cache.size` / `cache.evictions`.
