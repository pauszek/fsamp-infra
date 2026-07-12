#!/usr/bin/env bash
# Create environment-scoped GitHub OIDC plan/apply roles for FSAMP.
# Run once per AWS account with IAM administrator credentials. The generated
# roles trust only the fsamp-infra GitHub Environment subject; configure each
# GitHub Environment to allow deployments from the protected main branch.
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  GITHUB_OWNER=pauszek ./scripts/bootstrap-github-oidc.sh

Required:
  GITHUB_OWNER          GitHub organization or user.

Optional:
  GITHUB_REPO           Infrastructure repository (default: fsamp-infra).
  ROLE_PREFIX           Role prefix (default: fsamp-github).
  ENVIRONMENTS          Comma-separated environments (default: dev,staging,prod).
  AWS_REGION            Deployment region (default: us-west-2).

The script prints AWS_PLAN_ROLE_ARN and AWS_APPLY_ROLE_ARN values for every
GitHub Environment. Store them as environment-scoped GitHub variables.
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

for command_name in aws jq openssl; do
  command -v "${command_name}" >/dev/null || {
    echo "${command_name} is required." >&2
    exit 1
  }
done

if [[ -z "${GITHUB_OWNER:-}" ]]; then
  echo "GITHUB_OWNER is required." >&2
  usage
  exit 2
fi

github_owner="${GITHUB_OWNER}"
github_repo="${GITHUB_REPO:-fsamp-infra}"
role_prefix="${ROLE_PREFIX:-fsamp-github}"
environments="${ENVIRONMENTS:-dev,staging,prod}"
aws_region="${AWS_REGION:-us-west-2}"
oidc_host="token.actions.githubusercontent.com"
oidc_url="https://${oidc_host}"

if [[ "${aws_region}" != "us-west-2" ]]; then
  echo "FSAMP deployment roles are restricted to us-west-2." >&2
  exit 2
fi

account_id="$(aws sts get-caller-identity --query Account --output text)"
partition="$(aws sts get-caller-identity --query Arn --output text | cut -d: -f2)"

extract_thumbprint() {
  local certificate_index="$1"
  echo | openssl s_client -servername "${oidc_host}" -showcerts -connect "${oidc_host}:443" 2>/dev/null \
    | awk -v wanted="${certificate_index}" '
        /BEGIN CERTIFICATE/ { certificate++ }
        certificate == wanted { print }
        /END CERTIFICATE/ && certificate == wanted { exit }
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
  echo "Could not resolve the GitHub OIDC thumbprint." >&2
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

temporary_directory="$(mktemp -d)"
cleanup() {
  rm -rf "${temporary_directory}"
}
trap cleanup EXIT

write_trust_policy() {
  local environment_name="$1"
  local destination="$2"
  local subject="repo:${github_owner}/${github_repo}:environment:${environment_name}"

  jq -n \
    --arg provider "${oidc_arn}" \
    --arg host "${oidc_host}" \
    --arg subject "${subject}" \
    '{
      Version: "2012-10-17",
      Statement: [{
        Sid: "GitHubEnvironmentOIDC",
        Effect: "Allow",
        Principal: {Federated: $provider},
        Action: "sts:AssumeRoleWithWebIdentity",
        Condition: {
          StringEquals: {
            ($host + ":aud"): "sts.amazonaws.com",
            ($host + ":sub"): $subject
          }
        }
      }]
    }' > "${destination}"
}

write_plan_policy() {
  local environment_name="$1"
  local destination="$2"
  local state_bucket="fsamp-${environment_name}-${account_id}-${aws_region}-tfstate"
  local lock_table="fsamp-${environment_name}-terraform-locks"

  jq -n \
    --arg account "${account_id}" \
    --arg environment "${environment_name}" \
    --arg partition "${partition}" \
    --arg region "${aws_region}" \
    --arg stateBucket "${state_bucket}" \
    --arg lockTable "${lock_table}" \
    '{
      Version: "2012-10-17",
      Statement: [
        {
          Sid: "TerraformReadOnly",
          Effect: "Allow",
          Action: [
            "acm:Describe*", "acm:List*", "apigateway:GET",
            "application-autoscaling:Describe*", "autoscaling:Describe*",
            "cloudtrail:Describe*", "cloudtrail:Get*", "cloudtrail:List*",
            "cloudwatch:Describe*", "cloudwatch:Get*", "cloudwatch:List*",
            "cognito-idp:Describe*", "cognito-idp:Get*", "cognito-idp:List*",
            "config:Describe*", "config:Get*", "config:List*",
            "dynamodb:Describe*", "dynamodb:List*",
            "ec2:Describe*", "ecr:Describe*", "ecr:Get*", "ecr:List*",
            "ecs:Describe*", "ecs:List*", "elasticloadbalancing:Describe*",
            "events:Describe*", "events:List*", "guardduty:Get*", "guardduty:List*",
            "iam:Get*", "iam:List*", "kms:Describe*", "kms:Get*", "kms:List*",
            "lambda:Get*", "lambda:List*", "logs:Describe*", "logs:Get*", "logs:List*",
            "route53:Get*", "route53:List*", "s3:GetBucket*", "s3:ListAllMyBuckets",
            "securityhub:Describe*", "securityhub:Get*", "securityhub:List*",
            "sns:Get*", "sns:List*", "sqs:Get*", "sqs:List*",
            "ssm:Describe*", "ssm:Get*", "ssm:List*", "sts:GetCallerIdentity",
            "tag:Get*", "wafv2:Get*", "wafv2:List*", "xray:Get*"
          ],
          Resource: "*"
        },
        {
          Sid: "TerraformStateRead",
          Effect: "Allow",
          Action: ["s3:GetObject", "s3:GetObjectVersion", "s3:ListBucket"],
          Resource: [
            ("arn:" + $partition + ":s3:::" + $stateBucket),
            ("arn:" + $partition + ":s3:::" + $stateBucket + "/*")
          ]
        },
        {
          Sid: "TerraformStateLock",
          Effect: "Allow",
          Action: ["dynamodb:DescribeTable", "dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem", "dynamodb:UpdateItem"],
          Resource: ("arn:" + $partition + ":dynamodb:" + $region + ":" + $account + ":table/" + $lockTable)
        }
      ]
    }' > "${destination}"
}

write_apply_policy() {
  local environment_name="$1"
  local destination="$2"
  local name_prefix="fsamp-${environment_name}"
  local state_bucket="fsamp-${environment_name}-${account_id}-${aws_region}-tfstate"
  local lock_table="fsamp-${environment_name}-terraform-locks"

  jq -n \
    --arg account "${account_id}" \
    --arg environment "${environment_name}" \
    --arg namePrefix "${name_prefix}" \
    --arg partition "${partition}" \
    --arg region "${aws_region}" \
    --arg stateBucket "${state_bucket}" \
    --arg lockTable "${lock_table}" \
    '{
      Version: "2012-10-17",
      Statement: [
        {
          Sid: "TerraformReadOnly",
          Effect: "Allow",
          Action: [
            "acm:Describe*", "acm:List*", "apigateway:GET",
            "application-autoscaling:Describe*", "autoscaling:Describe*",
            "cloudtrail:Describe*", "cloudtrail:Get*", "cloudtrail:List*",
            "cloudwatch:Describe*", "cloudwatch:Get*", "cloudwatch:List*",
            "cognito-idp:Describe*", "cognito-idp:Get*", "cognito-idp:List*",
            "config:Describe*", "config:Get*", "config:List*", "dynamodb:Describe*", "dynamodb:List*",
            "ec2:Describe*", "ecr:Describe*", "ecr:Get*", "ecr:List*", "ecs:Describe*", "ecs:List*",
            "elasticloadbalancing:Describe*", "events:Describe*", "events:List*",
            "guardduty:Get*", "guardduty:List*", "iam:Get*", "iam:List*",
            "kms:Describe*", "kms:Get*", "kms:List*", "lambda:Get*", "lambda:List*",
            "logs:Describe*", "logs:Get*", "logs:List*", "route53:Get*", "route53:List*",
            "s3:GetBucket*", "s3:GetObject*", "s3:List*",
            "securityhub:Describe*", "securityhub:Get*", "securityhub:List*",
            "sns:Get*", "sns:List*", "sqs:Get*", "sqs:List*", "ssm:Describe*", "ssm:Get*", "ssm:List*",
            "sts:GetCallerIdentity", "tag:Get*", "wafv2:Get*", "wafv2:List*", "xray:Get*"
          ],
          Resource: "*"
        },
        {
          Sid: "TerraformState",
          Effect: "Allow",
          Action: ["s3:CreateBucket", "s3:GetObject", "s3:GetObjectVersion", "s3:PutObject", "s3:ListBucket", "s3:PutBucket*", "s3:PutEncryptionConfiguration", "s3:PutLifecycleConfiguration"],
          Resource: [
            ("arn:" + $partition + ":s3:::" + $stateBucket),
            ("arn:" + $partition + ":s3:::" + $stateBucket + "/*")
          ]
        },
        {
          Sid: "TerraformStateLock",
          Effect: "Allow",
          Action: ["dynamodb:CreateTable", "dynamodb:DescribeTable", "dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem", "dynamodb:UpdateItem", "dynamodb:UpdateTable", "dynamodb:UpdateContinuousBackups", "dynamodb:TagResource"],
          Resource: ("arn:" + $partition + ":dynamodb:" + $region + ":" + $account + ":table/" + $lockTable)
        },
        {
          Sid: "ProjectS3",
          Effect: "Allow",
          Action: ["s3:CreateBucket", "s3:DeleteBucket", "s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:DeleteObjectVersion", "s3:PutBucket*", "s3:DeleteBucket*", "s3:GetReplicationConfiguration", "s3:PutReplicationConfiguration", "s3:DeleteReplicationConfiguration", "s3:ListBucket"],
          Resource: [
            ("arn:" + $partition + ":s3:::" + $namePrefix + "-*"),
            ("arn:" + $partition + ":s3:::" + $namePrefix + "-*/*")
          ]
        },
        {
          Sid: "ProjectNamedResources",
          Effect: "Allow",
          Action: [
            "cloudtrail:CreateTrail", "cloudtrail:DeleteTrail", "cloudtrail:UpdateTrail", "cloudtrail:StartLogging", "cloudtrail:StopLogging", "cloudtrail:PutEventSelectors", "cloudtrail:AddTags", "cloudtrail:RemoveTags",
            "cloudwatch:PutMetricAlarm", "cloudwatch:DeleteAlarms", "cloudwatch:PutCompositeAlarm", "cloudwatch:PutDashboard", "cloudwatch:DeleteDashboards", "cloudwatch:TagResource", "cloudwatch:UntagResource",
            "dynamodb:CreateTable", "dynamodb:DeleteTable", "dynamodb:UpdateTable", "dynamodb:UpdateTimeToLive", "dynamodb:UpdateContinuousBackups", "dynamodb:TagResource", "dynamodb:UntagResource",
            "ecr:CreateRepository", "ecr:DeleteRepository", "ecr:PutLifecyclePolicy", "ecr:DeleteLifecyclePolicy", "ecr:PutImageScanningConfiguration", "ecr:PutImageTagMutability", "ecr:SetRepositoryPolicy", "ecr:DeleteRepositoryPolicy", "ecr:TagResource", "ecr:UntagResource", "ecr:PutImage", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart", "ecr:CompleteLayerUpload", "ecr:BatchCheckLayerAvailability", "ecr:BatchGetImage",
            "ecs:CreateCluster", "ecs:DeleteCluster", "ecs:CreateService", "ecs:DeleteService", "ecs:UpdateService", "ecs:UpdateCluster", "ecs:UpdateClusterSettings", "ecs:PutClusterCapacityProviders", "ecs:RegisterTaskDefinition", "ecs:DeregisterTaskDefinition", "ecs:TagResource", "ecs:UntagResource",
            "events:PutRule", "events:DeleteRule", "events:PutTargets", "events:RemoveTargets", "events:TagResource", "events:UntagResource",
            "lambda:CreateFunction", "lambda:DeleteFunction", "lambda:UpdateFunction*", "lambda:AddPermission", "lambda:RemovePermission", "lambda:PutFunctionConcurrency", "lambda:DeleteFunctionConcurrency", "lambda:TagResource", "lambda:UntagResource",
            "logs:CreateLogGroup", "logs:DeleteLogGroup", "logs:PutRetentionPolicy", "logs:DeleteRetentionPolicy", "logs:AssociateKmsKey", "logs:DisassociateKmsKey", "logs:TagResource", "logs:UntagResource",
            "sns:CreateTopic", "sns:DeleteTopic", "sns:Subscribe", "sns:Unsubscribe", "sns:SetTopicAttributes", "sns:SetSubscriptionAttributes", "sns:TagResource", "sns:UntagResource",
            "sqs:CreateQueue", "sqs:DeleteQueue", "sqs:SetQueueAttributes", "sqs:TagQueue", "sqs:UntagQueue",
            "ssm:PutParameter", "ssm:DeleteParameter", "ssm:AddTagsToResource", "ssm:RemoveTagsFromResource"
          ],
          Resource: [
            ("arn:" + $partition + ":cloudtrail:" + $region + ":" + $account + ":trail/" + $namePrefix + "-*"),
            ("arn:" + $partition + ":cloudwatch:" + $region + ":" + $account + ":alarm:" + $namePrefix + "-*"),
            ("arn:" + $partition + ":cloudwatch::" + $account + ":dashboard/" + $namePrefix + "-*"),
            ("arn:" + $partition + ":dynamodb:" + $region + ":" + $account + ":table/" + $namePrefix + "-*"),
            ("arn:" + $partition + ":ecr:" + $region + ":" + $account + ":repository/" + $namePrefix + "-*"),
            ("arn:" + $partition + ":ecs:" + $region + ":" + $account + ":cluster/" + $namePrefix + "-*"),
            ("arn:" + $partition + ":ecs:" + $region + ":" + $account + ":service/" + $namePrefix + "-*/*"),
            ("arn:" + $partition + ":ecs:" + $region + ":" + $account + ":task-definition/" + $namePrefix + "-*:*"),
            ("arn:" + $partition + ":events:" + $region + ":" + $account + ":rule/" + $namePrefix + "-*"),
            ("arn:" + $partition + ":lambda:" + $region + ":" + $account + ":function:" + $namePrefix + "-*"),
            ("arn:" + $partition + ":logs:" + $region + ":" + $account + ":log-group:*" + $namePrefix + "*"),
            ("arn:" + $partition + ":sns:" + $region + ":" + $account + ":" + $namePrefix + "-*"),
            ("arn:" + $partition + ":sqs:" + $region + ":" + $account + ":" + $namePrefix + "-*"),
            ("arn:" + $partition + ":ssm:" + $region + ":" + $account + ":parameter/fsamp/" + $environment + "/*")
          ]
        },
        {
          Sid: "ProjectIam",
          Effect: "Allow",
          Action: ["iam:CreateRole", "iam:DeleteRole", "iam:UpdateRole", "iam:UpdateAssumeRolePolicy", "iam:PutRolePolicy", "iam:DeleteRolePolicy", "iam:AttachRolePolicy", "iam:DetachRolePolicy", "iam:PassRole", "iam:TagRole", "iam:UntagRole"],
          Resource: ("arn:" + $partition + ":iam::" + $account + ":role/" + $namePrefix + "-*")
        },
        {
          Sid: "CreateRequiredServiceLinkedRoles",
          Effect: "Allow",
          Action: "iam:CreateServiceLinkedRole",
          Resource: "*",
          Condition: {
            StringEquals: {
              "iam:AWSServiceName": [
                "config.amazonaws.com",
                "ecs.amazonaws.com",
                "ecs.application-autoscaling.amazonaws.com",
                "elasticloadbalancing.amazonaws.com",
                "guardduty.amazonaws.com",
                "securityhub.amazonaws.com"
              ]
            }
          }
        },
        {
          Sid: "CreateTaggedKmsKeys",
          Effect: "Allow",
          Action: ["kms:CreateKey"],
          Resource: "*",
          Condition: {StringEquals: {"aws:RequestTag/Project": "fsamp", "aws:RequestTag/Environment": $environment}}
        },
        {
          Sid: "ManageProjectKmsKeys",
          Effect: "Allow",
          Action: ["kms:CreateAlias", "kms:UpdateAlias", "kms:ScheduleKeyDeletion", "kms:CancelKeyDeletion", "kms:DisableKey", "kms:EnableKey", "kms:EnableKeyRotation", "kms:DisableKeyRotation", "kms:PutKeyPolicy", "kms:UpdateKeyDescription", "kms:TagResource", "kms:UntagResource"],
          Resource: ("arn:" + $partition + ":kms:*:" + $account + ":key/*"),
          Condition: {StringEquals: {"aws:ResourceTag/Project": "fsamp", "aws:ResourceTag/Environment": $environment}}
        },
        {
          Sid: "ManageProjectKmsAliases",
          Effect: "Allow",
          Action: ["kms:CreateAlias", "kms:UpdateAlias", "kms:DeleteAlias"],
          Resource: ("arn:" + $partition + ":kms:*:" + $account + ":alias/" + $namePrefix + "-*")
        },
        {
          Sid: "EnvironmentInfrastructureMutation",
          Effect: "Allow",
          Action: [
            "acm:RequestCertificate", "acm:ImportCertificate", "acm:DeleteCertificate", "acm:AddTagsToCertificate", "acm:RemoveTagsFromCertificate",
            "apigateway:POST", "apigateway:PUT", "apigateway:PATCH", "apigateway:DELETE",
            "application-autoscaling:RegisterScalableTarget", "application-autoscaling:DeregisterScalableTarget", "application-autoscaling:PutScalingPolicy", "application-autoscaling:DeleteScalingPolicy",
            "cognito-idp:CreateUserPool*", "cognito-idp:DeleteUserPool*", "cognito-idp:UpdateUserPool*", "cognito-idp:CreateGroup", "cognito-idp:DeleteGroup", "cognito-idp:CreateResourceServer", "cognito-idp:DeleteResourceServer", "cognito-idp:TagResource", "cognito-idp:UntagResource",
            "config:Put*", "config:Delete*", "config:Start*", "config:Stop*",
            "ec2:CreateVpc", "ec2:DeleteVpc", "ec2:ModifyVpc*", "ec2:CreateSubnet", "ec2:DeleteSubnet", "ec2:ModifySubnet*", "ec2:CreateRoute*", "ec2:DeleteRoute*", "ec2:ReplaceRoute*", "ec2:AssociateRouteTable", "ec2:DisassociateRouteTable", "ec2:CreateSecurityGroup", "ec2:DeleteSecurityGroup", "ec2:ModifySecurityGroupRules", "ec2:AuthorizeSecurityGroup*", "ec2:RevokeSecurityGroup*", "ec2:CreateInternetGateway", "ec2:DeleteInternetGateway", "ec2:AttachInternetGateway", "ec2:DetachInternetGateway", "ec2:CreateNatGateway", "ec2:DeleteNatGateway", "ec2:AllocateAddress", "ec2:ReleaseAddress", "ec2:CreateVpcEndpoint", "ec2:DeleteVpcEndpoints", "ec2:ModifyVpcEndpoint", "ec2:CreateNetworkAcl*", "ec2:DeleteNetworkAcl*", "ec2:ReplaceNetworkAcl*", "ec2:CreateTags", "ec2:DeleteTags", "ec2:CreateFlowLogs", "ec2:DeleteFlowLogs",
            "elasticloadbalancing:Create*", "elasticloadbalancing:Delete*", "elasticloadbalancing:Modify*", "elasticloadbalancing:Register*", "elasticloadbalancing:Deregister*", "elasticloadbalancing:Set*", "elasticloadbalancing:AddTags", "elasticloadbalancing:RemoveTags",
            "guardduty:Create*", "guardduty:Update*", "guardduty:Delete*", "guardduty:TagResource", "guardduty:UntagResource",
            "route53:CreateHostedZone", "route53:DeleteHostedZone", "route53:ChangeResourceRecordSets", "route53:ChangeTagsForResource",
            "lambda:CreateEventSourceMapping", "lambda:UpdateEventSourceMapping", "lambda:DeleteEventSourceMapping",
            "securityhub:Enable*", "securityhub:Disable*", "securityhub:Update*", "securityhub:BatchEnableStandards", "securityhub:BatchDisableStandards",
            "wafv2:Create*", "wafv2:Update*", "wafv2:Delete*", "wafv2:AssociateWebACL", "wafv2:DisassociateWebACL", "wafv2:PutLoggingConfiguration", "wafv2:DeleteLoggingConfiguration", "wafv2:TagResource", "wafv2:UntagResource",
            "xray:PutEncryptionConfig", "xray:CreateGroup", "xray:DeleteGroup", "xray:TagResource", "xray:UntagResource"
          ],
          Resource: "*",
          Condition: {
            StringEqualsIfExists: {
              "aws:ResourceTag/Project": "fsamp",
              "aws:ResourceTag/Environment": $environment,
              "aws:RequestTag/Project": "fsamp",
              "aws:RequestTag/Environment": $environment
            }
          }
        },
        {
          Sid: "AccountLevelConfiguration",
          Effect: "Allow",
          Action: ["ecr:PutRegistryScanningConfiguration"],
          Resource: "*"
        },
        {
          Sid: "DenyIdentityAndOrganizationAdministration",
          Effect: "Deny",
          Action: ["iam:CreateUser", "iam:DeleteUser", "iam:CreateAccessKey", "iam:DeleteAccessKey", "iam:CreateLoginProfile", "organizations:*", "account:*"],
          Resource: "*"
        }
      ]
    }' > "${destination}"
}

ensure_role() {
  local role_name="$1"
  local trust_policy="$2"
  local permissions_policy="$3"
  local policy_name="$4"

  if aws iam get-role --role-name "${role_name}" >/dev/null 2>&1; then
    aws iam update-assume-role-policy \
      --role-name "${role_name}" \
      --policy-document "file://${trust_policy}" >/dev/null
  else
    aws iam create-role \
      --role-name "${role_name}" \
      --assume-role-policy-document "file://${trust_policy}" \
      --description "Environment-scoped FSAMP GitHub OIDC role" \
      --max-session-duration 3600 \
      --tags Key=Project,Value=fsamp >/dev/null
  fi

  aws iam put-role-policy \
    --role-name "${role_name}" \
    --policy-name "${policy_name}" \
    --policy-document "file://${permissions_policy}" >/dev/null
}

IFS=',' read -ra environment_names <<< "${environments}"
for raw_environment in "${environment_names[@]}"; do
  environment_name="$(echo "${raw_environment}" | xargs)"
  if [[ ! "${environment_name}" =~ ^(dev|staging|prod)$ ]]; then
    echo "Unsupported environment: ${environment_name}" >&2
    exit 2
  fi

  trust_policy="${temporary_directory}/trust-${environment_name}.json"
  plan_policy="${temporary_directory}/plan-${environment_name}.json"
  apply_policy="${temporary_directory}/apply-${environment_name}.json"
  plan_role="${role_prefix}-plan-${environment_name}"
  apply_role="${role_prefix}-apply-${environment_name}"

  write_trust_policy "${environment_name}" "${trust_policy}"
  write_plan_policy "${environment_name}" "${plan_policy}"
  write_apply_policy "${environment_name}" "${apply_policy}"

  ensure_role "${plan_role}" "${trust_policy}" "${plan_policy}" "fsamp-terraform-plan-${environment_name}"
  ensure_role "${apply_role}" "${trust_policy}" "${apply_policy}" "fsamp-terraform-apply-${environment_name}"

  echo "${environment_name}:"
  echo "  AWS_PLAN_ROLE_ARN=arn:${partition}:iam::${account_id}:role/${plan_role}"
  echo "  AWS_APPLY_ROLE_ARN=arn:${partition}:iam::${account_id}:role/${apply_role}"
done

echo "OIDC_PROVIDER_ARN=${oidc_arn}"
