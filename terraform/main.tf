# =============================================================================
# FSAMP Infrastructure - Main Configuration
# =============================================================================
# Single configuration for all environments. Values come from tfvars.
#
# Usage:
#   terraform init -backend-config=backends/local.hcl   # or dev.hcl, prod.hcl
#   terraform plan -var-file=envs/local.tfvars          # or dev.tfvars, prod.tfvars
#   terraform apply -var-file=envs/local.tfvars
#
# Files:
#   - provider.tf:  AWS/LocalStack provider configuration
#   - backend.tf:   State backend (partial config)
#   - variables.tf: Input variables
#   - locals.tf:    Computed values
#   - outputs.tf:   Output definitions
#   - envs/*.tfvars: Environment-specific values
#   - backends/*.hcl: Backend configs per environment
# =============================================================================

# =============================================================================
# Modules
# =============================================================================

module "security" {
  source = "./modules/security"

  environment         = var.environment
  name_prefix         = local.name_prefix
  tags                = local.common_tags
  key_deletion_window = local.key_deletion_days
  enable_key_rotation = true
}

# Networking only for non-local environments
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
}

# Auth (Cognito) - only for non-local environments
module "auth" {
  source = "./modules/auth"
  count  = local.is_local ? 0 : 1

  environment = var.environment
  name_prefix = local.name_prefix
  tags        = local.common_tags

  callback_urls = var.environment == "prod" ? ["https://app.fsamp.example.com/callback"] : ["http://localhost:3000/callback"]
  logout_urls   = var.environment == "prod" ? ["https://app.fsamp.example.com"] : ["http://localhost:3000"]

  # FedRAMP AC-12: shorter token lifetime in production
  access_token_validity_minutes = var.environment == "prod" ? 30 : 60
  refresh_token_validity_days   = var.environment == "prod" ? 7 : 30
}

# API Gateway with WAF - only for non-local environments
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

# ECR only for non-local environments
module "ecr" {
  source = "./modules/ecr"
  count  = local.is_local ? 0 : 1

  environment = var.environment
  name_prefix = local.name_prefix
  kms_key_arn = module.security.kms_key_arn
  tags        = local.common_tags

  depends_on = [module.security]
}

# Compute only for non-local environments (LocalStack handles this via init-aws.sh)
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
  log_group_name            = module.observability.log_group_names.ecs
  sqs_queue_arn             = module.messaging.queue_arns.file_processing
  dlq_arn                   = module.messaging.queue_arns.dlq
  vpc_id                    = module.networking[0].vpc_id
  subnet_ids                = module.networking[0].private_subnet_ids
  security_group_id         = module.networking[0].ecs_security_group_id
  lambda_security_group_id  = module.networking[0].lambda_security_group_id
  alb_security_group_id     = module.networking[0].alb_security_group_id
  enable_container_insights = var.enable_container_insights
  enable_processor_ecs      = var.enable_processor_ecs

  # Processor configuration (Lambda + ECS)
  sqs_queue_url       = module.messaging.queue_urls.file_processing
  sns_topic_arn       = module.messaging.topic_arns.processing_events
  s3_bucket_name      = module.storage.bucket_names.files
  dynamodb_table_name = module.storage.dynamodb_table_names.file_metadata
  outbox_table_name   = module.storage.dynamodb_table_names.outbox

  # Container images from ECR
  gateway_image   = "${module.ecr[0].repository_urls["gateway"]}:${var.gateway_image_tag}"
  processor_image = "${module.ecr[0].repository_urls["processor"]}:${var.processor_image_tag}"

  # Outbox Pattern: DynamoDB Streams for transactional event publishing
  outbox_stream_arn = module.storage.outbox_stream_arn

  depends_on = [module.security, module.networking, module.observability, module.messaging, module.ecr]
}

# Audit services (CloudTrail, GuardDuty, AWS Config) - FedRAMP alignment
# Feature-flagged per environment for cost control
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

# =============================================================================
# Outputs - see outputs.tf for all output definitions
# =============================================================================
