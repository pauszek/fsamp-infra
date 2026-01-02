#!/bin/bash
# =============================================================================
# LocalStack Initialization Script
# =============================================================================
# Creates AWS resources for local development and E2E testing.
# This script runs automatically when LocalStack starts (ready.d hook).
#
# Resources created:
#   - S3 bucket for file storage
#   - SNS topic for file events
#   - SQS queue for processing (subscribed to SNS)
#   - SQS dead-letter queue
#   - DynamoDB table for metadata
#   - KMS key for encryption
# =============================================================================

set -euo pipefail

REGION="${AWS_DEFAULT_REGION:-us-west-2}"
ACCOUNT_ID="000000000000"
ENDPOINT="http://localhost:4566"
CONFIG_FILE="/tmp/localstack-config/fsamp-config.env"

# LocalStack uses fake credentials
export AWS_ACCESS_KEY_ID="test"
export AWS_SECRET_ACCESS_KEY="test"
export AWS_DEFAULT_REGION="$REGION"

# Remove old config to ensure healthcheck waits for fresh init
rm -f "$CONFIG_FILE" 2>/dev/null || true

echo "=============================================="
echo "Initializing FSAMP LocalStack resources..."
echo "Region: $REGION"
echo "=============================================="

# Helper function - use awslocal if available, otherwise aws with endpoint
if command -v awslocal &> /dev/null; then
    awslocal() {
        command awslocal "$@"
    }
else
    awslocal() {
        aws --endpoint-url="$ENDPOINT" --region "$REGION" "$@"
    }
fi

# -----------------------------------------------------------------------------
# KMS - Encryption Key
# -----------------------------------------------------------------------------
echo "Creating KMS key..."
KMS_KEY_ID=$(awslocal kms create-key \
    --description "FSAMP master encryption key" \
    --query 'KeyMetadata.KeyId' \
    --output text)

awslocal kms create-alias \
    --alias-name "alias/fsamp-local-master-key" \
    --target-key-id "$KMS_KEY_ID"

echo "  ✓ KMS key created: $KMS_KEY_ID"

# -----------------------------------------------------------------------------
# S3 - File Storage Bucket
# -----------------------------------------------------------------------------
echo "Creating S3 bucket..."
awslocal s3 mb "s3://fsamp-local-files" || true

# Enable versioning
awslocal s3api put-bucket-versioning \
    --bucket fsamp-local-files \
    --versioning-configuration Status=Enabled

# Enable encryption
awslocal s3api put-bucket-encryption \
    --bucket fsamp-local-files \
    --server-side-encryption-configuration '{
        "Rules": [{
            "ApplyServerSideEncryptionByDefault": {
                "SSEAlgorithm": "aws:kms",
                "KMSMasterKeyID": "'"$KMS_KEY_ID"'"
            },
            "BucketKeyEnabled": true
        }]
    }'

echo "  ✓ S3 bucket created: fsamp-local-files"

# -----------------------------------------------------------------------------
# SNS - File Events Topic
# -----------------------------------------------------------------------------
echo "Creating SNS topic..."
SNS_TOPIC_ARN=$(awslocal sns create-topic \
    --name "fsamp-local-file-events" \
    --query 'TopicArn' \
    --output text)

echo "  ✓ SNS topic created: $SNS_TOPIC_ARN"

# -----------------------------------------------------------------------------
# SQS - Processing Queue + DLQ
# -----------------------------------------------------------------------------
echo "Creating SQS queues..."

# Dead-letter queue first
DLQ_URL=$(awslocal sqs create-queue \
    --queue-name "fsamp-local-processing-dlq" \
    --query 'QueueUrl' \
    --output text)

DLQ_ARN=$(awslocal sqs get-queue-attributes \
    --queue-url "$DLQ_URL" \
    --attribute-names QueueArn \
    --query 'Attributes.QueueArn' \
    --output text)

# Main processing queue with DLQ redrive policy
QUEUE_URL=$(awslocal sqs create-queue \
    --queue-name "fsamp-local-processing-queue" \
    --attributes '{
        "VisibilityTimeout": "300",
        "MessageRetentionPeriod": "1209600",
        "RedrivePolicy": "{\"deadLetterTargetArn\":\"'"$DLQ_ARN"'\",\"maxReceiveCount\":\"3\"}"
    }' \
    --query 'QueueUrl' \
    --output text)

QUEUE_ARN=$(awslocal sqs get-queue-attributes \
    --queue-url "$QUEUE_URL" \
    --attribute-names QueueArn \
    --query 'Attributes.QueueArn' \
    --output text)

echo "  ✓ SQS queue created: $QUEUE_URL"
echo "  ✓ SQS DLQ created: $DLQ_URL"

# -----------------------------------------------------------------------------
# SNS -> SQS Subscription
# -----------------------------------------------------------------------------
echo "Creating SNS -> SQS subscription..."

# Allow SNS to send to SQS
awslocal sqs set-queue-attributes \
    --queue-url "$QUEUE_URL" \
    --attributes '{
        "Policy": "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":{\"Service\":\"sns.amazonaws.com\"},\"Action\":\"sqs:SendMessage\",\"Resource\":\"'"$QUEUE_ARN"'\",\"Condition\":{\"ArnEquals\":{\"aws:SourceArn\":\"'"$SNS_TOPIC_ARN"'\"}}}]}"
    }'

awslocal sns subscribe \
    --topic-arn "$SNS_TOPIC_ARN" \
    --protocol sqs \
    --notification-endpoint "$QUEUE_ARN" \
    --attributes '{"RawMessageDelivery": "true"}'

echo "  ✓ SNS -> SQS subscription created"

# -----------------------------------------------------------------------------
# DynamoDB - File Metadata Table
# -----------------------------------------------------------------------------
echo "Creating DynamoDB table..."
awslocal dynamodb create-table \
    --table-name "fsamp-local-file-metadata" \
    --attribute-definitions \
        AttributeName=PK,AttributeType=S \
        AttributeName=SK,AttributeType=S \
        AttributeName=GSI1PK,AttributeType=S \
        AttributeName=GSI1SK,AttributeType=S \
    --key-schema \
        AttributeName=PK,KeyType=HASH \
        AttributeName=SK,KeyType=RANGE \
    --global-secondary-indexes '[
        {
            "IndexName": "GSI1",
            "KeySchema": [
                {"AttributeName": "GSI1PK", "KeyType": "HASH"},
                {"AttributeName": "GSI1SK", "KeyType": "RANGE"}
            ],
            "Projection": {"ProjectionType": "ALL"},
            "ProvisionedThroughput": {"ReadCapacityUnits": 5, "WriteCapacityUnits": 5}
        }
    ]' \
    --provisioned-throughput ReadCapacityUnits=5,WriteCapacityUnits=5 \
    --sse-specification Enabled=true,SSEType=KMS,KMSMasterKeyId="$KMS_KEY_ID" \
    2>/dev/null || echo "  (table may already exist)"

echo "  ✓ DynamoDB table created: fsamp-local-file-metadata"

# -----------------------------------------------------------------------------
# Cognito - User Pool for Authentication
# -----------------------------------------------------------------------------
echo "Creating Cognito User Pool..."

# Create user pool (LocalStack generates ID automatically)
USER_POOL_ID=$(awslocal cognito-idp create-user-pool \
    --pool-name "fsamp-local-pool" \
    --policies '{
        "PasswordPolicy": {
            "MinimumLength": 8,
            "RequireUppercase": true,
            "RequireLowercase": true,
            "RequireNumbers": true,
            "RequireSymbols": false
        }
    }' \
    --auto-verified-attributes email \
    --query 'UserPool.Id' \
    --output text)

echo "  ✓ Cognito User Pool created: $USER_POOL_ID"

# Create app client
CLIENT_ID=$(awslocal cognito-idp create-user-pool-client \
    --user-pool-id "$USER_POOL_ID" \
    --client-name "fsamp-local-client" \
    --explicit-auth-flows ADMIN_NO_SRP_AUTH ALLOW_USER_PASSWORD_AUTH ALLOW_REFRESH_TOKEN_AUTH \
    --query 'UserPoolClient.ClientId' \
    --output text)

echo "  ✓ Cognito App Client created: $CLIENT_ID"

# Create resource server for scopes
awslocal cognito-idp create-resource-server \
    --user-pool-id "$USER_POOL_ID" \
    --identifier "fsamp-api" \
    --name "FSAMP API" \
    --scopes '[
        {"ScopeName": "files.read", "ScopeDescription": "Read files"},
        {"ScopeName": "files.write", "ScopeDescription": "Write files"}
    ]'

echo "  ✓ Resource server created with scopes"

# Create user groups
awslocal cognito-idp create-group \
    --user-pool-id "$USER_POOL_ID" \
    --group-name "USERS" \
    --description "Standard users"

awslocal cognito-idp create-group \
    --user-pool-id "$USER_POOL_ID" \
    --group-name "ADMINS" \
    --description "Administrator users"

echo "  ✓ User groups created (USERS, ADMINS)"

# Create test user
awslocal cognito-idp admin-create-user \
    --user-pool-id "$USER_POOL_ID" \
    --username "e2e-test-user" \
    --temporary-password "TempPass123!" \
    --user-attributes Name=email,Value=e2e@test.local Name=email_verified,Value=true \
    --message-action SUPPRESS

# Set permanent password
awslocal cognito-idp admin-set-user-password \
    --user-pool-id "$USER_POOL_ID" \
    --username "e2e-test-user" \
    --password "E2eTestPass123!" \
    --permanent

# Add user to USERS group
awslocal cognito-idp admin-add-user-to-group \
    --user-pool-id "$USER_POOL_ID" \
    --username "e2e-test-user" \
    --group-name "USERS"

echo "  ✓ Test user created: e2e-test-user"

# Create admin test user
awslocal cognito-idp admin-create-user \
    --user-pool-id "$USER_POOL_ID" \
    --username "e2e-admin-user" \
    --temporary-password "TempPass123!" \
    --user-attributes Name=email,Value=admin@test.local Name=email_verified,Value=true \
    --message-action SUPPRESS

awslocal cognito-idp admin-set-user-password \
    --user-pool-id "$USER_POOL_ID" \
    --username "e2e-admin-user" \
    --password "E2eAdminPass123!" \
    --permanent

awslocal cognito-idp admin-add-user-to-group \
    --user-pool-id "$USER_POOL_ID" \
    --username "e2e-admin-user" \
    --group-name "ADMINS"

echo "  ✓ Admin user created: e2e-admin-user"

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
echo ""
echo "=============================================="
echo "✅ FSAMP LocalStack initialization complete!"
echo "=============================================="
echo ""
echo "Resources created:"
echo "  S3 Bucket:     s3://fsamp-local-files"
echo "  SNS Topic:     $SNS_TOPIC_ARN"
echo "  SQS Queue:     $QUEUE_URL"
echo "  SQS DLQ:       $DLQ_URL"
echo "  DynamoDB:      fsamp-local-file-metadata"
echo "  KMS Key:       alias/fsamp-local-master-key"
echo ""
echo "Cognito:"
echo "  User Pool ID:  $USER_POOL_ID"
echo "  Client ID:     $CLIENT_ID"
echo "  Test User:     e2e-test-user / E2eTestPass123!"
echo "  Admin User:    e2e-admin-user / E2eAdminPass123!"
echo ""
echo "Environment variables for services:"
echo "  AWS_ENDPOINT_URL=http://localhost:4566"
echo "  AWS_REGION=$REGION"
echo "  S3_BUCKET_NAME=fsamp-local-files"
echo "  SNS_TOPIC_ARN=$SNS_TOPIC_ARN"
echo "  SQS_QUEUE_URL=$QUEUE_URL"
echo "  DYNAMODB_TABLE_NAME=fsamp-local-file-metadata"
echo "  KMS_KEY_ID=alias/fsamp-local-master-key"
echo "  COGNITO_USER_POOL_ID=$USER_POOL_ID"
echo "  COGNITO_CLIENT_ID=$CLIENT_ID"
echo ""
echo "JWKS Endpoint: http://localhost:4566/$USER_POOL_ID/.well-known/jwks.json"
echo ""

# -----------------------------------------------------------------------------
# Save config to shared volume for other services
# -----------------------------------------------------------------------------
CONFIG_FILE="/tmp/localstack-config/fsamp-config.env"
mkdir -p /tmp/localstack-config

cat > "$CONFIG_FILE" << ENVFILE
# FSAMP LocalStack Configuration
# Generated by init-aws.sh at $(date -u +"%Y-%m-%dT%H:%M:%SZ")

export AWS_ENDPOINT_URL=http://localstack:4566
export AWS_REGION=$REGION

# S3
export S3_BUCKET_NAME=fsamp-local-files

# SNS
export SNS_TOPIC_ARN=$SNS_TOPIC_ARN

# SQS
export SQS_QUEUE_URL=http://localstack:4566/000000000000/fsamp-local-processing-queue

# DynamoDB
export DYNAMODB_TABLE_NAME=fsamp-local-file-metadata

# KMS - Full ARN required for schema validation
export KMS_KEY_ID=arn:aws:kms:$REGION:$ACCOUNT_ID:key/$KMS_KEY_ID
export KMS_KEY_ALIAS=alias/fsamp-local-master-key

# Cognito
export COGNITO_USER_POOL_ID=$USER_POOL_ID
export COGNITO_CLIENT_ID=$CLIENT_ID
export COGNITO_JWKS_ENDPOINT=http://localstack:4566/$USER_POOL_ID/.well-known/jwks.json
export COGNITO_ISSUER_URI=http://localstack:4566/$USER_POOL_ID

# Test users
export TEST_USER=e2e-test-user
export TEST_PASSWORD=E2eTestPass123!
export ADMIN_USER=e2e-admin-user
export ADMIN_PASSWORD=E2eAdminPass123!
ENVFILE

echo "✓ Config saved to $CONFIG_FILE"
