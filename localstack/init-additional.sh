#!/usr/bin/env bash
# Additional LocalStack setup for the unified deployment stack.
# Complements 01-hxpr-init.sh (from the hxpr project).

# HXPR Audit Events SNS topic (used by hxpr-app)
# The default application.properties points to a production ARN; we create
# the equivalent topic locally so that SNS publishing succeeds without errors.
awslocal sns create-topic --name hxpr-repository-events-standard

# ── GraphRAG (hxpr Graph API / Dgraph backend) ────────────────────────────────
# hxpr reads Dgraph ACL root credentials and per-namespace credentials from AWS
# Secrets Manager, and stores uploaded ontology YAML files in an S3 bucket. These
# mirror hxpr's own local-dev seeding (server/hxpr-app/config/localstack/init.sh)
# so the graph API is functional in this stack. Only used when the graph feature
# flag is enabled on hxpr-app.
awslocal secretsmanager create-secret \
  --name dgraph/acl/credentials \
  --secret-string '{"root-username": "groot", "root-password": "password"}'

awslocal secretsmanager create-secret \
  --name dgraph-namespace-credentials \
  --secret-string '{}'

# Ontology upload bucket. hxpr throws if this bucket is absent (it does not create
# it), so it must exist up front. Matches ontology.s3.bucket on hxpr-app.
awslocal s3 mb s3://ontology-bucket-1
