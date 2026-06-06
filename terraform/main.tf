module "security" {
  source = "./modules/security"

  environment         = var.environment
  name_prefix         = local.name_prefix
  tags                = local.common_tags
  key_deletion_window = local.key_deletion_days
  enable_key_rotation = true
}

module "networking" {
  source = "./modules/networking"
  count  = local.is_local ? 0 : 1

  environment              = var.environment
  name_prefix              = local.name_prefix
  tags                     = local.common_tags
  kms_key_arn              = module.security.kms_key_arn
  vpc_cidr                 = var.vpc_cidr
  enable_nat_gateway       = var.enable_nat_gateway || local.is_production
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

  environment = var.environment
  name_prefix = local.name_prefix
  kms_key_id  = module.security.kms_key_id
  tags        = local.common_tags

  depends_on = [module.security]
}

module "observability" {
  source = "./modules/observability"

  environment        = var.environment
  name_prefix        = local.name_prefix
  tags               = local.common_tags
  log_retention_days = local.log_retention_days
  kms_key_arn        = module.security.kms_key_arn

  outbox_table_name                  = module.storage.dynamodb_table_names.outbox
  gateway_alb_full_name              = local.is_local ? "" : module.compute[0].gateway_alb_arn_suffix
  gateway_alb_target_group_full_name = local.is_local ? "" : module.compute[0].gateway_alb_target_group_arn_suffix
}

module "auth" {
  source = "./modules/auth"
  count  = local.is_local ? 0 : 1

  environment = var.environment
  name_prefix = local.name_prefix
  tags        = local.common_tags

  callback_urls = var.environment == "prod" ? ["https://app.fsamp.example.com/callback"] : ["http://localhost:3000/callback"]
  logout_urls   = var.environment == "prod" ? ["https://app.fsamp.example.com"] : ["http://localhost:3000"]

  access_token_validity_minutes = var.environment == "prod" ? 30 : 60
  refresh_token_validity_days   = var.environment == "prod" ? 7 : 30
}

module "api_gateway" {
  source = "./modules/api-gateway"
  count  = local.is_local ? 0 : 1

  environment                 = var.environment
  name_prefix                 = local.name_prefix
  tags                        = local.common_tags
  kms_key_arn                 = module.security.kms_key_arn
  cognito_user_pool_arn       = module.auth[0].user_pool_arn
  enable_waf                  = local.enable_waf_computed
  private_subnet_ids          = module.networking[0].private_subnet_ids
  vpc_link_security_group_ids = [module.networking[0].alb_security_group_id]
  alb_arn                     = module.compute[0].gateway_alb_arn
  alb_dns_name                = module.compute[0].gateway_alb_dns_name

  depends_on = [module.auth, module.compute]
}

module "ecr" {
  source = "./modules/ecr"
  count  = local.is_local ? 0 : 1

  environment = var.environment
  name_prefix = local.name_prefix
  kms_key_arn = module.security.kms_key_arn
  tags        = local.common_tags

  depends_on = [module.security]
}

module "compute" {
  source = "./modules/compute"
  count  = local.is_local ? 0 : 1

  environment               = var.environment
  name_prefix               = local.name_prefix
  tags                      = local.common_tags
  aws_region                = var.aws_region
  use_fips_endpoint         = var.use_fips_endpoint
  kms_key_arn               = module.security.kms_key_arn
  ecs_task_role_arn         = module.security.ecs_task_role_arn
  ecs_execution_role_arn    = module.security.ecs_execution_role_arn
  lambda_role_arn           = module.security.lambda_role_arn
  log_group_name            = "/ecs/${local.name_prefix}"
  log_retention_days        = local.log_retention_days
  sqs_queue_arn             = module.messaging.queue_arns.file_processing
  dlq_arn                   = module.messaging.queue_arns.dlq
  vpc_id                    = module.networking[0].vpc_id
  subnet_ids                = module.networking[0].private_subnet_ids
  security_group_id         = module.networking[0].ecs_security_group_id
  lambda_security_group_id  = module.networking[0].lambda_security_group_id
  alb_security_group_id     = module.networking[0].alb_security_group_id
  enable_container_insights = var.enable_container_insights
  enable_processor_ecs      = var.enable_processor_ecs

  sqs_queue_url          = module.messaging.queue_urls.file_processing
  sns_topic_arn          = module.messaging.topic_arns.processing_events
  file_events_topic_arn  = module.messaging.topic_arns.file_events
  s3_bucket_name         = module.storage.bucket_names.files
  dynamodb_table_name    = module.storage.dynamodb_table_names.file_metadata
  outbox_table_name      = module.storage.dynamodb_table_names.outbox
  idempotency_table_name = module.storage.dynamodb_table_names.idempotency_keys
  cognito_user_pool_id   = module.auth[0].user_pool_id
  cognito_client_id      = module.auth[0].web_client_id

  gateway_image   = "${module.ecr[0].repository_urls["gateway"]}:${var.gateway_image_tag}"
  processor_image = "${module.ecr[0].repository_urls["processor"]}:${var.processor_image_tag}"

  outbox_stream_arn        = module.storage.outbox_stream_arn
  outbox_publisher_dlq_arn = module.messaging.queue_arns.outbox_publisher_dlq

  depends_on = [module.security, module.networking, module.messaging, module.ecr]
}

module "audit" {
  source = "./modules/audit"
  count  = local.is_local ? 0 : 1

  environment         = var.environment
  name_prefix         = local.name_prefix
  tags                = local.common_tags
  kms_key_arn         = module.security.kms_key_arn
  enable_cloudtrail   = var.enable_cloudtrail
  enable_guardduty    = var.enable_guardduty
  enable_security_hub = var.enable_security_hub
  enable_aws_config   = local.enable_config_computed

  depends_on = [module.security]
}

# Cross-region replication for tenant data buckets and audit logs.
# Feature-flagged via local.enable_crr_computed (default: prod and staging).
# Uses the aws.replica provider configured in provider.tf.
module "replication" {
  source = "./modules/replication"
  count  = local.is_local ? 0 : 1

  providers = {
    aws         = aws
    aws.replica = aws.replica
  }

  enabled     = local.enable_crr_computed
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

  depends_on = [module.storage, module.audit]
}
