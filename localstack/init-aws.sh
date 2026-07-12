#!/bin/bash
set -euo pipefail

REGION="${AWS_DEFAULT_REGION:-us-west-2}"
ACCOUNT_ID="000000000000"
ENDPOINT="http://localhost:4566"
CONFIG_FILE="/tmp/localstack-config/fsamp-config.env"

if [[ "${FSAMP_TF_MANAGED:-0}" == "1" ]]; then
    echo "Skipping legacy LocalStack bootstrap; Terraform manages FSAMP resources."
    exit 0
fi

export AWS_ACCESS_KEY_ID="test"
export AWS_SECRET_ACCESS_KEY="test"
export AWS_DEFAULT_REGION="$REGION"

rm -f "$CONFIG_FILE" 2>/dev/null || true

echo "Initializing FSAMP LocalStack resources..."
echo "Region: $REGION"
echo ""

if command -v awslocal &> /dev/null; then
    awslocal() {
        command awslocal "$@"
    }
else
    awslocal() {
        aws --endpoint-url="$ENDPOINT" --region "$REGION" "$@"
    }
fi
echo "Creating KMS key..."
KMS_KEY_ID=$(awslocal kms create-key \
    --description "FSAMP master encryption key" \
    --query 'KeyMetadata.KeyId' \
    --output text)

awslocal kms create-alias \
    --alias-name "alias/fsamp-local-master-key" \
    --target-key-id "$KMS_KEY_ID"

echo "  OK KMS key created: $KMS_KEY_ID"
echo "Creating S3 bucket..."
awslocal s3 mb "s3://fsamp-local-files" || true

awslocal s3api put-bucket-versioning \
    --bucket fsamp-local-files \
    --versioning-configuration Status=Enabled

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

echo "  OK S3 bucket created: fsamp-local-files"
echo "Creating SNS topics..."
FILE_EVENTS_TOPIC_ARN=$(awslocal sns create-topic \
    --name "fsamp-local-file-events" \
    --query 'TopicArn' \
    --output text)

PROCESSING_EVENTS_TOPIC_ARN=$(awslocal sns create-topic \
    --name "fsamp-local-processing-events" \
    --query 'TopicArn' \
    --output text)

# Backward-compatible name consumed by the gateway local profile.
SNS_TOPIC_ARN="$FILE_EVENTS_TOPIC_ARN"

echo "  OK file events topic created: $FILE_EVENTS_TOPIC_ARN"
echo "  OK processing events topic created: $PROCESSING_EVENTS_TOPIC_ARN"
echo "Creating SQS queues..."

DLQ_URL=$(awslocal sqs create-queue \
    --queue-name "fsamp-local-processing-dlq" \
    --query 'QueueUrl' \
    --output text)

DLQ_ARN=$(awslocal sqs get-queue-attributes \
    --queue-url "$DLQ_URL" \
    --attribute-names QueueArn \
    --query 'Attributes.QueueArn' \
    --output text)

QUEUE_URL=$(awslocal sqs create-queue \
    --queue-name "fsamp-local-processing-queue" \
    --attributes '{
        "VisibilityTimeout": "1805",
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

FILE_EVENTS_AUDIT_QUEUE_URL=$(awslocal sqs create-queue \
    --queue-name "fsamp-local-file-events-audit" \
    --attributes '{"MessageRetentionPeriod":"1209600"}' \
    --query 'QueueUrl' \
    --output text)

FILE_EVENTS_AUDIT_QUEUE_ARN=$(awslocal sqs get-queue-attributes \
    --queue-url "$FILE_EVENTS_AUDIT_QUEUE_URL" \
    --attribute-names QueueArn \
    --query 'Attributes.QueueArn' \
    --output text)

PROCESSING_EVENTS_AUDIT_QUEUE_URL=$(awslocal sqs create-queue \
    --queue-name "fsamp-local-processing-events-audit" \
    --attributes '{"MessageRetentionPeriod":"1209600"}' \
    --query 'QueueUrl' \
    --output text)

PROCESSING_EVENTS_AUDIT_QUEUE_ARN=$(awslocal sqs get-queue-attributes \
    --queue-url "$PROCESSING_EVENTS_AUDIT_QUEUE_URL" \
    --attribute-names QueueArn \
    --query 'Attributes.QueueArn' \
    --output text)

echo "  OK SQS queue created: $QUEUE_URL"
echo "  OK SQS DLQ created: $DLQ_URL"
echo "Creating SNS -> SQS subscription..."

awslocal sqs set-queue-attributes \
    --queue-url "$QUEUE_URL" \
    --attributes '{
        "Policy": "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":{\"Service\":\"sns.amazonaws.com\"},\"Action\":\"sqs:SendMessage\",\"Resource\":\"'"$QUEUE_ARN"'\",\"Condition\":{\"ArnEquals\":{\"aws:SourceArn\":\"'"$FILE_EVENTS_TOPIC_ARN"'\"}}}]}"
    }'

awslocal sns subscribe \
    --topic-arn "$FILE_EVENTS_TOPIC_ARN" \
    --protocol sqs \
    --notification-endpoint "$QUEUE_ARN" \
    --attributes '{"RawMessageDelivery": "true"}'

awslocal sqs set-queue-attributes \
    --queue-url "$FILE_EVENTS_AUDIT_QUEUE_URL" \
    --attributes '{
        "Policy": "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":{\"Service\":\"sns.amazonaws.com\"},\"Action\":\"sqs:SendMessage\",\"Resource\":\"'"$FILE_EVENTS_AUDIT_QUEUE_ARN"'\",\"Condition\":{\"ArnEquals\":{\"aws:SourceArn\":\"'"$FILE_EVENTS_TOPIC_ARN"'\"}}}]}"
    }'

awslocal sns subscribe \
    --topic-arn "$FILE_EVENTS_TOPIC_ARN" \
    --protocol sqs \
    --notification-endpoint "$FILE_EVENTS_AUDIT_QUEUE_ARN" \
    --attributes '{"RawMessageDelivery": "true"}'

awslocal sqs set-queue-attributes \
    --queue-url "$PROCESSING_EVENTS_AUDIT_QUEUE_URL" \
    --attributes '{
        "Policy": "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":{\"Service\":\"sns.amazonaws.com\"},\"Action\":\"sqs:SendMessage\",\"Resource\":\"'"$PROCESSING_EVENTS_AUDIT_QUEUE_ARN"'\",\"Condition\":{\"ArnEquals\":{\"aws:SourceArn\":\"'"$PROCESSING_EVENTS_TOPIC_ARN"'\"}}}]}"
    }'

awslocal sns subscribe \
    --topic-arn "$PROCESSING_EVENTS_TOPIC_ARN" \
    --protocol sqs \
    --notification-endpoint "$PROCESSING_EVENTS_AUDIT_QUEUE_ARN" \
    --attributes '{"RawMessageDelivery": "true"}'

echo "  OK SNS -> SQS subscriptions created"
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

awslocal dynamodb wait table-exists --table-name "fsamp-local-file-metadata"
echo "  OK DynamoDB table created: fsamp-local-file-metadata"
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

awslocal dynamodb wait table-exists --table-name "fsamp-local-outbox"

awslocal dynamodb update-time-to-live \
    --table-name "fsamp-local-outbox" \
    --time-to-live-specification Enabled=true,AttributeName=ttl \
    2>/dev/null || true

echo "  OK DynamoDB outbox table created: fsamp-local-outbox (with Streams)"
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

awslocal dynamodb wait table-exists --table-name "fsamp-local-idempotency-keys"

awslocal dynamodb update-time-to-live \
    --table-name "fsamp-local-idempotency-keys" \
    --time-to-live-specification Enabled=true,AttributeName=ttl \
    2>/dev/null || true

echo "  OK DynamoDB idempotency keys table created: fsamp-local-idempotency-keys"
echo "Creating Cognito User Pool..."

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

echo "  OK Cognito User Pool created: $USER_POOL_ID"

CLIENT_ID=$(awslocal cognito-idp create-user-pool-client \
    --user-pool-id "$USER_POOL_ID" \
    --client-name "fsamp-local-client" \
    --explicit-auth-flows ADMIN_NO_SRP_AUTH ALLOW_USER_PASSWORD_AUTH ALLOW_REFRESH_TOKEN_AUTH \
    --query 'UserPoolClient.ClientId' \
    --output text)

echo "  OK Cognito App Client created: $CLIENT_ID"

awslocal cognito-idp create-resource-server \
    --user-pool-id "$USER_POOL_ID" \
    --identifier "fsamp-api" \
    --name "FSAMP API" \
    --scopes '[
        {"ScopeName": "files.read", "ScopeDescription": "Read files"},
        {"ScopeName": "files.write", "ScopeDescription": "Write files"},
        {"ScopeName": "files.delete", "ScopeDescription": "Delete files"}
    ]'

echo "  OK Resource server created with scopes"

awslocal cognito-idp create-group \
    --user-pool-id "$USER_POOL_ID" \
    --group-name "USERS" \
    --description "Standard users"

awslocal cognito-idp create-group \
    --user-pool-id "$USER_POOL_ID" \
    --group-name "ADMINS" \
    --description "Administrator users"

echo "  OK User groups created (USERS, ADMINS)"

awslocal cognito-idp admin-create-user \
    --user-pool-id "$USER_POOL_ID" \
    --username "e2e-test-user" \
    --temporary-password "TempPass123!" \
    --user-attributes Name=email,Value=e2e@test.local Name=email_verified,Value=true \
    --message-action SUPPRESS

awslocal cognito-idp admin-set-user-password \
    --user-pool-id "$USER_POOL_ID" \
    --username "e2e-test-user" \
    --password "E2eTestPass123!" \
    --permanent

awslocal cognito-idp admin-add-user-to-group \
    --user-pool-id "$USER_POOL_ID" \
    --username "e2e-test-user" \
    --group-name "USERS"

echo "  OK Test user created: e2e-test-user"

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

echo "  OK Admin user created: e2e-admin-user"
echo "Creating IAM roles and policies..."

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
                "Action": ["s3:PutObject", "s3:GetObject", "s3:HeadObject", "s3:DeleteObject", "s3:ListBucket"],
                "Resource": [
                    "arn:aws:s3:::fsamp-local-files",
                    "arn:aws:s3:::fsamp-local-files/*"
                ]
            },
            {
                "Sid": "SNSPublish",
                "Effect": "Allow",
                "Action": ["sns:Publish"],
                "Resource": "arn:aws:sns:'"$REGION"':'"$ACCOUNT_ID"':fsamp-local-processing-events"
            },
            {
                "Sid": "DynamoDBAccess",
                "Effect": "Allow",
                "Action": ["dynamodb:PutItem", "dynamodb:GetItem", "dynamodb:Query", "dynamodb:UpdateItem", "dynamodb:DeleteItem", "dynamodb:TransactWriteItems"],
                "Resource": [
                    "arn:aws:dynamodb:'"$REGION"':'"$ACCOUNT_ID"':table/fsamp-local-file-metadata",
                    "arn:aws:dynamodb:'"$REGION"':'"$ACCOUNT_ID"':table/fsamp-local-file-metadata/*",
                    "arn:aws:dynamodb:'"$REGION"':'"$ACCOUNT_ID"':table/fsamp-local-outbox",
                    "arn:aws:dynamodb:'"$REGION"':'"$ACCOUNT_ID"':table/fsamp-local-outbox/*",
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

echo "  OK Gateway IAM role created: fsamp-gateway-role"

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
                "Sid": "S3SourceAccess",
                "Effect": "Allow",
                "Action": ["s3:GetObject", "s3:HeadObject", "s3:PutObject", "s3:DeleteObject"],
                "Resource": "arn:aws:s3:::fsamp-local-files/*"
            },
            {
                "Sid": "DynamoDBWrite",
                "Effect": "Allow",
                "Action": ["dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:GetItem", "dynamodb:Query", "dynamodb:DeleteItem", "dynamodb:TransactWriteItems", "dynamodb:DescribeStream", "dynamodb:GetRecords", "dynamodb:GetShardIterator", "dynamodb:ListStreams"],
                "Resource": [
                    "arn:aws:dynamodb:'"$REGION"':'"$ACCOUNT_ID"':table/fsamp-local-file-metadata",
                    "arn:aws:dynamodb:'"$REGION"':'"$ACCOUNT_ID"':table/fsamp-local-file-metadata/*",
                    "arn:aws:dynamodb:'"$REGION"':'"$ACCOUNT_ID"':table/fsamp-local-outbox",
                    "arn:aws:dynamodb:'"$REGION"':'"$ACCOUNT_ID"':table/fsamp-local-outbox/*"
                ]
            },
            {
                "Sid": "SNSPublish",
                "Effect": "Allow",
                "Action": ["sns:Publish"],
                "Resource": [
                    "arn:aws:sns:'"$REGION"':'"$ACCOUNT_ID"':fsamp-local-file-events",
                    "arn:aws:sns:'"$REGION"':'"$ACCOUNT_ID"':fsamp-local-processing-events"
                ]
            },
            {
                "Sid": "KMSDecrypt",
                "Effect": "Allow",
                "Action": ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"],
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

echo "  OK Processor IAM role created: fsamp-processor-role"
if [[ "${ENABLE_AUDIT_SERVICES:-0}" == "1" ]]; then
    echo "Setting up audit services (CloudTrail, GuardDuty, Config)..."

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

    echo "  OK CloudTrail trail created: fsamp-local-trail"

    DETECTOR_ID=$(awslocal guardduty create-detector \
        --enable \
        --finding-publishing-frequency FIFTEEN_MINUTES \
        --query 'DetectorId' \
        --output text 2>/dev/null || echo "existing")

    echo "  OK GuardDuty detector created: $DETECTOR_ID"

    awslocal s3 mb "s3://fsamp-local-config-logs" 2>/dev/null || true

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

    echo "  OK AWS Config recorder started: fsamp-local-recorder"
    echo "  OK Audit services initialization complete"
else
    echo "Skipping audit services (set ENABLE_AUDIT_SERVICES=1 to enable)"
fi
echo ""
echo "FSAMP LocalStack initialization complete"
echo ""
echo "Resources created:"
echo "  S3 Bucket:     s3://fsamp-local-files"
echo "  File Topic:    $FILE_EVENTS_TOPIC_ARN"
echo "  Result Topic:  $PROCESSING_EVENTS_TOPIC_ARN"
echo "  SQS Queue:     $QUEUE_URL"
echo "  SQS DLQ:       $DLQ_URL"
echo "  Audit Queue:   $FILE_EVENTS_AUDIT_QUEUE_URL"
echo "  Audit Queue:   $PROCESSING_EVENTS_AUDIT_QUEUE_URL"
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
echo "  PROCESSING_EVENTS_TOPIC_ARN=$PROCESSING_EVENTS_TOPIC_ARN"
echo "  SQS_QUEUE_URL=$QUEUE_URL"
echo "  DYNAMODB_TABLE_NAME=fsamp-local-file-metadata"
echo "  KMS_KEY_ID=alias/fsamp-local-master-key"
echo "  COGNITO_USER_POOL_ID=$USER_POOL_ID"
echo "  COGNITO_CLIENT_ID=$CLIENT_ID"
echo ""
echo "JWKS Endpoint: http://localhost:4566/$USER_POOL_ID/.well-known/jwks.json"
echo ""
CONFIG_FILE="/tmp/localstack-config/fsamp-config.env"
mkdir -p /tmp/localstack-config

cat > "$CONFIG_FILE" << ENVFILE

export AWS_ENDPOINT_URL=http://localstack:4566
export AWS_REGION=$REGION

export S3_BUCKET_NAME=fsamp-local-files

export SNS_TOPIC_ARN=$SNS_TOPIC_ARN
export FILE_EVENTS_TOPIC_ARN=$FILE_EVENTS_TOPIC_ARN
export PROCESSING_EVENTS_TOPIC_ARN=$PROCESSING_EVENTS_TOPIC_ARN

export SQS_QUEUE_URL=http://localstack:4566/000000000000/fsamp-local-processing-queue
export FILE_EVENTS_AUDIT_QUEUE_URL=http://localstack:4566/000000000000/fsamp-local-file-events-audit
export PROCESSING_EVENTS_AUDIT_QUEUE_URL=http://localstack:4566/000000000000/fsamp-local-processing-events-audit

export DYNAMODB_TABLE_NAME=fsamp-local-file-metadata
export DYNAMODB_OUTBOX_TABLE_NAME=fsamp-local-outbox
export OUTBOX_TABLE_NAME=fsamp-local-outbox
export DYNAMODB_IDEMPOTENCY_TABLE_NAME=fsamp-local-idempotency-keys

export KMS_KEY_ID=arn:aws:kms:$REGION:$ACCOUNT_ID:key/$KMS_KEY_ID
export KMS_KEY_ALIAS=alias/fsamp-local-master-key

export COGNITO_USER_POOL_ID=$USER_POOL_ID
export COGNITO_CLIENT_ID=$CLIENT_ID
export COGNITO_JWKS_ENDPOINT=http://localstack:4566/$USER_POOL_ID/.well-known/jwks.json
export COGNITO_ISSUER_URI=http://localstack:4566/$USER_POOL_ID

export TEST_USER=e2e-test-user
export TEST_PASSWORD=E2eTestPass123!
export ADMIN_USER=e2e-admin-user
export ADMIN_PASSWORD=E2eAdminPass123!
ENVFILE

echo "OK Config saved to $CONFIG_FILE"
