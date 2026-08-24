#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TERRAFORM_DIR="${ROOT_DIR}/terraform"
TARGET_PATH="${1:-${ROOT_DIR}/../fsamp-demo-flow/.env.local}"
AWS_REGION="${AWS_REGION:-us-west-2}"
LOCALSTACK_ENDPOINT="${LOCALSTACK_ENDPOINT:-http://localhost:4566}"

existing_token=""
if [ -f "${TARGET_PATH}" ]; then
  existing_token="$(grep -E '^LOCALSTACK_AUTH_TOKEN=' "${TARGET_PATH}" | tail -1 | cut -d= -f2- || true)"
fi
token="${LOCALSTACK_AUTH_TOKEN:-${existing_token}}"

tf_output() {
  terraform -chdir="${TERRAFORM_DIR}" output -json "$1"
}

tf_raw() {
  terraform -chdir="${TERRAFORM_DIR}" output -raw "$1"
}

require_jq() {
  local json="$1"
  local path="$2"
  printf '%s' "${json}" | jq -er "${path}"
}

s3_buckets="$(tf_output s3_buckets)"
tables="$(tf_output dynamodb_table_names)"
queues="$(tf_output sqs_queue_urls)"
topics="$(tf_output sns_topic_arns)"

api_gateway_endpoint="$(tf_raw api_gateway_endpoint)"
api_gateway_id="$(tf_raw api_gateway_id)"
gateway_alb_dns_name="$(tf_raw gateway_alb_dns_name)"
ecs_cluster_name="$(tf_raw ecs_cluster_name)"
gateway_service_name="$(tf_raw gateway_service_name)"
processor_lambda_name="$(tf_raw processor_lambda_name)"
outbox_publisher_lambda_name="$(tf_raw outbox_publisher_lambda_name)"
gateway_role_arn="$(tf_raw ecs_task_role_arn)"
processor_role_arn="$(tf_raw lambda_role_arn)"

files_bucket="$(require_jq "${s3_buckets}" '.files')"
metadata_table="$(require_jq "${tables}" '.file_metadata')"
outbox_table="$(require_jq "${tables}" '.outbox')"
idempotency_table="$(require_jq "${tables}" '.idempotency_keys')"
processing_queue_url="$(require_jq "${queues}" '.file_processing')"
processing_dlq_url="$(require_jq "${queues}" '.dlq')"
file_events_topic_arn="$(require_jq "${topics}" '.file_events')"
processing_events_topic_arn="$(require_jq "${topics}" '.processing_events')"
kms_key_arn="$(tf_raw kms_key_arn)"
cognito_user_pool_id="$(tf_raw cognito_user_pool_id)"
cognito_client_id="$(tf_raw cognito_web_client_id)"
cognito_resource_server_identifier="$(tf_raw cognito_resource_server_identifier)"

queue_name="${processing_queue_url##*/}"
dlq_name="${processing_dlq_url##*/}"
gateway_role_name="${gateway_role_arn##*/}"
processor_role_name="${processor_role_arn##*/}"
api_gateway_stage="${api_gateway_endpoint%/}"
api_gateway_stage="${api_gateway_stage##*/}"
localstack_edge_port="$(printf '%s' "${LOCALSTACK_ENDPOINT}" | sed -E 's#^https?://[^/:]+:([0-9]+).*$#\1#')"
if [ "${localstack_edge_port}" = "${LOCALSTACK_ENDPOINT}" ]; then
  localstack_edge_port="4566"
fi
localstack_api_gateway_host="${LOCALSTACK_API_GATEWAY_HOST:-localhost.localstack.cloud}"
local_api_gateway_endpoint="http://${api_gateway_id}.execute-api.${localstack_api_gateway_host}:${localstack_edge_port}/${api_gateway_stage}"

mkdir -p "$(dirname "${TARGET_PATH}")"
tmp_file="$(mktemp)"

cat > "${tmp_file}" <<EOF
LOCALSTACK_AUTH_TOKEN=${token}
LOCALSTACK_DEBUG=0

FSAMP_DEMO_RUNTIME=terraform-local
DIRECT_PUBLISH_AFTER_OUTBOX=false

GATEWAY_URL=${local_api_gateway_endpoint}
GATEWAY_UPLOAD_PATH=/files/upload
GATEWAY_FILES_PATH=/files
GATEWAY_HEALTH_PATH=/health
GATEWAY_MANAGEMENT_URL=https://${gateway_alb_dns_name}:${localstack_edge_port}
GATEWAY_MANAGEMENT_VERIFY_TLS=false

AWS_ENDPOINT_URL=${LOCALSTACK_ENDPOINT}
AWS_REGION=${AWS_REGION}
AWS_ACCESS_KEY_ID=test
AWS_SECRET_ACCESS_KEY=test

S3_BUCKET_NAME=${files_bucket}
DYNAMODB_TABLE_NAME=${metadata_table}
OUTBOX_TABLE_NAME=${outbox_table}
DYNAMODB_IDEMPOTENCY_TABLE_NAME=${idempotency_table}

SQS_QUEUE_NAME=${queue_name}
SQS_QUEUE_URL=${processing_queue_url}
SQS_PROCESSING_DLQ_NAME=${dlq_name}
SQS_PROCESSING_DLQ_URL=${processing_dlq_url}
FILE_EVENTS_AUDIT_QUEUE_NAME=fsamp-local-file-events-audit
PROCESSING_EVENTS_AUDIT_QUEUE_NAME=fsamp-local-processing-events-audit
EXPECTED_AUDIT_SERVICES=cloudtrail,config

SNS_TOPIC_ARN=${file_events_topic_arn}
FILE_EVENTS_TOPIC_ARN=${file_events_topic_arn}
PROCESSING_EVENTS_TOPIC_ARN=${processing_events_topic_arn}
KMS_KEY_ID=${kms_key_arn}

COGNITO_USER_POOL_ID=${cognito_user_pool_id}
COGNITO_CLIENT_ID=${cognito_client_id}
COGNITO_RESOURCE_SERVER_IDENTIFIER=${cognito_resource_server_identifier}
TEST_USER=e2e@test.local
TEST_PASSWORD=E2eTestPass123!
ADMIN_USER=admin@test.local
ADMIN_PASSWORD=E2eAdminPass123!
GATEWAY_ROLE_NAME=${gateway_role_name}
PROCESSOR_ROLE_NAME=${processor_role_name}
ECS_CLUSTER_NAME=${ecs_cluster_name}
GATEWAY_SERVICE_NAME=${gateway_service_name}
GATEWAY_CONTAINER_NAME=gateway

PROCESSOR_LAMBDA_NAME=${processor_lambda_name}
OUTBOX_PUBLISHER_LAMBDA_NAME=${outbox_publisher_lambda_name}
FSAMP_DEMO_DOCKER_LOGS=false
EOF

mv "${tmp_file}" "${TARGET_PATH}"
echo "Wrote demo environment to ${TARGET_PATH}"
