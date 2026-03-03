#!/usr/bin/env bash
# Async Tasks configuration
TOPIC_TASKS_ARN=$(awslocal sns create-topic --name test-sns-async-tasks | sed -n -e 's/^.*TopicArn": "\(.*\)".*$/\1/p')
awslocal sqs create-queue --queue-name scroller-queue
awslocal sqs create-queue --queue-name deletion-queue
awslocal sqs create-queue --queue-name trash-queue
awslocal sqs create-queue --queue-name retentionexpired-queue
awslocal sqs create-queue --queue-name setproperties-queue
awslocal sqs create-queue --queue-name setsystemproperties-queue
awslocal sqs create-queue --queue-name updatereadacls-queue
awslocal sqs create-queue --queue-name bucketindexing-queue
awslocal sqs create-queue --queue-name computedigest-queue
awslocal sqs create-queue --queue-name fulltextextractor-queue
awslocal sqs create-queue --queue-name indexing-queue
awslocal sqs create-queue --queue-name scrollerindexing-queue
awslocal sqs create-queue --queue-name transientstoragegc-queue
awslocal sqs create-queue --queue-name updateacestatus-queue
awslocal sqs create-queue --queue-name scrollerdocument-queue
awslocal sqs create-queue --queue-name bulkimport-queue
awslocal sqs create-queue --queue-name cleanuporphans-queue
SUB_SCROLLER_ID=$(awslocal sns subscribe --topic-arn $TOPIC_TASKS_ARN --protocol sqs --notification-endpoint arn:aws:sqs:us-east-1:000000000000:scroller-queue | sed -n -e 's/^.*SubscriptionArn": "\(.*\)".*$/\1/p')
awslocal sns set-subscription-attributes --subscription-arn $SUB_SCROLLER_ID --attribute-name FilterPolicy --attribute-value '{"taskName": ["scroller"]}'
SUB_DELETION_ID=$(awslocal sns subscribe --topic-arn $TOPIC_TASKS_ARN --protocol sqs --notification-endpoint arn:aws:sqs:us-east-1:000000000000:deletion-queue | sed -n -e 's/^.*SubscriptionArn": "\(.*\)".*$/\1/p')
awslocal sns set-subscription-attributes --subscription-arn $SUB_DELETION_ID --attribute-name FilterPolicy --attribute-value '{"taskName": ["deletion"]}'
SUB_TRASH_ID=$(awslocal sns subscribe --topic-arn $TOPIC_TASKS_ARN --protocol sqs --notification-endpoint arn:aws:sqs:us-east-1:000000000000:trash-queue | sed -n -e 's/^.*SubscriptionArn": "\(.*\)".*$/\1/p')
awslocal sns set-subscription-attributes --subscription-arn $SUB_TRASH_ID --attribute-name FilterPolicy --attribute-value '{"taskName": ["trash"]}'
SUB_RETENTION_EXPIRED_ID=$(awslocal sns subscribe --topic-arn $TOPIC_TASKS_ARN --protocol sqs --notification-endpoint arn:aws:sqs:us-east-1:000000000000:retentionexpired-queue | sed -n -e 's/^.*SubscriptionArn": "\(.*\)".*$/\1/p')
awslocal sns set-subscription-attributes --subscription-arn $SUB_RETENTION_EXPIRED_ID --attribute-name FilterPolicy --attribute-value '{"taskName": ["retentionExpired"]}'
SUB_SET_PROPERTIES_ID=$(awslocal sns subscribe --topic-arn $TOPIC_TASKS_ARN --protocol sqs --notification-endpoint arn:aws:sqs:us-east-1:000000000000:setproperties-queue | sed -n -e 's/^.*SubscriptionArn": "\(.*\)".*$/\1/p')
awslocal sns set-subscription-attributes --subscription-arn $SUB_SET_PROPERTIES_ID --attribute-name FilterPolicy --attribute-value '{"taskName": ["setProperties"]}'
SUB_UPDATE_READ_ACLS_ID=$(awslocal sns subscribe --topic-arn $TOPIC_TASKS_ARN --protocol sqs --notification-endpoint arn:aws:sqs:us-east-1:000000000000:updatereadacls-queue | sed -n -e 's/^.*SubscriptionArn": "\(.*\)".*$/\1/p')
awslocal sns set-subscription-attributes --subscription-arn $SUB_UPDATE_READ_ACLS_ID --attribute-name FilterPolicy --attribute-value '{"taskName": ["updateReadAcls"]}'
SUB_SET_SYSTEM_PROPERTIES_ID=$(awslocal sns subscribe --topic-arn $TOPIC_TASKS_ARN --protocol sqs --notification-endpoint arn:aws:sqs:us-east-1:000000000000:setsystemproperties-queue | sed -n -e 's/^.*SubscriptionArn": "\(.*\)".*$/\1/p')
awslocal sns set-subscription-attributes --subscription-arn $SUB_SET_SYSTEM_PROPERTIES_ID --attribute-name FilterPolicy --attribute-value '{"taskName": ["setSystemProperties"]}'
SUB_BUCKET_INDEXING_ID=$(awslocal sns subscribe --topic-arn $TOPIC_TASKS_ARN --protocol sqs --notification-endpoint arn:aws:sqs:us-east-1:000000000000:bucketindexing-queue | sed -n -e 's/^.*SubscriptionArn": "\(.*\)".*$/\1/p')
awslocal sns set-subscription-attributes --subscription-arn $SUB_BUCKET_INDEXING_ID --attribute-name FilterPolicy --attribute-value '{"taskName": ["bucketIndexing"]}'
SUB_COMPUTE_DIGEST_ID=$(awslocal sns subscribe --topic-arn $TOPIC_TASKS_ARN --protocol sqs --notification-endpoint arn:aws:sqs:us-east-1:000000000000:computedigest-queue | sed -n -e 's/^.*SubscriptionArn": "\(.*\)".*$/\1/p')
awslocal sns set-subscription-attributes --subscription-arn $SUB_COMPUTE_DIGEST_ID --attribute-name FilterPolicy --attribute-value '{"taskName": ["computeDigest"]}'
SUB_FULLTEXT_EXTRACTOR_ID=$(awslocal sns subscribe --topic-arn $TOPIC_TASKS_ARN --protocol sqs --notification-endpoint arn:aws:sqs:us-east-1:000000000000:fulltextextractor-queue | sed -n -e 's/^.*SubscriptionArn": "\(.*\)".*$/\1/p')
awslocal sns set-subscription-attributes --subscription-arn $SUB_FULLTEXT_EXTRACTOR_ID --attribute-name FilterPolicy --attribute-value '{"taskName": ["fulltextExtractor"]}'
SUB_INDEXING_ID=$(awslocal sns subscribe --topic-arn $TOPIC_TASKS_ARN --protocol sqs --notification-endpoint arn:aws:sqs:us-east-1:000000000000:indexing-queue | sed -n -e 's/^.*SubscriptionArn": "\(.*\)".*$/\1/p')
awslocal sns set-subscription-attributes --subscription-arn $SUB_INDEXING_ID --attribute-name FilterPolicy --attribute-value '{"taskName": ["indexing"]}'
SUB_SCROLLER_INDEXING_ID=$(awslocal sns subscribe --topic-arn $TOPIC_TASKS_ARN --protocol sqs --notification-endpoint arn:aws:sqs:us-east-1:000000000000:scrollerindexing-queue | sed -n -e 's/^.*SubscriptionArn": "\(.*\)".*$/\1/p')
awslocal sns set-subscription-attributes --subscription-arn $SUB_SCROLLER_INDEXING_ID --attribute-name FilterPolicy --attribute-value '{"taskName": ["scrollerIndexing"]}'
SUB_TRANSIENT_STORAGE_GC_ID=$(awslocal sns subscribe --topic-arn $TOPIC_TASKS_ARN --protocol sqs --notification-endpoint arn:aws:sqs:us-east-1:000000000000:transientstoragegc-queue | sed -n -e 's/^.*SubscriptionArn": "\(.*\)".*$/\1/p')
awslocal sns set-subscription-attributes --subscription-arn $SUB_TRANSIENT_STORAGE_GC_ID --attribute-name FilterPolicy --attribute-value '{"taskName": ["transientStorageGC"]}'
SUB_UPDATE_ACE_STATUS_ID=$(awslocal sns subscribe --topic-arn $TOPIC_TASKS_ARN --protocol sqs --notification-endpoint arn:aws:sqs:us-east-1:000000000000:updateacestatus-queue | sed -n -e 's/^.*SubscriptionArn": "\(.*\)".*$/\1/p')
awslocal sns set-subscription-attributes --subscription-arn $SUB_UPDATE_ACE_STATUS_ID --attribute-name FilterPolicy --attribute-value '{"taskName": ["updateAceStatus"]}'
SUB_SCROLLER_DOCUMENT_ID=$(awslocal sns subscribe --topic-arn $TOPIC_TASKS_ARN --protocol sqs --notification-endpoint arn:aws:sqs:us-east-1:000000000000:scrollerdocument-queue | sed -n -e 's/^.*SubscriptionArn": "\(.*\)".*$/\1/p')
awslocal sns set-subscription-attributes --subscription-arn $SUB_SCROLLER_DOCUMENT_ID --attribute-name FilterPolicy --attribute-value '{"taskName": ["scrollerDocument"]}'
SUB_BULK_IMPORT_ID=$(awslocal sns subscribe --topic-arn $TOPIC_TASKS_ARN --protocol sqs --notification-endpoint arn:aws:sqs:us-east-1:000000000000:bulkimport-queue | sed -n -e 's/^.*SubscriptionArn": "\(.*\)".*$/\1/p')
awslocal sns set-subscription-attributes --subscription-arn $SUB_BULK_IMPORT_ID --attribute-name FilterPolicy --attribute-value '{"taskName": ["bulkImport"]}'
SUB_CLEANUP_ORPHANS_ID=$(awslocal sns subscribe --topic-arn $TOPIC_TASKS_ARN --protocol sqs --notification-endpoint arn:aws:sqs:us-east-1:000000000000:cleanuporphans-queue | sed -n -e 's/^.*SubscriptionArn": "\(.*\)".*$/\1/p')
awslocal sns set-subscription-attributes --subscription-arn $SUB_CLEANUP_ORPHANS_ID --attribute-name FilterPolicy --attribute-value '{"taskName": ["cleanupOrphans"]}'

# Audit events Studio SNS topic
awslocal sns create-topic --name audit-events-studio-topic

# Audit events Nucleus SNS topic
awslocal sns create-topic --name audit-events-nucleus-topic

# Usage events
awslocal sns create-topic --name test-usage-events

# Topic SNS events
awslocal sns create-topic --name test-sns-events

# Audit events Insight SNS topic
awslocal sns create-topic --name insight-events-topic

# Governance events SNS topic
awslocal sns create-topic --name cicgov-events-topic

# Commands
awslocal sqs create-queue --queue-name commands-queue
