# =============================================================================
# FSAMP Infrastructure - Root Module
# =============================================================================
# This is the main entry point for Terraform configuration.
# Environment-specific configurations are in /environments/{env}/
# =============================================================================

# =============================================================================
# Variables
# =============================================================================

variable "environment" {
  description = "Environment name (local, dev, staging, prod)"
  type        = string
  default     = "local"

  validation {
    condition     = contains(["local", "dev", "staging", "prod"], var.environment)
    error_message = "Environment must be one of: local, dev, staging, prod"
  }
}

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "eu-central-1"
}

variable "project_name" {
  description = "Project name used for resource naming"
  type        = string
  default     = "fsamp"
}

variable "tags" {
  description = "Common tags for all resources"
  type        = map(string)
  default     = {}
}

variable "vpc_cidr" {
  description = "CIDR block for VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "enable_nat_gateway" {
  description = "Enable NAT Gateway (costs ~$32/month per gateway)"
  type        = bool
  default     = false
}

# =============================================================================
# Local Values
# =============================================================================

locals {
  common_tags = merge(
    {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
      Repository  = "fsamp-infra"
    },
    var.tags
  )

  name_prefix = "${var.project_name}-${var.environment}"

  # Environment-specific settings
  is_production = var.environment == "prod"
  is_local      = var.environment == "local"
}

# =============================================================================
# Modules
# =============================================================================

module "security" {
  source = "./modules/security"

  environment         = var.environment
  name_prefix         = local.name_prefix
  tags                = local.common_tags
  key_deletion_window = local.is_production ? 30 : 7
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
  log_retention_days = local.is_production ? 90 : 30
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
# Outputs
# =============================================================================

output "kms_key_arn" {
  description = "ARN of the KMS key"
  value       = module.security.kms_key_arn
}

output "kms_key_alias" {
  description = "Alias of the KMS key"
  value       = module.security.kms_key_alias
}

output "s3_buckets" {
  description = "S3 bucket names"
  value       = module.storage.bucket_names
}

output "sqs_queue_urls" {
  description = "SQS queue URLs"
  value       = module.messaging.queue_urls
}

output "sns_topic_arns" {
  description = "SNS topic ARNs"
  value       = module.messaging.topic_arns
}

output "dynamodb_table_names" {
  description = "DynamoDB table names"
  value       = module.storage.dynamodb_table_names
}

output "ecs_task_role_arn" {
  description = "ARN of the ECS task role"
  value       = module.security.ecs_task_role_arn
}

output "ecs_execution_role_arn" {
  description = "ARN of the ECS execution role"
  value       = module.security.ecs_execution_role_arn
}

output "lambda_role_arn" {
  description = "ARN of the Lambda execution role"
  value       = module.security.lambda_role_arn
}

output "log_group_names" {
  description = "CloudWatch log group names"
  value       = module.observability.log_group_names
}

# Conditional outputs for non-local environments
output "vpc_id" {
  description = "VPC ID (null for local environment)"
  value       = local.is_local ? null : module.networking[0].vpc_id
}

output "vpc_cidr" {
  description = "VPC CIDR block (null for local environment)"
  value       = local.is_local ? null : module.networking[0].vpc_cidr
}

output "public_subnet_ids" {
  description = "Public subnet IDs (null for local environment)"
  value       = local.is_local ? null : module.networking[0].public_subnet_ids
}

output "private_subnet_ids" {
  description = "Private subnet IDs (null for local environment)"
  value       = local.is_local ? null : module.networking[0].private_subnet_ids
}

output "ecs_cluster_name" {
  description = "ECS cluster name (null for local environment)"
  value       = local.is_local ? null : module.compute[0].ecs_cluster_name
}

output "ecs_cluster_arn" {
  description = "ECS cluster ARN (null for local environment)"
  value       = local.is_local ? null : module.compute[0].ecs_cluster_arn
}

output "gateway_service_name" {
  description = "Gateway ECS service name (null for local environment)"
  value       = local.is_local ? null : module.compute[0].gateway_service_name
}

output "processor_lambda_name" {
  description = "Processor Lambda function name (null for local environment)"
  value       = local.is_local ? null : module.compute[0].processor_lambda_name
}

output "processor_lambda_arn" {
  description = "Processor Lambda function ARN (null for local environment)"
  value       = local.is_local ? null : module.compute[0].processor_lambda_arn
}

output "ecr_repository_urls" {
  description = "ECR repository URLs (null for local environment)"
  value       = local.is_local ? null : module.ecr[0].repository_urls
}

output "ecr_repository_names" {
  description = "ECR repository names (null for local environment)"
  value       = local.is_local ? null : module.ecr[0].repository_names
}

# Auth outputs (Cognito)
output "cognito_user_pool_id" {
  description = "Cognito User Pool ID (null for local environment)"
  value       = local.is_local ? null : module.auth[0].user_pool_id
}

output "cognito_user_pool_arn" {
  description = "Cognito User Pool ARN (null for local environment)"
  value       = local.is_local ? null : module.auth[0].user_pool_arn
}

output "cognito_web_client_id" {
  description = "Cognito Web Client ID (null for local environment)"
  value       = local.is_local ? null : module.auth[0].web_client_id
}

output "cognito_domain_url" {
  description = "Cognito Domain URL (null for local environment)"
  value       = local.is_local ? null : module.auth[0].cognito_domain_url
}

# API Gateway outputs
output "api_gateway_endpoint" {
  description = "API Gateway invoke URL (null for local environment)"
  value       = local.is_local ? null : module.api_gateway[0].api_endpoint
}

output "api_gateway_id" {
  description = "API Gateway REST API ID (null for local environment)"
  value       = local.is_local ? null : module.api_gateway[0].api_id
}

output "waf_web_acl_arn" {
  description = "WAF Web ACL ARN (null for local/dev environment)"
  value       = local.is_local ? null : module.api_gateway[0].waf_web_acl_arn
}

