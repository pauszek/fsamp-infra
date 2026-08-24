#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALIDATOR="${SCRIPT_DIR}/validate-drift-config.sh"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "${TEST_DIR}"' EXIT

run_validator() {
    local output_file="$1"
    shift
    env \
        GITHUB_OUTPUT="${output_file}" \
        AWS_ACCOUNT_ID_DEV="123456789012" \
        AWS_ACCOUNT_ID_STAGING="234567890123" \
        AWS_ACCOUNT_ID_PROD="345678901234" \
        AWS_DRIFT_ROLE_ARN_DEV="arn:aws:iam::123456789012:role/fsamp-dev-plan" \
        AWS_DRIFT_ROLE_ARN_STAGING="arn:aws:iam::234567890123:role/fsamp-staging-plan" \
        AWS_DRIFT_ROLE_ARN_PROD="arn:aws:iam::345678901234:role/fsamp-prod-plan" \
        "$@" \
        bash "${VALIDATOR}"
}

disabled_output="${TEST_DIR}/disabled.out"
run_validator "${disabled_output}" DRIFT_DETECTION_ENABLED=false
grep -qx 'enabled=false' "${disabled_output}"

enabled_output="${TEST_DIR}/enabled.out"
run_validator "${enabled_output}" DRIFT_DETECTION_ENABLED=true
grep -qx 'enabled=true' "${enabled_output}"

invalid_account_output="${TEST_DIR}/invalid-account.out"
if run_validator \
    "${invalid_account_output}" \
    DRIFT_DETECTION_ENABLED=true \
    AWS_ACCOUNT_ID_STAGING=not-an-account; then
    echo "Expected an invalid account ID to fail"
    exit 1
fi

wrong_role_output="${TEST_DIR}/wrong-role.out"
if run_validator \
    "${wrong_role_output}" \
    DRIFT_DETECTION_ENABLED=true \
    AWS_DRIFT_ROLE_ARN_PROD=arn:aws:iam::123456789012:role/fsamp-prod-plan; then
    echo "Expected a role from another account to fail"
    exit 1
fi
