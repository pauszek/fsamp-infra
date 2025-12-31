#!/bin/bash
# LocalStack initialization script - runs on container start
# This bootstraps the local AWS environment for development

set -euo pipefail

echo "============================================"
echo "  FSAMP LocalStack Initialization"
echo "============================================"

AWS_REGION="eu-central-1"
AWS_ENDPOINT="http://localhost:4566"

# Helper function for AWS CLI
awslocal() {
    aws --endpoint-url="$AWS_ENDPOINT" --region="$AWS_REGION" "$@"
}

echo "[1/6] Creating KMS key for FIPS 140-3 encryption..."
KMS_KEY_ID=$(awslocal kms create-key \
    --description "FSAMP Master Key (FIPS 140-3 compliant)" \
    --key-usage ENCRYPT_DECRYPT \
    --origin AWS_KMS \
    --query 'KeyMetadata.KeyId' \
    --output text)

awslocal kms create-alias \
    --alias-name alias/fsamp-local-master-key \
    --target-key-id "$KMS_KEY_ID"

echo "   Created KMS Key: $KMS_KEY_ID"

echo "[2/6] Creating S3 buckets with encryption..."
for BUCKET in fsamp-local-files fsamp-local-processed fsamp-local-quarantine; do
    awslocal s3 mb "s3://$BUCKET" || true
    awslocal s3api put-bucket-encryption \
        --bucket "$BUCKET" \
        --server-side-encryption-configuration '{
            "Rules": [{
                "ApplyServerSideEncryptionByDefault": {
                    "SSEAlgorithm": "aws:kms",
                    "KMSMasterKeyID": "alias/fsamp-local-master-key"
                },
                "BucketKeyEnabled": true
            }]
        }'
    echo "   Created bucket: $BUCKET (KMS encrypted)"
done

echo "[3/6] Creating DynamoDB tables..."
awslocal dynamodb create-table \
    --table-name fsamp-local-file-metadata \
    --attribute-definitions \
        AttributeName=fileId,AttributeType=S \
        AttributeName=uploadTimestamp,AttributeType=S \
    --key-schema \
        AttributeName=fileId,KeyType=HASH \
        AttributeName=uploadTimestamp,KeyType=RANGE \
    --billing-mode PAY_PER_REQUEST \
    --sse-specification Enabled=true,SSEType=KMS,KMSMasterKeyId="$KMS_KEY_ID" \
    || true
echo "   Created table: fsamp-local-file-metadata"

awslocal dynamodb create-table \
    --table-name fsamp-local-events \
    --attribute-definitions \
        AttributeName=eventId,AttributeType=S \
        AttributeName=timestamp,AttributeType=S \
    --key-schema \
        AttributeName=eventId,KeyType=HASH \
        AttributeName=timestamp,KeyType=RANGE \
    --billing-mode PAY_PER_REQUEST \
    --sse-specification Enabled=true,SSEType=KMS,KMSMasterKeyId="$KMS_KEY_ID" \
    || true
echo "   Created table: fsamp-local-events"

echo "[4/6] Creating SNS topics..."
awslocal sns create-topic --name fsamp-local-file-events || true
awslocal sns create-topic --name fsamp-local-processing-events || true
awslocal sns create-topic --name fsamp-local-dlq-alerts || true
echo "   Created SNS topics"

echo "[5/6] Creating SQS queues with DLQ..."
# Dead Letter Queue
awslocal sqs create-queue \
    --queue-name fsamp-local-dlq \
    --attributes '{
        "MessageRetentionPeriod": "1209600",
        "KmsMasterKeyId": "alias/fsamp-local-master-key"
    }' || true

DLQ_ARN=$(awslocal sqs get-queue-attributes \
    --queue-url "http://sqs.eu-central-1.localhost.localstack.cloud:4566/000000000000/fsamp-local-dlq" \
    --attribute-names QueueArn \
    --query 'Attributes.QueueArn' \
    --output text)

# Main processing queue with DLQ
awslocal sqs create-queue \
    --queue-name fsamp-local-file-processing \
    --attributes '{
        "VisibilityTimeout": "300",
        "MessageRetentionPeriod": "86400",
        "KmsMasterKeyId": "alias/fsamp-local-master-key",
        "RedrivePolicy": "{\"deadLetterTargetArn\":\"'"$DLQ_ARN"'\",\"maxReceiveCount\":3}"
    }' || true

# Analysis results queue
awslocal sqs create-queue \
    --queue-name fsamp-local-analysis-results \
    --attributes '{
        "VisibilityTimeout": "60",
        "MessageRetentionPeriod": "86400",
        "KmsMasterKeyId": "alias/fsamp-local-master-key",
        "RedrivePolicy": "{\"deadLetterTargetArn\":\"'"$DLQ_ARN"'\",\"maxReceiveCount\":3}"
    }' || true

echo "   Created SQS queues with DLQ"

echo "[6/6] Creating SNS -> SQS subscription..."
QUEUE_ARN=$(awslocal sqs get-queue-attributes \
    --queue-url "http://sqs.eu-central-1.localhost.localstack.cloud:4566/000000000000/fsamp-local-file-processing" \
    --attribute-names QueueArn \
    --query 'Attributes.QueueArn' \
    --output text)

awslocal sns subscribe \
    --topic-arn "arn:aws:sns:eu-central-1:000000000000:fsamp-local-file-events" \
    --protocol sqs \
    --notification-endpoint "$QUEUE_ARN" || true

echo "   SNS -> SQS subscription created"

echo ""
echo "============================================"
echo "  LocalStack initialization complete!"
echo "============================================"
echo ""
echo "Resources created:"
echo "  - KMS Key: alias/fsamp-local-master-key"
echo "  - S3: fsamp-local-files, fsamp-local-processed, fsamp-local-quarantine"
echo "  - DynamoDB: fsamp-local-file-metadata, fsamp-local-events"
echo "  - SNS: fsamp-local-file-events, fsamp-local-processing-events, fsamp-local-dlq-alerts"
echo "  - SQS: fsamp-local-file-processing, fsamp-local-analysis-results, fsamp-local-dlq"
echo ""
echo "Endpoint: http://localhost:4566"
