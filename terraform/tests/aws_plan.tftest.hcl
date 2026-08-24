mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
      arn        = "arn:aws:iam::123456789012:user/terraform-test"
      user_id    = "AIDATEST"
    }
  }

  mock_data "aws_partition" {
    defaults = {
      partition  = "aws"
      dns_suffix = "amazonaws.com"
    }
  }

  mock_data "aws_region" {
    defaults = {
      name = "us-west-2"
    }
  }
}

mock_provider "aws" {
  alias = "replica"
}

run "aws_plan_uses_static_resource_counts" {
  command = plan

  variables {
    environment                 = "dev"
    alarm_notification_endpoint = "alerts@fsamp.invalid"
    cognito_callback_urls       = ["https://dev.fsamp.invalid/callback"]
    cognito_logout_urls         = ["https://dev.fsamp.invalid"]
    gateway_image_digest        = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    processor_image_digest      = "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  }

  assert {
    condition     = local.deploy_edge
    error_message = "The AWS plan must include the edge stack."
  }

}

run "aws_endpoint_policy_uses_modern_version" {
  command = plan

  module {
    source = "./modules/networking"
  }

  variables {
    environment              = "dev"
    name_prefix              = "fsamp-dev"
    tags                     = {}
    kms_key_arn              = "arn:aws:kms:us-west-2:123456789012:key/00000000-0000-4000-8000-000000000000"
    enable_private_endpoints = false
  }

  assert {
    condition     = jsondecode(aws_vpc_endpoint.s3.policy).Version == "2012-10-17"
    error_message = "AWS VPC endpoint policies must retain the explicit modern policy-language version."
  }
}

run "local_endpoint_policy_matches_localstack_readback" {
  command = plan

  module {
    source = "./modules/networking"
  }

  variables {
    environment              = "local"
    name_prefix              = "fsamp-local"
    tags                     = {}
    kms_key_arn              = "arn:aws:kms:us-west-2:123456789012:key/00000000-0000-4000-8000-000000000000"
    enable_private_endpoints = false
  }

  assert {
    condition     = !contains(keys(jsondecode(aws_vpc_endpoint.s3.policy)), "Version")
    error_message = "Local endpoint policies must match LocalStack's normalized readback."
  }
}

run "aws_api_methods_require_resource_scopes" {
  command = plan

  module {
    source = "./modules/api-gateway"
  }

  variables {
    environment                        = "dev"
    name_prefix                        = "fsamp-dev"
    tags                               = {}
    kms_key_arn                        = "arn:aws:kms:us-west-2:123456789012:key/00000000-0000-4000-8000-000000000000"
    cognito_user_pool_arn              = "arn:aws:cognito-idp:us-west-2:123456789012:userpool/us-west-2_test"
    enable_cognito_authorizer          = true
    enable_waf                         = false
    enable_alb_integration             = true
    private_subnet_ids                 = ["subnet-private"]
    vpc_link_security_group_ids        = ["sg-vpc-link"]
    alb_arn                            = "arn:aws:elasticloadbalancing:us-west-2:123456789012:loadbalancer/app/fsamp/test"
    alb_dns_name                       = "internal.fsamp.invalid"
    alb_tls_enabled                    = false
    cognito_resource_server_identifier = "https://fsamp-dev-api"
  }

  assert {
    condition = toset(aws_api_gateway_method.upload_post[0].authorization_scopes) == toset([
      "https://fsamp-dev-api/files.write",
    ])
    error_message = "AWS upload methods must require the resource-server write scope."
  }

  assert {
    condition = toset(aws_api_gateway_method.file_get[0].authorization_scopes) == toset([
      "https://fsamp-dev-api/files.read",
    ])
    error_message = "AWS read methods must require the resource-server read scope."
  }

  assert {
    condition = toset(aws_api_gateway_method.file_delete[0].authorization_scopes) == toset([
      "https://fsamp-dev-api/files.delete",
    ])
    error_message = "AWS delete methods must require the resource-server delete scope."
  }

  assert {
    condition = (
      length(aws_api_gateway_integration.upload_post) == 1 &&
      length(aws_api_gateway_integration.file_get) == 1 &&
      length(aws_api_gateway_integration.file_delete) == 1 &&
      length(aws_api_gateway_integration.health_get) == 1 &&
      length(aws_api_gateway_integration.local_vpc) == 0
    )
    error_message = "AWS plans must use integrations with fully managed VPC Link targets."
  }
}

run "local_api_methods_accept_password_flow_access_tokens" {
  command = plan

  module {
    source = "./modules/api-gateway"
  }

  variables {
    environment                        = "local"
    name_prefix                        = "fsamp-local"
    tags                               = {}
    kms_key_arn                        = "arn:aws:kms:us-west-2:123456789012:key/00000000-0000-4000-8000-000000000000"
    cognito_user_pool_arn              = "arn:aws:cognito-idp:us-west-2:123456789012:userpool/us-west-2_test"
    enable_cognito_authorizer          = true
    enable_waf                         = false
    enable_alb_integration             = true
    private_subnet_ids                 = ["subnet-private"]
    vpc_link_security_group_ids        = ["sg-vpc-link"]
    alb_arn                            = "arn:aws:elasticloadbalancing:us-west-2:123456789012:loadbalancer/app/fsamp/test"
    alb_dns_name                       = "internal.fsamp.invalid"
    alb_tls_enabled                    = false
    cognito_resource_server_identifier = "https://fsamp-local-api"
  }

  assert {
    condition = toset(aws_api_gateway_method.upload_post[0].authorization_scopes) == toset([
      "aws.cognito.signin.user.admin",
    ])
    error_message = "Local methods must accept Cognito password-flow access tokens."
  }

  assert {
    condition = (
      length(aws_api_gateway_integration.upload_post) == 0 &&
      length(aws_api_gateway_integration.file_get) == 0 &&
      length(aws_api_gateway_integration.file_delete) == 0 &&
      length(aws_api_gateway_integration.health_get) == 0 &&
      length(aws_api_gateway_integration.local_vpc) == 4
    )
    error_message = "Local plans must isolate all four emulator-specific VPC Link integrations."
  }
}

run "gateway_target_alarm_rejects_missing_target_group_dimension" {
  command = plan

  module {
    source = "./modules/observability"
  }

  variables {
    name_prefix                        = "fsamp-test"
    tags                               = {}
    enable_alarms                      = true
    enable_gateway_alarms              = true
    gateway_alb_full_name              = "app/fsamp-test/0123456789abcdef"
    gateway_alb_target_group_full_name = ""
  }

  plan_options {
    target = [aws_cloudwatch_metric_alarm.gateway_5xx_target]
  }

  expect_failures = [aws_cloudwatch_metric_alarm.gateway_5xx_target]
}

run "gateway_alb_alarm_rejects_missing_load_balancer_dimension" {
  command = plan

  module {
    source = "./modules/observability"
  }

  variables {
    name_prefix                        = "fsamp-test"
    tags                               = {}
    enable_alarms                      = true
    enable_gateway_alarms              = true
    gateway_alb_full_name              = ""
    gateway_alb_target_group_full_name = "targetgroup/fsamp-test/0123456789abcdef"
  }

  plan_options {
    target = [aws_cloudwatch_metric_alarm.gateway_5xx_alb]
  }

  expect_failures = [aws_cloudwatch_metric_alarm.gateway_5xx_alb]
}

run "security_findings_target_rejects_missing_alert_topic" {
  command = plan

  module {
    source = "./modules/audit"
  }

  variables {
    environment         = "test"
    name_prefix         = "fsamp-test"
    tags                = {}
    kms_key_arn         = "arn:aws:kms:us-west-2:123456789012:key/00000000-0000-4000-8000-000000000000"
    enable_cloudtrail   = false
    enable_guardduty    = true
    enable_security_hub = false
    enable_aws_config   = false
    enable_alerting     = true
    alert_topic_arn     = ""
  }

  plan_options {
    target = [aws_cloudwatch_event_target.security_findings]
  }

  expect_failures = [aws_cloudwatch_event_target.security_findings]
}

run "config_target_rejects_missing_alert_topic" {
  command = plan

  module {
    source = "./modules/audit"
  }

  variables {
    environment         = "test"
    name_prefix         = "fsamp-test"
    tags                = {}
    kms_key_arn         = "arn:aws:kms:us-west-2:123456789012:key/00000000-0000-4000-8000-000000000000"
    enable_cloudtrail   = false
    enable_guardduty    = false
    enable_security_hub = false
    enable_aws_config   = true
    enable_alerting     = true
    alert_topic_arn     = ""
  }

  plan_options {
    target = [aws_cloudwatch_event_target.config_noncompliance]
  }

  expect_failures = [aws_cloudwatch_event_target.config_noncompliance]
}

run "local_parity_provisions_event_evidence_queues" {
  command = plan

  module {
    source = "./modules/messaging"
  }

  variables {
    environment             = "local"
    name_prefix             = "fsamp-local"
    kms_key_id              = "arn:aws:kms:us-west-2:123456789012:key/00000000-0000-4000-8000-000000000000"
    tags                    = {}
    enable_e2e_audit_queues = true
  }

  assert {
    condition = toset([
      for queue in aws_sqs_queue.e2e_audit : queue.name
      ]) == toset([
      "fsamp-local-file-events-audit",
      "fsamp-local-processing-events-audit",
    ])
    error_message = "Local parity must retain both event streams for E2E evidence."
  }
}
