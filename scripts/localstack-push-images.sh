#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TERRAFORM_DIR="${ROOT_DIR}/terraform"
GATEWAY_DIR="${GATEWAY_DIR:-${ROOT_DIR}/../fsamp-gateway}"
PROCESSOR_DIR="${PROCESSOR_DIR:-${ROOT_DIR}/../fsamp-processor}"
LOCALSTACK_ENDPOINT="${LOCALSTACK_ENDPOINT:-http://localhost:4566}"
AWS_REGION="${AWS_REGION:-us-west-2}"
IMAGE_TAG="${LOCAL_PARITY_IMAGE_TAG:-local-parity}"
PROCESSOR_PLATFORM="${PROCESSOR_PLATFORM:-linux/arm64}"

export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-${AWS_REGION}}"

require_output() {
  local key="$1"
  terraform -chdir="${TERRAFORM_DIR}" output -json ecr_repository_urls \
    | jq -er --arg key "$key" '.[$key]'
}

docker_resolvable_repo() {
  local repo="$1"
  echo "${repo/.localstack:4566/.localhost.localstack.cloud:4566}"
}

gateway_repo="$(docker_resolvable_repo "$(require_output gateway)")"
processor_repo="$(docker_resolvable_repo "$(require_output processor)")"
registry="${gateway_repo%%/*}"

echo "Logging in to LocalStack ECR registry: ${registry}"
aws --endpoint-url="${LOCALSTACK_ENDPOINT}" --region "${AWS_REGION}" ecr get-login-password \
  | docker login --username AWS --password-stdin "${registry}" >/dev/null

delete_existing_tag() {
  local repository_name="$1"
  aws --endpoint-url="${LOCALSTACK_ENDPOINT}" --region "${AWS_REGION}" ecr batch-delete-image \
    --repository-name "${repository_name}" \
    --image-ids "imageTag=${IMAGE_TAG}" >/dev/null 2>&1 || true
}

gateway_repo_name="$(terraform -chdir="${TERRAFORM_DIR}" output -json ecr_repository_names | jq -er '.gateway')"
processor_repo_name="$(terraform -chdir="${TERRAFORM_DIR}" output -json ecr_repository_names | jq -er '.processor')"

delete_existing_tag "${gateway_repo_name}"
delete_existing_tag "${processor_repo_name}"

echo "Building gateway image: ${gateway_repo}:${IMAGE_TAG}"
docker build -t "${gateway_repo}:${IMAGE_TAG}" "${GATEWAY_DIR}"
docker push "${gateway_repo}:${IMAGE_TAG}"

echo "Building processor Lambda image: ${processor_repo}:${IMAGE_TAG}"
docker build --platform "${PROCESSOR_PLATFORM}" -f "${PROCESSOR_DIR}/Dockerfile.lambda" \
  -t "${processor_repo}:${IMAGE_TAG}" "${PROCESSOR_DIR}"
docker push "${processor_repo}:${IMAGE_TAG}"

echo "LocalStack ECR images are ready with tag ${IMAGE_TAG}"
