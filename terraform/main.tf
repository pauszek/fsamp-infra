# =============================================================================
# FSAMP Infrastructure - Root Module
# =============================================================================
# This is the main entry point for Terraform configuration.
# Environment-specific configurations are in /environments/{env}/
#
# Files in this directory:
#   - variables.tf: Input variable definitions
#   - locals.tf: Computed local values
#   - outputs.tf: Output definitions
#   - versions.tf: Provider version constraints
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
  enable_key_rotation = !local.is_local
}

# Networking only for non-local environments
module "networking" {
  source = "./modules/networking"
  count  = local.is_local ? 0 : 1

  environment        = var.environment
  name_prefix        = local.name_prefix
  tags               = local.common_tags
  vpc_cidr           = var.vpc_cidr
  enable_nat_gateway = var.enable_nat_gateway || local.is_production
  single_nat_gateway = !local.is_production
}

module "storage" {
  source = "./modules/storage"

  environment = var.environment
  name_prefix = local.name_prefix
  kms_key_arn = module.security.kms_key_arn
  kms_key_id  = module.security.kms_key_id
  tags        = local.common_tags

  depends_on = [module.security]
}

module "messaging" {
  source = "./modules/messaging"

  environment = var.environment
  name_prefix = local.name_prefix
  kms_key_arn = module.security.kms_key_arn
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
}

# API Gateway with WAF - only for non-local environments
module "api_gateway" {
  source = "./modules/api-gateway"
  count  = local.is_local ? 0 : 1

  environment           = var.environment
  name_prefix           = local.name_prefix
  tags                  = local.common_tags
  cognito_user_pool_arn = module.auth[0].user_pool_arn
  enable_waf            = local.is_production

  depends_on = [module.auth]
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

  environment            = var.environment
  name_prefix            = local.name_prefix
  tags                   = local.common_tags
  aws_region             = var.aws_region
  kms_key_arn            = module.security.kms_key_arn
  ecs_task_role_arn      = module.security.ecs_task_role_arn
  ecs_execution_role_arn = module.security.ecs_execution_role_arn
  lambda_role_arn        = module.security.lambda_role_arn
  log_group_name         = module.observability.log_group_names.ecs
  lambda_log_group_name  = module.observability.log_group_names.lambda
  sqs_queue_arn          = module.messaging.queue_arns.file_processing
  dlq_arn                = module.messaging.queue_arns.dlq
  vpc_id                 = module.networking[0].vpc_id
  subnet_ids             = module.networking[0].private_subnet_ids
  security_group_id      = module.networking[0].ecs_security_group_id

  depends_on = [module.security, module.networking, module.observability, module.messaging]
}

# =============================================================================
# Outputs - see outputs.tf for all output definitions
# =============================================================================


