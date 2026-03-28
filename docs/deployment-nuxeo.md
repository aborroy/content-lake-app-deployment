# Deployment — Nuxeo Stack

This guide covers Nuxeo-specific setup for Content Lake. For the full stack deployment see
[deployment-alfresco.md](deployment-alfresco.md).

---

## Local Development Stack

Use the `nuxeo-deployment/` sibling project for local Nuxeo development. No Connect account, CLID,
or special credentials required — it uses the public `nuxeo` Docker Hub image.

```bash
cd ../nuxeo-deployment
docker compose up -d
docker compose logs -f nuxeo   # wait for "Nuxeo Platform started"
```

- Web UI: `http://localhost:8081/nuxeo`
- REST base: `http://localhost:8081/nuxeo/api/v1`
- Default credentials: `Administrator` / `Administrator`

**Trade-offs of the public image:** The `nuxeo:latest` image is a Community-era release. Suitable
for developing and testing the REST connector; not for validating against a current Hyland Nuxeo
release. Marketplace packages requiring a Connect subscription cannot be installed without a CLID.

---

## REST API Quick Reference

Base URL: `http://localhost:8081/nuxeo/api/v1`
Auth header: `Authorization: Basic <base64(user:password)>`

| Operation | Endpoint |
|---|---|
| Fetch document | `GET /id/{uid}` |
| Fetch with ACLs | `GET /id/{uid}` + header `enrichers-document: acls` |
| Fetch by path | `GET /path/{docPath}` |
| List children | `GET /id/{uid}/@children?currentPageIndex=0&pageSize=50` |
| Download blob | `GET /id/{uid}/@blob/file:content` |
| NXQL search | `GET /search/lang/NXQL/execute?query=...&pageSize=50&currentPageIndex=0` |
| Convert to text | `GET /id/{uid}/@blob/{blobXpath}/@convert?type=text/plain` |

### Default NXQL for batch discovery

```sql
SELECT * FROM Document
WHERE ecm:path STARTSWITH '/default-domain/workspaces'
  AND ecm:primaryType IN ('File','Note')
  AND ecm:currentLifeCycleState != 'deleted'
  AND ecm:isProxy = 0
  AND ecm:isCheckedInVersion = 0
```

---

## Nuxeo vs Alfresco Differences

| Aspect | Alfresco | Nuxeo |
|---|---|---|
| Content model | Nodes with aspects and properties | Documents with types, schemas, and facets |
| Hierarchy | Folder-based path tree | Domains, workspaces, folders, files, proxies, versions |
| Events | ActiveMQ with Event2 model | Internal event bus, audit log, stream processing |
| Text extraction | Transform Core AIO | `ConversionService` via REST `@convert` |
| Permissions | ACLs with roles (Consumer, Contributor…) | ACP/ACL/ACE with inherited grants |
| Discovery | `@children` REST or NXQL | NXQL preferred for scalability |
| Authentication | Ticket auth, Basic Auth | Basic auth for MVP; Token/OAuth2 for production |

---

## `SourceNode` Field Mapping (Nuxeo)

| `SourceNode` field | Nuxeo source |
|---|---|
| `nodeId` | document `uid` |
| `sourceType` | `"nuxeo"` |
| `sourceId` | configured instance ID (NOT `repository` — always `"default"` in main repo) |
| `path` | document path |
| `mimeType` | MIME type of primary blob (`file:content` xpath or configured blob xpath) |
| `readPrincipals` | derived from effective ACL — request with `enrichers-document: acls` header |

---

## Text Extraction

Nuxeo's `TransformService` API is deprecated. Content Lake uses `ConversionService` server-side
through the REST `@convert` adapter:

```
GET /nuxeo/api/v1/id/{uid}/@blob/{blobXpath}/@convert?type=text/plain
```

This keeps the pattern parallel to Alfresco's Transform Core AIO: the ingester requests plain text
synchronously, conversion executes server-side, and the HTTP response contains the converted bytes.
Do not use embedded Apache Tika in the main adapter path.

---

## Scope Resolution (MVP)

`NuxeoScopeResolver` uses config-only scope. Set in `application.yml`:

```yaml
nuxeo:
  scope:
    included-roots:
      - /default-domain/workspaces
    included-types:
      - File
      - Note
```

A schema-based approach (custom facet equivalent to Alfresco's `cl:indexed`) is a follow-up.

---

## Authentication Configuration

Basic auth for MVP. Set in `application.yml`:

```yaml
nuxeo:
  url: http://localhost:8081/nuxeo
  username: Administrator
  password: Administrator
  source-id: my-nuxeo-instance   # must be set explicitly; never use the Nuxeo repository field
```

The `sourceId` must uniquely identify the Nuxeo instance for `cin_sourceId` generation. Using a
descriptive, stable name (e.g. `prod-nuxeo`, `dev-nuxeo`) avoids conflicts when running multiple
Nuxeo instances against the same hxpr.

---

## Demo Content

Create a known-good sample file in the local Nuxeo stack without using the Web UI:

```bash
# From content-lake-app-deployment/
./scripts/create-nuxeo-demo-file.sh
./scripts/create-nuxeo-demo-file.sh --title "Quarterly Notes" --text $'Line 1\nLine 2'
./scripts/create-nuxeo-demo-file.sh --input-file README.md --mime-type text/markdown
```

The helper creates the demo workspace if needed and attaches the blob through the
`Blob.AttachOnDocument` automation endpoint.

Verify indexing after syncing:

```bash
curl -u Administrator:Administrator -X POST \
  'http://localhost/api/sync/configured?sourceType=nuxeo'
```

---

## Audit-Based Live Sync

`nuxeo-live-ingester` polls the Nuxeo audit log via `NuxeoAuditClient`. Configuration:

```yaml
nuxeo:
  live:
    poll-interval: 30s       # how often to poll the audit log
    page-size: 50            # audit entries per page
    cursor-file: /tmp/nuxeo-audit-cursor.json   # persists the audit watermark
```

The cursor is stored by `FileAuditCursorStore`. Replace with a database-backed implementation for
multi-instance deployments.
