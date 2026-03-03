#!/usr/bin/env bash
# Additional LocalStack setup for the unified deployment stack.
# Complements 01-hxpr-init.sh (from the hxpr project).

# HXPR Audit Events SNS topic (used by hxpr-app)
# The default application.properties points to a production ARN; we create
# the equivalent topic locally so that SNS publishing succeeds without errors.
awslocal sns create-topic --name hxpr-repository-events-standard
