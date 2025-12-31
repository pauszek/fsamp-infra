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

output "lambda_role_arn" {
  description = "ARN of the Lambda execution role"
  value       = module.security.lambda_role_arn
}

output "log_group_names" {
  description = "CloudWatch log group names"
  value       = module.observability.log_group_names
}
