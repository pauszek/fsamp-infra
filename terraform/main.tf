module "security" {
  source = "./modules/security"

  environment         = var.environment
  name_prefix         = local.name_prefix
  tags                = local.common_tags
  key_deletion_window = local.key_deletion_days
  enable_key_rotation = true
}

resource "terraform_data" "environment_contract" {
  input = var.environment

  lifecycle {
    precondition {
      condition     = local.is_local || var.alarm_notification_endpoint != ""
      error_message = "alarm_notification_endpoint must be configured for every AWS environment."
    }

    precondition {
      condition     = !(local.is_staging || local.is_production) || (var.alb_certificate_mode == "acm" && var.alb_domain_name != null && length(trimspace(var.alb_domain_name)) > 0 && !endswith(var.alb_domain_name, ".example.com"))
      error_message = "staging and prod require alb_certificate_mode=acm and a non-placeholder alb_domain_name."
    }

    precondition {
      condition = !(local.is_staging || local.is_production) || (
        length(var.cognito_callback_urls) > 0 &&
        length(var.cognito_logout_urls) > 0 &&
        alltrue([for url in concat(var.cognito_callback_urls, var.cognito_logout_urls) : startswith(url, "https://") && !strcontains(url, "example.com")])
      )
      error_message = "staging and prod require explicit non-placeholder HTTPS Cognito callback and logout URLs."
    }

    precondition {
      condition = local.is_local || alltrue([
        for url in concat(var.cognito_callback_urls, var.cognito_logout_urls) : startswith(url, "https://")
      ])
      error_message = "Only the local environment may use HTTP Cognito callback or logout URLs."
    }

    precondition {
      condition     = local.is_local || (var.gateway_image_digest != "" && var.processor_image_digest != "")
      error_message = "AWS environments must deploy immutable gateway and processor image digests."
    }
  }
}

module "networking" {
  source = "./modules/networking"
  count  = local.deploy_core ? 1 : 0

  environment              = var.environment
  name_prefix              = local.name_prefix
  tags                     = local.common_tags
  kms_key_arn              = module.security.kms_key_arn
  vpc_cidr                 = var.vpc_cidr
  enable_nat_gateway       = var.enable_nat_gateway || (var.use_fips_endpoint && !local.is_local)
  single_nat_gateway       = !local.is_production
  enable_private_endpoints = var.enable_private_endpoints
}

module "storage" {
  source = "./modules/storage"

  environment = var.environment
  name_prefix = local.name_prefix
  kms_key_arn = module.security.kms_key_arn
  tags        = local.common_tags

  depends_on = [module.security]
}

module "messaging" {
  source = "./modules/messaging"

  environment                 = var.environment
  name_prefix                 = local.name_prefix
  kms_key_id                  = module.security.kms_key_id
  tags                        = local.common_tags
  processor_timeout_seconds   = 300
  alarm_notification_endpoint = var.alarm_notification_endpoint
  alarm_notification_protocol = var.alarm_notification_protocol

  depends_on = [module.security]
}

module "observability" {
  source = "./modules/observability"

  name_prefix         = local.name_prefix
  tags                = local.common_tags
  enable_alarms       = !local.is_local
  alarm_sns_topic_arn = module.messaging.topic_arns.operations_alerts

  outbox_table_name                  = module.storage.dynamodb_table_names.outbox
  gateway_alb_full_name              = length(module.compute) > 0 ? module.compute[0].gateway_alb_arn_suffix : ""
  gateway_alb_target_group_full_name = length(module.compute) > 0 ? module.compute[0].gateway_alb_target_group_arn_suffix : ""
}

module "auth" {
  source = "./modules/auth"
  count  = local.deploy_core ? 1 : 0

  environment = var.environment
  name_prefix = local.name_prefix
  tags        = local.common_tags

  callback_urls = local.callback_urls
  logout_urls   = local.logout_urls

  access_token_validity_minutes = var.environment == "prod" ? 30 : 60
  refresh_token_validity_days   = var.environment == "prod" ? 7 : 30

  # Local e2e logs in with USER_PASSWORD_AUTH; AWS environments stay SRP-only.
  enable_password_auth_flow = local.is_local
}

module "api_gateway" {
  source = "./modules/api-gateway"
  count  = local.deploy_edge ? 1 : 0

  environment                 = var.environment
  name_prefix                 = local.name_prefix
  tags                        = local.common_tags
  kms_key_arn                 = module.security.kms_key_arn
  cognito_user_pool_arn       = module.auth[0].user_pool_arn
  enable_cognito_authorizer   = true
  enable_waf                  = local.enable_waf_computed
  private_subnet_ids          = module.networking[0].private_subnet_ids
  vpc_link_security_group_ids = [module.networking[0].alb_security_group_id]
  enable_alb_integration      = true
  alb_arn                     = module.compute[0].gateway_alb_arn
  alb_dns_name                = module.compute[0].gateway_endpoint_host
  alb_tls_verified            = module.compute[0].alb_tls_verified

  depends_on = [module.auth, module.compute]
}

module "ecr" {
  source = "./modules/ecr"
  count  = local.deploy_core ? 1 : 0

  environment              = var.environment
  name_prefix              = local.name_prefix
  kms_key_arn              = module.security.kms_key_arn
  tags                     = local.common_tags
  enable_registry_scanning = !local.is_local

  depends_on = [module.security]
}

data "aws_ecr_image" "gateway" {
  count = local.deploy_edge && var.gateway_image_digest == "" ? 1 : 0

  repository_name = module.ecr[0].repository_names["gateway"]
  image_tag       = var.gateway_image_tag

  depends_on = [module.ecr]
}

data "aws_ecr_image" "processor" {
  count = local.deploy_edge && var.processor_image_digest == "" ? 1 : 0

  repository_name = module.ecr[0].repository_names["processor"]
  image_tag       = var.processor_image_tag

  depends_on = [module.ecr]
}

module "compute" {
  source = "./modules/compute"
  count  = local.deploy_edge ? 1 : 0

  environment                  = var.environment
  name_prefix                  = local.name_prefix
  tags                         = local.common_tags
  aws_region                   = var.aws_region
  use_fips_endpoint            = var.use_fips_endpoint
  kms_key_arn                  = module.security.kms_key_arn
  gateway_task_role_arn        = module.security.gateway_task_role_arn
  processor_task_role_arn      = module.security.processor_task_role_arn
  ecs_execution_role_arn       = module.security.ecs_execution_role_arn
  processor_lambda_role_arn    = module.security.processor_lambda_role_arn
  outbox_lambda_role_arn       = module.security.outbox_lambda_role_arn
  retry_lambda_role_arn        = module.security.retry_lambda_role_arn
  log_group_name               = "/ecs/${local.name_prefix}"
  log_retention_days           = local.log_retention_days
  sqs_queue_arn                = module.messaging.queue_arns.file_processing
  dlq_arn                      = module.messaging.queue_arns.dlq
  vpc_id                       = module.networking[0].vpc_id
  subnet_ids                   = module.networking[0].private_subnet_ids
  security_group_id            = module.networking[0].ecs_security_group_id
  lambda_security_group_id     = module.networking[0].lambda_security_group_id
  alb_security_group_id        = module.networking[0].alb_security_group_id
  enable_container_insights    = var.enable_container_insights
  enable_processor_ecs         = var.enable_processor_ecs
  enable_lambdas               = !local.is_local || var.local_enable_lambdas
  alb_certificate_mode         = var.alb_certificate_mode
  alb_domain_name              = var.alb_domain_name
  localstack_internal_endpoint = local.is_local ? var.localstack_internal_endpoint : ""

  sqs_queue_url          = module.messaging.queue_urls.file_processing
  sns_topic_arn          = module.messaging.topic_arns.processing_events
  file_events_topic_arn  = module.messaging.topic_arns.file_events
  s3_bucket_name         = module.storage.bucket_names.files
  dynamodb_table_name    = module.storage.dynamodb_table_names.file_metadata
  outbox_table_name      = module.storage.dynamodb_table_names.outbox
  idempotency_table_name = module.storage.dynamodb_table_names.idempotency_keys
  cognito_user_pool_id   = module.auth[0].user_pool_id
  cognito_client_id      = module.auth[0].web_client_id

  gateway_image = (
    var.gateway_image_digest != ""
    ? "${module.ecr[0].repository_urls["gateway"]}@${var.gateway_image_digest}"
    : "${module.ecr[0].repository_urls["gateway"]}:${var.gateway_image_tag}"
  )
  processor_image = (
    var.processor_image_digest != ""
    ? "${module.ecr[0].repository_urls["processor"]}@${var.processor_image_digest}"
    : "${module.ecr[0].repository_urls["processor"]}:${var.processor_image_tag}"
  )

  outbox_stream_arn        = module.storage.outbox_stream_arn
  outbox_publisher_dlq_arn = module.messaging.queue_arns.outbox_publisher_dlq

  depends_on = [module.security, module.networking, module.messaging, module.ecr, data.aws_ecr_image.gateway, data.aws_ecr_image.processor]
}

module "audit" {
  source = "./modules/audit"
  count  = local.deploy_audit ? 1 : 0

  environment       = var.environment
  name_prefix       = local.name_prefix
  tags              = local.common_tags
  kms_key_arn       = module.security.kms_key_arn
  enable_cloudtrail = var.enable_cloudtrail
  enable_aws_config = local.enable_config_computed
  # GuardDuty and Security Hub are not emulated by LocalStack, so they are
  # forced off locally even when their flags are set.
  enable_guardduty    = !local.is_local && var.enable_guardduty
  enable_security_hub = !local.is_local && var.enable_security_hub
  alert_topic_arn     = module.messaging.topic_arns.operations_alerts
  data_bucket_arns    = values(module.storage.bucket_arns)

  depends_on = [module.security]
}

resource "terraform_data" "replica_region_guard" {
  count = local.enable_crr_computed ? 1 : 0
  input = var.replica_region

  lifecycle {
    precondition {
      condition     = var.replica_region != var.aws_region
      error_message = "replica_region must be distinct from aws_region when enable_cross_region_replication=true."
    }
  }
}

# Optional cross-region replication for tenant data buckets and audit logs.
# Disabled by default so the thesis/free-tier baseline creates active resources
# only in us-west-2; enable explicitly for a DR validation run.
# Uses the aws.replica provider configured in provider.tf.
module "replication" {
  source = "./modules/replication"
  count  = !local.is_local && local.enable_crr_computed ? 1 : 0

  providers = {
    aws         = aws
    aws.replica = aws.replica
  }

  enabled     = true
  environment = var.environment
  name_prefix = local.name_prefix
  tags        = local.common_tags

  source_buckets = merge(
    {
      files     = { id = module.storage.bucket_names.files, arn = module.storage.bucket_arns.files }
      processed = { id = module.storage.bucket_names.processed, arn = module.storage.bucket_arns.processed }
    },
    var.enable_cloudtrail && length(module.audit) > 0 && module.audit[0].cloudtrail_s3_bucket != null ? {
      cloudtrail_logs = {
        id  = module.audit[0].cloudtrail_s3_bucket
        arn = module.audit[0].cloudtrail_s3_bucket_arn
      }
    } : {}
  )

  depends_on = [module.storage, module.audit, terraform_data.replica_region_guard]
}
