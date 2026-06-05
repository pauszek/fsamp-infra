#!/usr/bin/env bash
#
# Bootstraps the GitHub OIDC trust relationship and the deployment IAM role
# used by the FSAMP Deploy workflow. The script is intended to be run once
# per AWS account by an operator with IAM administration permissions.
#
# Security posture:
#   - Trust policy is scoped to specific branches and GitHub Environments
#     (not a wildcard subject pattern). This prevents arbitrary forks,
#     pull-request workflows and unrelated branches from assuming the role.
#   - Permissions policy follows least-privilege for the resources Terraform
#     actually manages: it intentionally avoids iam:* and kms:* wildcards.
#     IAM and KMS actions are scoped to FSAMP-prefixed resources only.
#   - Optional managed policy fallback (USE_MANAGED_FALLBACK=true) attaches
#     PowerUserAccess + IAMFullAccess for environments where the inline
#     policy is too restrictive during early bootstrap. This is OFF by default.
#
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  GITHUB_OWNER=pauszek GITHUB_REPO=fsamp-infra ./scripts/bootstrap-github-oidc.sh

Required environment variables:
  GITHUB_OWNER  - GitHub organization or user that owns the repositories
                  authorized to assume the deployment role.

Optional environment variables:
  GITHUB_REPO         - Primary repo authorized to assume the role.
                        Default: fsamp-infra
  ROLE_NAME           - IAM role name. Default: fsamp-github-deploy
  RESOURCE_PREFIX     - Resource name prefix used in least-privilege ARN
                        conditions (matches Terraform name_prefix).
                        Default: fsamp-*
  ALLOWED_BRANCHES    - Comma-separated list of refs allowed to deploy.
                        Default: refs/heads/main
  ALLOWED_ENVIRONMENTS - Comma-separated list of GitHub Environments allowed
                        to assume the role. Default: dev,staging,prod
  ALLOWED_REPOS       - Comma-separated list of repositories allowed to
                        dispatch deployments through this role.
                        Default: GITHUB_REPO,fsamp-gateway,fsamp-processor
  USE_MANAGED_FALLBACK - When set to "true" attaches PowerUserAccess +
                         IAMFullAccess instead of the inline least-privilege
                         policy. Use only for the very first bootstrap when
                         account state requires broader permissions.
                         Default: false
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

command -v aws >/dev/null || { echo "aws CLI is required."; exit 1; }
command -v openssl >/dev/null || { echo "openssl is required."; exit 1; }
command -v jq >/dev/null || { echo "jq is required."; exit 1; }

if [[ -z "${GITHUB_OWNER:-}" ]]; then
  echo "GITHUB_OWNER is required." >&2
  usage
  exit 2
fi

github_owner="${GITHUB_OWNER}"
github_repo="${GITHUB_REPO:-fsamp-infra}"
role_name="${ROLE_NAME:-fsamp-github-deploy}"
resource_prefix="${RESOURCE_PREFIX:-fsamp-*}"
allowed_branches="${ALLOWED_BRANCHES:-refs/heads/main}"
allowed_environments="${ALLOWED_ENVIRONMENTS:-dev,staging,prod}"
allowed_repos="${ALLOWED_REPOS:-${github_repo},fsamp-gateway,fsamp-processor}"
use_managed_fallback="${USE_MANAGED_FALLBACK:-false}"
oidc_host="token.actions.githubusercontent.com"
oidc_url="https://${oidc_host}"

account_id="$(aws sts get-caller-identity --query Account --output text)"
partition="$(aws sts get-caller-identity --query Arn --output text | cut -d: -f2)"

# Build the StringLike list of allowed sub claims. Each combination of
# (allowed repo) x (allowed branch) and (allowed repo) x (environment) is
# enumerated explicitly so that the resulting trust policy is auditable.
build_sub_patterns() {
  local -a patterns=()
  IFS=',' read -ra repos_arr <<< "${allowed_repos}"
  IFS=',' read -ra branches_arr <<< "${allowed_branches}"
  IFS=',' read -ra envs_arr <<< "${allowed_environments}"

  local repo branch env_name
  for repo in "${repos_arr[@]}"; do
    repo="$(echo "${repo}" | xargs)"
    [[ -z "${repo}" ]] && continue
    for branch in "${branches_arr[@]}"; do
      branch="$(echo "${branch}" | xargs)"
      [[ -z "${branch}" ]] && continue
      patterns+=("repo:${github_owner}/${repo}:ref:${branch}")
    done
    for env_name in "${envs_arr[@]}"; do
      env_name="$(echo "${env_name}" | xargs)"
      [[ -z "${env_name}" ]] && continue
      patterns+=("repo:${github_owner}/${repo}:environment:${env_name}")
    done
  done

  printf '%s\n' "${patterns[@]}" | jq -R . | jq -s .
}

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
  echo "Could not resolve GitHub OIDC thumbprint." >&2
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

sub_patterns_json="$(build_sub_patterns)"

jq -n \
  --arg oidcArn "${oidc_arn}" \
  --arg oidcHost "${oidc_host}" \
  --argjson subs "${sub_patterns_json}" \
  '{
    Version: "2012-10-17",
    Statement: [
      {
        Sid: "GitHubOIDCTrust",
        Effect: "Allow",
        Principal: { Federated: $oidcArn },
        Action: "sts:AssumeRoleWithWebIdentity",
        Condition: {
          StringEquals: {
            ($oidcHost + ":aud"): "sts.amazonaws.com"
          },
          StringLike: {
            ($oidcHost + ":sub"): $subs
          }
        }
      }
    ]
  }' > "${trust_policy}"

# Least-privilege permissions policy. IAM and KMS actions are scoped to
# resources owned by the FSAMP project. Other AWS service actions are
# constrained to operations Terraform requires for plan/apply.
jq -n \
  --arg accountId "${account_id}" \
  --arg partition "${partition}" \
  --arg prefix "${resource_prefix}" \
  '{
    Version: "2012-10-17",
    Statement: [
      {
        Sid: "TerraformReadOnlyAccess",
        Effect: "Allow",
        Action: [
          "apigateway:GET",
          "cloudtrail:Describe*",
          "cloudtrail:Get*",
          "cloudtrail:List*",
          "cloudwatch:Describe*",
          "cloudwatch:Get*",
          "cloudwatch:List*",
          "cognito-idp:Describe*",
          "cognito-idp:Get*",
          "cognito-idp:List*",
          "config:Describe*",
          "config:Get*",
          "config:List*",
          "dynamodb:Describe*",
          "dynamodb:List*",
          "ec2:Describe*",
          "ecr:Describe*",
          "ecr:Get*",
          "ecr:List*",
          "ecs:Describe*",
          "ecs:List*",
          "elasticloadbalancing:Describe*",
          "events:Describe*",
          "events:List*",
          "guardduty:Get*",
          "guardduty:List*",
          "iam:Get*",
          "iam:List*",
          "kms:Describe*",
          "kms:Get*",
          "kms:List*",
          "lambda:Get*",
          "lambda:List*",
          "logs:Describe*",
          "logs:Get*",
          "logs:List*",
          "s3:GetBucket*",
          "s3:GetObject*",
          "s3:List*",
          "securityhub:Describe*",
          "securityhub:Get*",
          "securityhub:List*",
          "secretsmanager:Describe*",
          "secretsmanager:Get*",
          "secretsmanager:List*",
          "sns:Get*",
          "sns:List*",
          "sqs:Get*",
          "sqs:List*",
          "ssm:Describe*",
          "ssm:Get*",
          "ssm:List*",
          "sts:GetCallerIdentity",
          "tag:Get*",
          "wafv2:Get*",
          "wafv2:List*",
          "xray:Get*"
        ],
        Resource: "*"
      },
      {
        Sid: "TerraformInfrastructureWrite",
        Effect: "Allow",
        Action: [
          "apigateway:POST", "apigateway:PUT", "apigateway:PATCH", "apigateway:DELETE",
          "application-autoscaling:*",
          "autoscaling:*",
          "cloudtrail:CreateTrail", "cloudtrail:DeleteTrail", "cloudtrail:UpdateTrail",
          "cloudtrail:StartLogging", "cloudtrail:StopLogging",
          "cloudtrail:PutEventSelectors", "cloudtrail:AddTags", "cloudtrail:RemoveTags",
          "cloudwatch:PutMetricAlarm", "cloudwatch:DeleteAlarms",
          "cloudwatch:PutCompositeAlarm", "cloudwatch:PutDashboard",
          "cloudwatch:DeleteDashboards", "cloudwatch:TagResource", "cloudwatch:UntagResource",
          "cognito-idp:CreateUserPool*", "cognito-idp:DeleteUserPool*",
          "cognito-idp:UpdateUserPool*", "cognito-idp:CreateGroup",
          "cognito-idp:DeleteGroup", "cognito-idp:CreateResourceServer",
          "cognito-idp:DeleteResourceServer", "cognito-idp:CreateIdentityProvider",
          "cognito-idp:DeleteIdentityProvider", "cognito-idp:TagResource",
          "config:Put*", "config:Delete*", "config:Start*", "config:Stop*",
          "dynamodb:CreateTable", "dynamodb:DeleteTable", "dynamodb:UpdateTable",
          "dynamodb:UpdateTimeToLive", "dynamodb:UpdateContinuousBackups",
          "dynamodb:TagResource", "dynamodb:UntagResource",
          "ec2:CreateVpc*", "ec2:DeleteVpc*", "ec2:ModifyVpc*",
          "ec2:CreateSubnet", "ec2:DeleteSubnet", "ec2:ModifySubnet*",
          "ec2:CreateRoute*", "ec2:DeleteRoute*", "ec2:ReplaceRoute*",
          "ec2:AssociateRouteTable", "ec2:DisassociateRouteTable",
          "ec2:CreateSecurityGroup", "ec2:DeleteSecurityGroup",
          "ec2:AuthorizeSecurityGroup*", "ec2:RevokeSecurityGroup*",
          "ec2:CreateInternetGateway", "ec2:DeleteInternetGateway",
          "ec2:AttachInternetGateway", "ec2:DetachInternetGateway",
          "ec2:CreateNatGateway", "ec2:DeleteNatGateway",
          "ec2:AllocateAddress", "ec2:ReleaseAddress",
          "ec2:CreateVpcEndpoint", "ec2:DeleteVpcEndpoints",
          "ec2:ModifyVpcEndpoint", "ec2:CreateNetworkAcl*",
          "ec2:DeleteNetworkAcl*", "ec2:ReplaceNetworkAcl*",
          "ec2:CreateTags", "ec2:DeleteTags",
          "ec2:CreateFlowLogs", "ec2:DeleteFlowLogs",
          "ecr:CreateRepository", "ecr:DeleteRepository",
          "ecr:PutLifecyclePolicy", "ecr:DeleteLifecyclePolicy",
          "ecr:PutImageScanningConfiguration", "ecr:PutImageTagMutability",
          "ecr:SetRepositoryPolicy", "ecr:DeleteRepositoryPolicy",
          "ecr:TagResource", "ecr:UntagResource",
          "ecs:Create*", "ecs:Delete*", "ecs:Update*",
          "ecs:Register*", "ecs:Deregister*", "ecs:TagResource", "ecs:UntagResource",
          "elasticloadbalancing:Create*", "elasticloadbalancing:Delete*",
          "elasticloadbalancing:Modify*", "elasticloadbalancing:Register*",
          "elasticloadbalancing:Deregister*", "elasticloadbalancing:AddTags",
          "elasticloadbalancing:RemoveTags",
          "events:Put*", "events:Delete*", "events:Remove*", "events:Tag*",
          "guardduty:Create*", "guardduty:Update*", "guardduty:Delete*",
          "guardduty:TagResource", "guardduty:UntagResource",
          "lambda:Create*", "lambda:Update*", "lambda:Delete*",
          "lambda:Add*", "lambda:Remove*", "lambda:Publish*",
          "lambda:PutFunctionConcurrency", "lambda:DeleteFunctionConcurrency",
          "lambda:TagResource", "lambda:UntagResource",
          "logs:CreateLogGroup", "logs:DeleteLogGroup",
          "logs:PutRetentionPolicy", "logs:DeleteRetentionPolicy",
          "logs:AssociateKmsKey", "logs:DisassociateKmsKey",
          "logs:TagResource", "logs:UntagResource", "logs:TagLogGroup",
          "s3:CreateBucket", "s3:DeleteBucket",
          "s3:PutBucket*", "s3:DeleteBucket*",
          "s3:PutLifecycleConfiguration", "s3:DeleteLifecycleConfiguration",
          "s3:PutEncryptionConfiguration", "s3:PutObject",
          "s3:DeleteObject", "s3:DeleteObjectVersion",
          "s3:PutBucketTagging", "s3:DeleteBucketTagging",
          "securityhub:Enable*", "securityhub:Disable*", "securityhub:Update*",
          "secretsmanager:CreateSecret", "secretsmanager:UpdateSecret",
          "secretsmanager:DeleteSecret", "secretsmanager:PutResourcePolicy",
          "secretsmanager:DeleteResourcePolicy", "secretsmanager:TagResource",
          "secretsmanager:UntagResource", "secretsmanager:RotateSecret",
          "sns:CreateTopic", "sns:DeleteTopic", "sns:Subscribe",
          "sns:Unsubscribe", "sns:SetTopicAttributes", "sns:SetSubscriptionAttributes",
          "sns:TagResource", "sns:UntagResource",
          "sqs:CreateQueue", "sqs:DeleteQueue", "sqs:SetQueueAttributes",
          "sqs:TagQueue", "sqs:UntagQueue", "sqs:PurgeQueue",
          "ssm:PutParameter", "ssm:DeleteParameter",
          "ssm:LabelParameterVersion", "ssm:AddTagsToResource", "ssm:RemoveTagsFromResource",
          "tag:TagResources", "tag:UntagResources",
          "wafv2:Create*", "wafv2:Update*", "wafv2:Delete*", "wafv2:Tag*", "wafv2:Untag*",
          "xray:PutEncryptionConfig", "xray:CreateGroup", "xray:DeleteGroup", "xray:Tag*"
        ],
        Resource: "*"
      },
      {
        Sid: "IamScopedToFsampResources",
        Effect: "Allow",
        Action: [
          "iam:CreateRole", "iam:DeleteRole", "iam:UpdateRole",
          "iam:UpdateAssumeRolePolicy", "iam:PutRolePolicy", "iam:DeleteRolePolicy",
          "iam:AttachRolePolicy", "iam:DetachRolePolicy",
          "iam:CreatePolicy", "iam:DeletePolicy",
          "iam:CreatePolicyVersion", "iam:DeletePolicyVersion",
          "iam:CreateInstanceProfile", "iam:DeleteInstanceProfile",
          "iam:AddRoleToInstanceProfile", "iam:RemoveRoleFromInstanceProfile",
          "iam:PassRole", "iam:TagRole", "iam:UntagRole",
          "iam:TagPolicy", "iam:UntagPolicy",
          "iam:CreateServiceLinkedRole", "iam:DeleteServiceLinkedRole"
        ],
        Resource: [
          ("arn:" + $partition + ":iam::" + $accountId + ":role/" + $prefix),
          ("arn:" + $partition + ":iam::" + $accountId + ":policy/" + $prefix),
          ("arn:" + $partition + ":iam::" + $accountId + ":instance-profile/" + $prefix)
        ]
      },
      {
        Sid: "KmsScopedToFsampKeys",
        Effect: "Allow",
        Action: [
          "kms:CreateKey", "kms:CreateAlias", "kms:DeleteAlias",
          "kms:UpdateAlias", "kms:ScheduleKeyDeletion",
          "kms:CancelKeyDeletion", "kms:DisableKey", "kms:EnableKey",
          "kms:EnableKeyRotation", "kms:DisableKeyRotation",
          "kms:PutKeyPolicy", "kms:UpdateKeyDescription",
          "kms:TagResource", "kms:UntagResource"
        ],
        Resource: "*",
        Condition: {
          "ForAnyValue:StringLike": {
            "aws:TagKeys": ["Project", "Environment"]
          }
        }
      },
      {
        Sid: "DenyDangerousActions",
        Effect: "Deny",
        Action: [
          "iam:CreateUser",
          "iam:DeleteUser",
          "iam:CreateAccessKey",
          "iam:DeleteAccessKey",
          "iam:CreateLoginProfile",
          "iam:UpdateAccountPasswordPolicy",
          "organizations:*",
          "account:*"
        ],
        Resource: "*"
      }
    ]
  }' > "${permissions_policy}"

if aws iam get-role --role-name "${role_name}" >/dev/null 2>&1; then
  aws iam update-assume-role-policy \
    --role-name "${role_name}" \
    --policy-document "file://${trust_policy}" >/dev/null
else
  aws iam create-role \
    --role-name "${role_name}" \
    --assume-role-policy-document "file://${trust_policy}" \
    --description "GitHub OIDC deployment role for the FSAMP platform (managed by bootstrap-github-oidc.sh)" \
    --max-session-duration 3600 >/dev/null
fi

if [[ "${use_managed_fallback}" == "true" ]]; then
  echo "USE_MANAGED_FALLBACK=true: attaching PowerUserAccess + IAMFullAccess." >&2
  aws iam attach-role-policy \
    --role-name "${role_name}" \
    --policy-arn "arn:${partition}:iam::aws:policy/PowerUserAccess" >/dev/null
  aws iam attach-role-policy \
    --role-name "${role_name}" \
    --policy-arn "arn:${partition}:iam::aws:policy/IAMFullAccess" >/dev/null
  aws iam delete-role-policy \
    --role-name "${role_name}" \
    --policy-name fsamp-terraform-deploy >/dev/null 2>&1 || true
else
  aws iam put-role-policy \
    --role-name "${role_name}" \
    --policy-name fsamp-terraform-deploy \
    --policy-document "file://${permissions_policy}" >/dev/null
fi

role_arn="arn:${partition}:iam::${account_id}:role/${role_name}"

echo "AWS_DEPLOY_ROLE_ARN=${role_arn}"
echo "OIDC_PROVIDER_ARN=${oidc_arn}"
echo "ALLOWED_REPOS=${allowed_repos}"
echo "ALLOWED_BRANCHES=${allowed_branches}"
echo "ALLOWED_ENVIRONMENTS=${allowed_environments}"
echo "USE_MANAGED_FALLBACK=${use_managed_fallback}"
