#!/usr/bin/env sh
# Registers the nuxeo_embeddings index template BEFORE hxpr-app creates the index.
#
# Why: OpenSearch 3.5 defaults index.knn.derived_source.enabled=true, which strips
# the vector from _source and reconstructs it from the HNSW .vec files at fetch time.
# After a segment merge (e.g. triggered by ingesting a document) those memory-mapped
# .vec files can end up AlreadyClosed, so any hybrid (knn + text match) search fails
# the fetch phase with "all shards failed" / 503 -- surfaced to RAG as a 500.
# Disabling derived_source keeps the vector in _source and avoids reconstruction.
#
# Idempotent: a PUT template just overwrites. opensearch is service_healthy before
# this runs, so no readiness loop is needed.
set -e

OS_URL="${OPENSEARCH_URL:-http://opensearch:9200}"

echo "opensearch-init: registering index template nuxeo-embeddings-noderivedsource at ${OS_URL}"
curl -sf -X PUT "${OS_URL}/_index_template/nuxeo-embeddings-noderivedsource" \
  -H 'Content-Type: application/json' \
  --data-binary @/init/index-template.json
echo
echo "opensearch-init: done"
