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
#   - IAM roles (gateway, processor) with least-privilege policies
#   - Cognito user pool and test users
#   - (optional) CloudTrail, GuardDuty, AWS Config audit services
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
        AttributeName=fileId,AttributeType=S \
        AttributeName=uploadTimestamp,AttributeType=S \
        AttributeName=status,AttributeType=S \
    --key-schema \
        AttributeName=fileId,KeyType=HASH \
        AttributeName=uploadTimestamp,KeyType=RANGE \
    --global-secondary-indexes '[
        {
            "IndexName": "status-index",
            "KeySchema": [
                {"AttributeName": "status", "KeyType": "HASH"},
                {"AttributeName": "uploadTimestamp", "KeyType": "RANGE"}
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
# DynamoDB - Outbox Table (Transactional Outbox Pattern)
# -----------------------------------------------------------------------------
echo "Creating DynamoDB outbox table..."
awslocal dynamodb create-table \
    --table-name "fsamp-local-outbox" \
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
    --stream-specification StreamEnabled=true,StreamViewType=NEW_IMAGE \
    2>/dev/null || echo "  (table may already exist)"

# Enable TTL on outbox table for automatic cleanup
awslocal dynamodb update-time-to-live \
    --table-name "fsamp-local-outbox" \
    --time-to-live-specification Enabled=true,AttributeName=ttl \
    2>/dev/null || true

echo "  ✓ DynamoDB outbox table created: fsamp-local-outbox (with Streams)"

# -----------------------------------------------------------------------------
# DynamoDB - Idempotency Keys Table
# -----------------------------------------------------------------------------
echo "Creating DynamoDB idempotency keys table..."
awslocal dynamodb create-table \
    --table-name "fsamp-local-idempotency-keys" \
    --attribute-definitions \
        AttributeName=idempotencyKey,AttributeType=S \
        AttributeName=userId,AttributeType=S \
    --key-schema \
        AttributeName=idempotencyKey,KeyType=HASH \
        AttributeName=userId,KeyType=RANGE \
    --provisioned-throughput ReadCapacityUnits=5,WriteCapacityUnits=5 \
    --sse-specification Enabled=true,SSEType=KMS,KMSMasterKeyId="$KMS_KEY_ID" \
    2>/dev/null || echo "  (table may already exist)"

# Enable TTL on idempotency keys table (keys expire after 24 hours)
awslocal dynamodb update-time-to-live \
    --table-name "fsamp-local-idempotency-keys" \
    --time-to-live-specification Enabled=true,AttributeName=ttl \
    2>/dev/null || true

echo "  ✓ DynamoDB idempotency keys table created: fsamp-local-idempotency-keys"

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
# IAM - Least-Privilege Roles (FedRAMP AC-6)
# -----------------------------------------------------------------------------
echo "Creating IAM roles and policies..."

# Gateway role — S3 read/write, SNS publish, DynamoDB, KMS encrypt
awslocal iam create-role \
    --role-name "fsamp-gateway-role" \
    --assume-role-policy-document '{
        "Version": "2012-10-17",
        "Statement": [{
            "Effect": "Allow",
            "Principal": {"Service": "ecs-tasks.amazonaws.com"},
            "Action": "sts:AssumeRole"
        }]
    }' 2>/dev/null || true

awslocal iam put-role-policy \
    --role-name "fsamp-gateway-role" \
    --policy-name "fsamp-gateway-policy" \
    --policy-document '{
        "Version": "2012-10-17",
        "Statement": [
            {
                "Sid": "S3Access",
                "Effect": "Allow",
                "Action": ["s3:PutObject", "s3:GetObject", "s3:HeadObject", "s3:ListBucket"],
                "Resource": [
                    "arn:aws:s3:::fsamp-local-files",
                    "arn:aws:s3:::fsamp-local-files/*"
                ]
            },
            {
                "Sid": "SNSPublish",
                "Effect": "Allow",
                "Action": ["sns:Publish"],
                "Resource": "arn:aws:sns:'"$REGION"':'"$ACCOUNT_ID"':fsamp-local-file-events"
            },
            {
                "Sid": "DynamoDBAccess",
                "Effect": "Allow",
                "Action": ["dynamodb:PutItem", "dynamodb:GetItem", "dynamodb:Query", "dynamodb:UpdateItem", "dynamodb:DeleteItem"],
                "Resource": [
                    "arn:aws:dynamodb:'"$REGION"':'"$ACCOUNT_ID"':table/fsamp-local-file-metadata",
                    "arn:aws:dynamodb:'"$REGION"':'"$ACCOUNT_ID"':table/fsamp-local-file-metadata/*",
                    "arn:aws:dynamodb:'"$REGION"':'"$ACCOUNT_ID"':table/fsamp-local-idempotency-keys",
                    "arn:aws:dynamodb:'"$REGION"':'"$ACCOUNT_ID"':table/fsamp-local-idempotency-keys/*"
                ]
            },
            {
                "Sid": "KMSEncrypt",
                "Effect": "Allow",
                "Action": ["kms:Encrypt", "kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"],
                "Resource": "arn:aws:kms:'"$REGION"':'"$ACCOUNT_ID"':key/'"$KMS_KEY_ID"'"
            }
        ]
    }'

echo "  ✓ Gateway IAM role created: fsamp-gateway-role"

# Processor role — SQS consume, S3 read, DynamoDB write, KMS decrypt
awslocal iam create-role \
    --role-name "fsamp-processor-role" \
    --assume-role-policy-document '{
        "Version": "2012-10-17",
        "Statement": [{
            "Effect": "Allow",
            "Principal": {"Service": "lambda.amazonaws.com"},
            "Action": "sts:AssumeRole"
        }]
    }' 2>/dev/null || true

awslocal iam put-role-policy \
    --role-name "fsamp-processor-role" \
    --policy-name "fsamp-processor-policy" \
    --policy-document '{
        "Version": "2012-10-17",
        "Statement": [
            {
                "Sid": "SQSConsume",
                "Effect": "Allow",
                "Action": ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes", "sqs:ChangeMessageVisibility"],
                "Resource": "arn:aws:sqs:'"$REGION"':'"$ACCOUNT_ID"':fsamp-local-processing-queue"
            },
            {
                "Sid": "S3ReadOnly",
                "Effect": "Allow",
                "Action": ["s3:GetObject", "s3:HeadObject"],
                "Resource": "arn:aws:s3:::fsamp-local-files/*"
            },
            {
                "Sid": "DynamoDBWrite",
                "Effect": "Allow",
                "Action": ["dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:GetItem", "dynamodb:Query", "dynamodb:DeleteItem"],
                "Resource": [
                    "arn:aws:dynamodb:'"$REGION"':'"$ACCOUNT_ID"':table/fsamp-local-file-metadata",
                    "arn:aws:dynamodb:'"$REGION"':'"$ACCOUNT_ID"':table/fsamp-local-file-metadata/*",
                    "arn:aws:dynamodb:'"$REGION"':'"$ACCOUNT_ID"':table/fsamp-local-outbox",
                    "arn:aws:dynamodb:'"$REGION"':'"$ACCOUNT_ID"':table/fsamp-local-outbox/*"
                ]
            },
            {
                "Sid": "KMSDecrypt",
                "Effect": "Allow",
                "Action": ["kms:Decrypt", "kms:DescribeKey"],
                "Resource": "arn:aws:kms:'"$REGION"':'"$ACCOUNT_ID"':key/'"$KMS_KEY_ID"'"
            },
            {
                "Sid": "CloudWatchLogs",
                "Effect": "Allow",
                "Action": ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"],
                "Resource": "arn:aws:logs:'"$REGION"':'"$ACCOUNT_ID"':log-group:/aws/lambda/fsamp-*"
            }
        ]
    }'

echo "  ✓ Processor IAM role created: fsamp-processor-role"

# -----------------------------------------------------------------------------
# Audit Services (FedRAMP AU-2, AU-3, AU-6, SI-4)
# Feature-flagged: set ENABLE_AUDIT_SERVICES=1 to activate
# -----------------------------------------------------------------------------
if [[ "${ENABLE_AUDIT_SERVICES:-0}" == "1" ]]; then
    echo "Setting up audit services (CloudTrail, GuardDuty, Config)..."

    # --- CloudTrail (AU-2, AU-3) ---
    # Create CloudTrail log bucket
    awslocal s3 mb "s3://fsamp-local-cloudtrail-logs" 2>/dev/null || true
    awslocal s3api put-bucket-policy \
        --bucket fsamp-local-cloudtrail-logs \
        --policy '{
            "Version": "2012-10-17",
            "Statement": [{
                "Sid": "CloudTrailWrite",
                "Effect": "Allow",
                "Principal": {"Service": "cloudtrail.amazonaws.com"},
                "Action": "s3:PutObject",
                "Resource": "arn:aws:s3:::fsamp-local-cloudtrail-logs/AWSLogs/'"$ACCOUNT_ID"'/*"
            }, {
                "Sid": "CloudTrailACLCheck",
                "Effect": "Allow",
                "Principal": {"Service": "cloudtrail.amazonaws.com"},
                "Action": "s3:GetBucketAcl",
                "Resource": "arn:aws:s3:::fsamp-local-cloudtrail-logs"
            }]
        }'

    awslocal cloudtrail create-trail \
        --name "fsamp-local-trail" \
        --s3-bucket-name "fsamp-local-cloudtrail-logs" \
        --is-multi-region-trail \
        --enable-log-file-validation \
        2>/dev/null || echo "  (trail may already exist)"

    awslocal cloudtrail start-logging --name "fsamp-local-trail" 2>/dev/null || true

    echo "  ✓ CloudTrail trail created: fsamp-local-trail"

    # --- GuardDuty (SI-4) ---
    DETECTOR_ID=$(awslocal guardduty create-detector \
        --enable \
        --finding-publishing-frequency FIFTEEN_MINUTES \
        --query 'DetectorId' \
        --output text 2>/dev/null || echo "existing")

    echo "  ✓ GuardDuty detector created: $DETECTOR_ID"

    # --- AWS Config (CM-2, CM-6) ---
    awslocal s3 mb "s3://fsamp-local-config-logs" 2>/dev/null || true

    # Config recorder
    awslocal configservice put-configuration-recorder \
        --configuration-recorder '{
            "name": "fsamp-local-recorder",
            "roleARN": "arn:aws:iam::'"$ACCOUNT_ID"':role/aws-service-role/config.amazonaws.com/AWSServiceRoleForConfig",
            "recordingGroup": {
                "allSupported": true,
                "includeGlobalResourceTypes": true
            }
        }' 2>/dev/null || true

    awslocal configservice put-delivery-channel \
        --delivery-channel '{
            "name": "fsamp-local-channel",
            "s3BucketName": "fsamp-local-config-logs",
            "configSnapshotDeliveryProperties": {
                "deliveryFrequency": "One_Hour"
            }
        }' 2>/dev/null || true

    awslocal configservice start-configuration-recorder \
        --configuration-recorder-name "fsamp-local-recorder" 2>/dev/null || true

    echo "  ✓ AWS Config recorder started: fsamp-local-recorder"
    echo "  ✓ Audit services initialization complete"
else
    echo "Skipping audit services (set ENABLE_AUDIT_SERVICES=1 to enable)"
fi

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
echo "  DynamoDB:      fsamp-local-outbox (Streams enabled)"
echo "  DynamoDB:      fsamp-local-idempotency-keys"
echo "  KMS Key:       alias/fsamp-local-master-key"
echo "  IAM Roles:     fsamp-gateway-role, fsamp-processor-role"
if [[ "${ENABLE_AUDIT_SERVICES:-0}" == "1" ]]; then
echo "  CloudTrail:    fsamp-local-trail"
echo "  GuardDuty:     detector $DETECTOR_ID"
echo "  AWS Config:    fsamp-local-recorder"
fi
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
export DYNAMODB_OUTBOX_TABLE_NAME=fsamp-local-outbox
export DYNAMODB_IDEMPOTENCY_TABLE_NAME=fsamp-local-idempotency-keys

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
