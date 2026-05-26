# Deployment — Alfresco Stack

> For first-run instructions, prerequisites, credentials, and Makefile commands see the
> [main README](../README.md). This page covers Alfresco-specific configuration only.

For Nuxeo-specific setup see [deployment-nuxeo.md](deployment-nuxeo.md).
For RAG service configuration see [deployment-rag.md](deployment-rag.md).

All commands run from `content-lake-app-deployment/`.

---

## Alfresco Requirements

The following Alfresco-side components are required for Content Lake to function:

- **`content-lake-repo-model` module** installed in Alfresco Repository so the `cl:indexed` and
  `cl:excludeFromLake` aspects exist. The same module contains the repository-side ACL
  reconciliation hook that publishes permission changes to a persistent ActiveMQ queue. The ACS
  image is built locally from `acs/alfresco/`.
- **ActiveMQ** configured for Alfresco Event2 so `live-ingester` can consume `alfresco.repo.event2`
- **Alfresco Transform Core AIO** for text extraction during ingestion
- **Alfresco Search Services / Solr** wired with `secureComms=secret`

---

## ActiveMQ Credential Wiring (ACS 26.1.x)

With ACS `26.1.x`, the ActiveMQ broker credentials must be propagated to **three** distinct
places in `compose.alfresco.yaml`. Updating only the broker image is not enough:

| Component | Variable |
|---|---|
| `activemq` broker | `ACTIVEMQ_ADMIN_LOGIN` / `ACTIVEMQ_ADMIN_PASSWORD` |
| Alfresco Repository client | `messaging.broker.username` / `messaging.broker.password` |
| `transform-core-aio` client | `ACTIVEMQ_USER` / `ACTIVEMQ_PASSWORD` |

Leaving only the broker credentials set causes Repository or transform startup failures against
the authenticated broker.

These values are exposed as `ACTIVEMQ_USER` / `ACTIVEMQ_PASSWORD` in `.env` and propagated
automatically through `compose.alfresco.yaml`. Override them in `.env.local` if needed.

---

## Automatic ACL Reconciliation

When `CONTENT_LAKE_PERMISSION_SYNC_ENABLED=true` (the default), Alfresco Repository records
permission-affecting changes after commit and publishes a persistent ActiveMQ message to
`CONTENT_LAKE_PERMISSION_SYNC_QUEUE_NAME`. `batch-ingester` consumes that queue and runs the
same ACL reconciliation logic exposed by `POST /api/sync/permissions`.

This is the **primary production path** for Alfresco ACL propagation because repository
permission updates are not reliably emitted as Event2 messages.

Changes caught by this flow:

- Alfresco UI permission edits
- Alfresco REST API permission changes
- Repository-side rules, scripts, or admin tools

| Variable | Default | Purpose |
|---|---|---|
| `CONTENT_LAKE_PERMISSION_SYNC_ENABLED` | `true` | Enable the repository-side ACL publisher |
| `CONTENT_LAKE_PERMISSION_SYNC_BROKER_URL` | `tcp://activemq:61616` | ActiveMQ broker for ACL messages |
| `CONTENT_LAKE_PERMISSION_SYNC_QUEUE_NAME` | `contentlake.acl.changed` | Persistent queue consumed transactionally by `batch-ingester` |

This flow is eventually consistent. A permission revocation is visible to search only after the
repository module has published the queue message and `batch-ingester` has updated hxpr.

---

## Triggering a Sync

```bash
# Alfresco full sync
curl -u admin:admin -X POST 'http://localhost/api/sync/configured'

# Nuxeo full sync (full/demo profiles only)
curl -u admin:admin -X POST 'http://localhost/api/sync/configured?sourceType=nuxeo'
```

---

## Deploying to AWS EC2

See [DEPLOY_EC2.md](../content-lake-app-deployment/DEPLOY_EC2.md) for a step-by-step guide to
running the full stack on a `g5.2xlarge` Ubuntu instance with GPU-accelerated inference.
