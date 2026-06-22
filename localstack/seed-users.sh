#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TERRAFORM_DIR="${ROOT_DIR}/terraform"
AWS_REGION="${AWS_REGION:-us-west-2}"
LOCALSTACK_ENDPOINT="${LOCALSTACK_ENDPOINT:-http://localhost:4566}"
TEST_PASSWORD="${TEST_PASSWORD:-E2eTestPass123!}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-E2eAdminPass123!}"

export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-${AWS_REGION}}"

aws_local() {
  aws --endpoint-url "${LOCALSTACK_ENDPOINT}" --region "${AWS_REGION}" "$@"
}

tf_raw() {
  terraform -chdir="${TERRAFORM_DIR}" output -raw "$1"
}

create_or_update_user() {
  local username="$1"
  local email="$2"
  local password="$3"
  local group="$4"
  local display_name="$5"

  local create_output
  local create_status

  set +e
  create_output="$(
    aws_local cognito-idp admin-create-user \
      --user-pool-id "${USER_POOL_ID}" \
      --username "${username}" \
      --temporary-password "TempPass123!" \
      --message-action SUPPRESS \
      --user-attributes \
        "Name=email,Value=${email}" \
        "Name=email_verified,Value=true" \
        "Name=name,Value=${display_name}" \
      2>&1
  )"
  create_status=$?
  set -e

  if [ "${create_status}" -ne 0 ] && [[ "${create_output}" != *"UsernameExistsException"* ]]; then
    printf '%s\n' "${create_output}" >&2
    return "${create_status}"
  fi

  aws_local cognito-idp admin-update-user-attributes \
    --user-pool-id "${USER_POOL_ID}" \
    --username "${username}" \
    --user-attributes \
      "Name=email,Value=${email}" \
      "Name=email_verified,Value=true" \
      "Name=name,Value=${display_name}" \
    >/dev/null

  aws_local cognito-idp admin-set-user-password \
    --user-pool-id "${USER_POOL_ID}" \
    --username "${username}" \
    --password "${password}" \
    --permanent \
    >/dev/null

  aws_local cognito-idp admin-add-user-to-group \
    --user-pool-id "${USER_POOL_ID}" \
    --username "${username}" \
    --group-name "${group}" \
    >/dev/null

  echo "Seeded Cognito user ${username} in group ${group}"
}

USER_POOL_ID="$(tf_raw cognito_user_pool_id)"

create_or_update_user "e2e@test.local" "e2e@test.local" "${TEST_PASSWORD}" "users" "FSAMP Demo User"
create_or_update_user "admin@test.local" "admin@test.local" "${ADMIN_PASSWORD}" "admins" "FSAMP Demo Admin"

echo "LocalStack Cognito users are ready in ${USER_POOL_ID}"
