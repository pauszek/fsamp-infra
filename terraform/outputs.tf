# =============================================================================
# FSAMP Infrastructure - Root Module Outputs
# =============================================================================
# These outputs expose key resource identifiers for use by applications
# and other Terraform configurations.
# =============================================================================

# -----------------------------------------------------------------------------
# Security Outputs
# -----------------------------------------------------------------------------

output "kms_key_arn" {
  description = "ARN of the KMS key for FIPS 140-3 compliant encryption"
  value       = module.security.kms_key_arn
}

output "kms_key_alias" {
  description = "Alias of the KMS key (e.g., alias/fsamp-local-master-key)"
  value       = module.security.kms_key_alias
}

output "ecs_task_role_arn" {
  description = "ARN of the ECS task role for application permissions"
  value       = module.security.ecs_task_role_arn
}

output "ecs_execution_role_arn" {
  description = "ARN of the ECS execution role for container management"
  value       = module.security.ecs_execution_role_arn
}

output "lambda_role_arn" {
  description = "ARN of the Lambda execution role"
  value       = module.security.lambda_role_arn
}

# -----------------------------------------------------------------------------
# Storage Outputs
# -----------------------------------------------------------------------------

output "s3_buckets" {
  description = "Map of S3 bucket names (files, processed, quarantine)"
  value       = module.storage.bucket_names
}

output "dynamodb_table_names" {
  description = "Map of DynamoDB table names (file_metadata, events)"
  value       = module.storage.dynamodb_table_names
}

# -----------------------------------------------------------------------------
# Messaging Outputs
# -----------------------------------------------------------------------------

output "sqs_queue_urls" {
  description = "Map of SQS queue URLs for application configuration"
  value       = module.messaging.queue_urls
}

output "sqs_queue_arns" {
  description = "Map of SQS queue ARNs for IAM policies"
  value       = module.messaging.queue_arns
}

output "sns_topic_arns" {
  description = "Map of SNS topic ARNs for event publishing"
  value       = module.messaging.topic_arns
}

# -----------------------------------------------------------------------------
# Observability Outputs
# -----------------------------------------------------------------------------

output "log_group_names" {
  description = "Map of CloudWatch log group names"
  value       = module.observability.log_group_names
}

# -----------------------------------------------------------------------------
# Networking Outputs (non-local environments)
# -----------------------------------------------------------------------------

output "vpc_id" {
  description = "VPC ID (null for local environment)"
  value       = local.is_local ? null : module.networking[0].vpc_id
}

output "vpc_cidr" {
  description = "VPC CIDR block (null for local environment)"
  value       = local.is_local ? null : module.networking[0].vpc_cidr
}

output "public_subnet_ids" {
  description = "List of public subnet IDs (null for local environment)"
  value       = local.is_local ? null : module.networking[0].public_subnet_ids
}

output "private_subnet_ids" {
  description = "List of private subnet IDs (null for local environment)"
  value       = local.is_local ? null : module.networking[0].private_subnet_ids
}

# -----------------------------------------------------------------------------
# Compute Outputs (non-local environments)
# -----------------------------------------------------------------------------

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

# -----------------------------------------------------------------------------
# ECR Outputs (non-local environments)
# -----------------------------------------------------------------------------

output "ecr_repository_urls" {
  description = "Map of ECR repository URLs for docker push"
  value       = local.is_local ? null : module.ecr[0].repository_urls
}

output "ecr_repository_names" {
  description = "Map of ECR repository names"
  value       = local.is_local ? null : module.ecr[0].repository_names
}

# -----------------------------------------------------------------------------
# Auth Outputs (non-local environments)
# -----------------------------------------------------------------------------

output "cognito_user_pool_id" {
  description = "Cognito User Pool ID (null for local environment)"
  value       = local.is_local ? null : module.auth[0].user_pool_id
}

output "cognito_user_pool_arn" {
  description = "Cognito User Pool ARN (null for local environment)"
  value       = local.is_local ? null : module.auth[0].user_pool_arn
}

output "cognito_web_client_id" {
  description = "Cognito Web Client ID for application authentication"
  value       = local.is_local ? null : module.auth[0].web_client_id
}

output "cognito_domain_url" {
  description = "Cognito hosted UI domain URL"
  value       = local.is_local ? null : module.auth[0].cognito_domain_url
}

# -----------------------------------------------------------------------------
# API Gateway Outputs (non-local environments)
# -----------------------------------------------------------------------------

output "api_gateway_endpoint" {
  description = "API Gateway invoke URL"
  value       = local.is_local ? null : module.api_gateway[0].api_endpoint
}

output "api_gateway_id" {
  description = "API Gateway REST API ID"
  value       = local.is_local ? null : module.api_gateway[0].api_id
}

output "waf_web_acl_arn" {
  description = "WAF Web ACL ARN (null for local/dev environment)"
  value       = local.is_local ? null : module.api_gateway[0].waf_web_acl_arn
}

# -----------------------------------------------------------------------------
# Environment Info
# -----------------------------------------------------------------------------

output "environment_info" {
  description = "Summary of environment configuration"
  value = {
    environment    = var.environment
    region         = var.aws_region
    name_prefix    = local.name_prefix
    is_local       = local.is_local
    is_production  = local.is_production
    nat_gateway    = var.enable_nat_gateway
    fips_compliant = true
  }
}

