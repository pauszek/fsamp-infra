# =============================================================================
# Production Environment Outputs
# =============================================================================

output "environment_info" {
  description = "Environment configuration summary"
  value       = module.fsamp.environment_info
}

# Security (sensitive in prod)
output "kms_key_arn" {
  description = "KMS key ARN"
  value       = module.fsamp.kms_key_arn
  sensitive   = true
}

# Storage
output "s3_buckets" {
  description = "S3 bucket names"
  value       = module.fsamp.s3_buckets
}

output "dynamodb_table_names" {
  description = "DynamoDB table names"
  value       = module.fsamp.dynamodb_table_names
}

# Messaging
output "sqs_queue_urls" {
  description = "SQS queue URLs"
  value       = module.fsamp.sqs_queue_urls
}

output "sns_topic_arns" {
  description = "SNS topic ARNs"
  value       = module.fsamp.sns_topic_arns
}

# Networking
output "vpc_id" {
  description = "VPC ID"
  value       = module.fsamp.vpc_id
}

# Compute
output "ecs_cluster_name" {
  description = "ECS Cluster name"
  value       = module.fsamp.ecs_cluster_name
}

output "ecr_repository_urls" {
  description = "ECR repository URLs"
  value       = module.fsamp.ecr_repository_urls
  sensitive   = true
}

# Auth
output "cognito_user_pool_id" {
  description = "Cognito User Pool ID"
  value       = module.fsamp.cognito_user_pool_id
}

output "cognito_web_client_id" {
  description = "Cognito Web Client ID"
  value       = module.fsamp.cognito_web_client_id
}

# API
output "api_gateway_endpoint" {
  description = "API Gateway invoke URL"
  value       = module.fsamp.api_gateway_endpoint
}

# WAF (prod only)
output "waf_web_acl_arn" {
  description = "WAF Web ACL ARN"
  value       = module.fsamp.waf_web_acl_arn
}

