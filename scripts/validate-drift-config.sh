#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${GITHUB_OUTPUT:-}" ]]; then
    echo "::error::GITHUB_OUTPUT is required"
    exit 1
fi

if [[ "${DRIFT_DETECTION_ENABLED:-}" != "true" ]]; then
    echo "enabled=false" >> "${GITHUB_OUTPUT}"
    echo "::notice::Drift detection is explicitly disabled. Follow docs/DEPLOYMENT.md to activate it."
    exit 0
fi

AWS_ACCOUNT_ID_DEV="${AWS_ACCOUNT_ID_DEV:-}"
AWS_ACCOUNT_ID_STAGING="${AWS_ACCOUNT_ID_STAGING:-}"
AWS_ACCOUNT_ID_PROD="${AWS_ACCOUNT_ID_PROD:-}"
AWS_DRIFT_ROLE_ARN_DEV="${AWS_DRIFT_ROLE_ARN_DEV:-}"
AWS_DRIFT_ROLE_ARN_STAGING="${AWS_DRIFT_ROLE_ARN_STAGING:-}"
AWS_DRIFT_ROLE_ARN_PROD="${AWS_DRIFT_ROLE_ARN_PROD:-}"

for account_var in AWS_ACCOUNT_ID_DEV AWS_ACCOUNT_ID_STAGING AWS_ACCOUNT_ID_PROD; do
    account_id="${!account_var}"
    if [[ ! "${account_id}" =~ ^[0-9]{12}$ ]]; then
        echo "::error::${account_var} must be a 12-digit AWS account ID before drift detection is enabled."
        exit 1
    fi
done

for environment in DEV STAGING PROD; do
    account_var="AWS_ACCOUNT_ID_${environment}"
    role_var="AWS_DRIFT_ROLE_ARN_${environment}"
    account_id="${!account_var}"
    role_arn="${!role_var}"
    if [[ ! "${role_arn}" =~ ^arn:aws:iam::${account_id}:role/[A-Za-z0-9+=,.@_/-]+$ ]]; then
        echo "::error::${role_var} must be a role ARN in ${account_var}."
        exit 1
    fi
done

echo "enabled=true" >> "${GITHUB_OUTPUT}"
