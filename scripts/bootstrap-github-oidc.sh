#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  GITHUB_OWNER=pauszek GITHUB_REPO=fsamp-infra ./scripts/bootstrap-github-oidc.sh

Optional:
  AWS_REGION=us-west-2
  ROLE_NAME=fsamp-github-deploy
  GITHUB_SUB_PATTERN=repo:pauszek/fsamp-infra:*
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

command -v aws >/dev/null || { echo "aws CLI is required."; exit 1; }
command -v openssl >/dev/null || { echo "openssl is required."; exit 1; }

github_owner="${GITHUB_OWNER:-pauszek}"
github_repo="${GITHUB_REPO:-fsamp-infra}"
role_name="${ROLE_NAME:-fsamp-github-deploy}"
github_sub_pattern="${GITHUB_SUB_PATTERN:-repo:${github_owner}/${github_repo}:*}"
oidc_host="token.actions.githubusercontent.com"
oidc_url="https://${oidc_host}"

account_id="$(aws sts get-caller-identity --query Account --output text)"
partition="$(aws sts get-caller-identity --query Arn --output text | cut -d: -f2)"

extract_thumbprint() {
  local cert_index="$1"
  echo | openssl s_client -servername "${oidc_host}" -showcerts -connect "${oidc_host}:443" 2>/dev/null \
    | awk -v wanted="${cert_index}" '
        /BEGIN CERTIFICATE/ { cert++ }
        cert == wanted { print }
        /END CERTIFICATE/ && cert == wanted { exit }
      ' \
    | openssl x509 -fingerprint -sha1 -noout 2>/dev/null \
    | cut -d= -f2 \
    | tr -d ':' \
    | tr '[:upper:]' '[:lower:]'
}

thumbprint="$(extract_thumbprint 2)"
if [[ -z "${thumbprint}" ]]; then
  thumbprint="$(extract_thumbprint 1)"
fi
if [[ -z "${thumbprint}" ]]; then
  echo "Could not resolve GitHub OIDC thumbprint."
  exit 1
fi

oidc_arn="$(aws iam list-open-id-connect-providers \
  --query "OpenIDConnectProviderList[?contains(Arn, '${oidc_host}')].Arn | [0]" \
  --output text)"

if [[ -z "${oidc_arn}" || "${oidc_arn}" == "None" ]]; then
  oidc_arn="$(aws iam create-open-id-connect-provider \
    --url "${oidc_url}" \
    --client-id-list sts.amazonaws.com \
    --thumbprint-list "${thumbprint}" \
    --query OpenIDConnectProviderArn \
    --output text)"
else
  aws iam update-open-id-connect-provider-thumbprint \
    --open-id-connect-provider-arn "${oidc_arn}" \
    --thumbprint-list "${thumbprint}" >/dev/null
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

trust_policy="${tmp_dir}/trust-policy.json"
permissions_policy="${tmp_dir}/permissions-policy.json"

cat > "${trust_policy}" <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "${oidc_arn}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${oidc_host}:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "${oidc_host}:sub": "${github_sub_pattern}"
        }
      }
    }
  ]
}
JSON

cat > "${permissions_policy}" <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "FsampTerraformDeploy",
      "Effect": "Allow",
      "Action": [
        "apigateway:*",
        "application-autoscaling:*",
        "autoscaling:*",
        "cloudtrail:*",
        "cloudwatch:*",
        "cognito-idp:*",
        "config:*",
        "dynamodb:*",
        "ec2:*",
        "ecr:*",
        "ecs:*",
        "elasticloadbalancing:*",
        "events:*",
        "guardduty:*",
        "iam:*",
        "kms:*",
        "lambda:*",
        "logs:*",
        "s3:*",
        "securityhub:*",
        "secretsmanager:*",
        "sns:*",
        "sqs:*",
        "ssm:*",
        "sts:GetCallerIdentity",
        "tag:*",
        "wafv2:*",
        "xray:*"
      ],
      "Resource": "*"
    }
  ]
}
JSON

if aws iam get-role --role-name "${role_name}" >/dev/null 2>&1; then
  aws iam update-assume-role-policy \
    --role-name "${role_name}" \
    --policy-document "file://${trust_policy}" >/dev/null
else
  aws iam create-role \
    --role-name "${role_name}" \
    --assume-role-policy-document "file://${trust_policy}" >/dev/null
fi

aws iam put-role-policy \
  --role-name "${role_name}" \
  --policy-name fsamp-terraform-deploy \
  --policy-document "file://${permissions_policy}" >/dev/null

role_arn="arn:${partition}:iam::${account_id}:role/${role_name}"

echo "AWS_DEPLOY_ROLE_ARN=${role_arn}"
echo "OIDC_PROVIDER_ARN=${oidc_arn}"
echo "GITHUB_SUB_PATTERN=${github_sub_pattern}"
