# OpenSearch 3.x Upgrade Attempt

**Status:** Abandoned, documented for future reference  
**Date:** Prior to 2026-09-24  
**Current Version:** OpenSearch 2.19.6 (pinned in `OPENSEARCH_TAG`)

## Summary

An attempt was made to upgrade from OpenSearch 2.19.6 to OpenSearch 3.5. The upgrade hit a critical defect
in the hybrid search path that caused the RAG Ask flow to fail with HTTP 500 errors. The upgrade was
abandoned, and the deployment remains on 2.19.6, which is working correctly with all E2E tests passing.

**This document exists so the attempt and its findings are preserved for future upgrade efforts.**

## The Defect

### Symptom

After upgrading to OpenSearch 3.5 and ingesting documents, **hybrid queries (knn + text match) fail the
fetch phase** with:

- OpenSearch error: `all shards failed` / HTTP 503
- Exception: `AlreadyClosed` on memory-mapped HNSW `.vec` files
- Presents to users as: **HTTP 500 on the RAG Ask endpoint**

### Root Cause

**OpenSearch 3.5 defaults `index.knn.derived_source.enabled=true`** for KNN indices.

When enabled, this setting:
1. Strips vectors from `_source` at index time
2. Stores them only in HNSW `.vec` segment files
3. Reconstructs vectors from these files at fetch time

**The bug:** After a segment merge (which document ingestion can trigger), the memory-mapped `.vec` files
can be in an `AlreadyClosed` state when the fetch phase tries to read them. This causes the query to fail.

### Why This Is Expensive to Diagnose

The failure manifests as:
- **HTTP 500 on `POST /api/rag/prompt`** - looks like an application bug
- No obvious error in `rag-service` logs - the 500 comes from the OpenSearch client
- The real cause is an **OpenSearch index setting**, not application code

An operator would naturally investigate `rag-service` first, burning significant time before discovering the
issue is in OpenSearch configuration.

## The Workaround

Disable `derived_source` for embedding indices **before they are created** by registering an index template.

### Template

```json
{
  "index_patterns": ["nuxeo_embeddings", "nuxeo_embeddings_*"],
  "priority": 500,
  "template": {
    "settings": {
      "index": {
        "knn": true,
        "knn.derived_source.enabled": false
      }
    }
  },
  "_meta": {
    "reason": "Workaround OpenSearch 3.5 derived_source bug: hybrid searches fail fetch phase with AlreadyClosed after segment merge"
  }
}
```

### Why Priority and Timing Matter

- **Priority 500**: Must override any lower-priority templates
- **Must be registered BEFORE index creation**: Templates only apply to new indices, not existing ones
- **Ordering requirement**: The template registration must complete before `hxpr-app` starts and creates indices

### Implementation That Was Tested

A one-shot `opensearch-init` service:

```yaml
opensearch-init:
  image: curlimages/curl:latest
  command: >
    sh -c "curl -XPUT 'http://opensearch:9200/_index_template/disable-derived-source'
           -H 'Content-Type: application/json'
           -d @/template.json"
  volumes:
    - ./hxpr/opensearch/index-template.json:/template.json:ro
  depends_on:
    opensearch:
      condition: service_healthy

hxpr-app:
  depends_on:
    opensearch-init:
      condition: service_completed_successfully
```

This ensures the template exists before hxpr creates its indices.

## Scope and Limitations

### What Was Covered

- **nuxeo_embeddings** indices only

The template above names only `nuxeo_embeddings*`. This was sufficient to prove the workaround, but a
production deployment would need to cover all embedding indices.

### What Was NOT Verified

1. **Whether Alfresco and plugin-source embedding indices need the same treatment**
   - The original attempt did not establish whether `alfresco_embeddings*` and other source indices exhibit
     the same bug
   - Assumption: they do, since they're all KNN indices on OpenSearch 3.5

2. **Whether the defect still exists in later 3.x releases**
   - The bug was reproduced on OpenSearch 3.5
   - Later point releases may have fixed it upstream
   - **Before attempting upgrade again:** Check OpenSearch 3.x release notes for fixes to `derived_source`
     or KNN fetch-phase issues

3. **Performance impact of keeping vectors in `_source`**
   - `derived_source` was introduced to reduce index size
   - Disabling it means larger indices (vectors stored twice: in `_source` and in HNSW segments)
   - The size/performance tradeoff was not measured

## Where the Code Lives

### Branch: `origin/java-25-upgrade`

**Do not merge or rebase this branch.** It is ~70 commits behind main and most of its changes are superseded:
- Java 21 -> 25 upgrade is already on main
- Per-service Dockerfiles no longer exist (consolidated to single `dockerfiles/Dockerfile`)
- E2E harness fixes have landed on main

### Only Commit of Value: `cd9e2c8`

```
commit cd9e2c8...
Author: ...
Date: ...

fix: disable OpenSearch 3.5 derived_source for nuxeo_embeddings
```

This commit contains:
- `hxpr/opensearch/index-template.json` - the template above
- `hxpr/opensearch/init.sh` - template registration script
- `compose.yaml` changes for `opensearch-init` service

**If the branch is deleted**, the code is still recoverable from commit `cd9e2c8`.

## Why It Was Abandoned

1. **The workaround works but is incomplete**
   - Only nuxeo_embeddings covered
   - Other sources not verified

2. **No compelling reason to upgrade**
   - OpenSearch 2.19.6 is working correctly
   - All E2E tests pass on 2.19.6
   - No feature or security issue forcing an upgrade

3. **Risk vs. benefit**
   - Risk: introduce a subtle fetch-phase bug affecting production queries
   - Benefit: unclear (no new features needed)
   - Decision: stay on 2.19.6 until there's a reason to move

## If Picked Up Again

### Before Starting

1. **Check if the bug is fixed upstream**
   - Search OpenSearch 3.x release notes for "derived_source" fixes
   - Test on the latest 3.x point release, not just 3.5

2. **Determine scope**
   - Which indices need the template: `nuxeo_embeddings*`, `alfresco_embeddings*`, `*_embeddings*`?
   - Are there patterns beyond `*_embeddings` that need coverage?

3. **Measure the index size impact**
   - Compare index sizes with and without `derived_source` on a representative corpus
   - Determine if the size increase is acceptable

### During Implementation

1. **Cover all embedding indices** in the template, not just Nuxeo
2. **Order `opensearch-init` before `hxpr-app`** explicitly in compose dependencies
3. **Run the full E2E gate** after upgrade - the failure is in hybrid search, not ingestion

### Verification

- **Full E2E suite must pass**, especially:
  - Alfresco hybrid search tests
  - Nuxeo hybrid search tests
  - Full RAG flow (the original failure point)

- **Test after ingestion load** - the bug manifests after segment merges, which happen when many documents
  are indexed

## Related Issues

- #27 - This document fulfills that issue's requirement to record the attempt

## References

- OpenSearch documentation: [KNN Index Settings](https://opensearch.org/docs/latest/search-plugins/knn/knn-index/)
- OpenSearch 3.0 release notes: [derived_source feature](https://opensearch.org/docs/latest/release-notes/3.0.0/)
