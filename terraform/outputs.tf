output "kms_key_arn" {
  description = "ARN of the KMS key used by the FIPS 140-3-oriented encryption design"
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
output "s3_buckets" {
  description = "Map of S3 bucket names (files, processed, quarantine)"
  value       = module.storage.bucket_names
}

output "dynamodb_table_names" {
  description = "Map of DynamoDB table names (file_metadata, events)"
  value       = module.storage.dynamodb_table_names
}
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
output "log_group_names" {
  description = "Map of CloudWatch log group names"
  value       = module.observability.log_group_names
}
output "vpc_id" {
  description = "VPC ID (null for local environment)"
  value       = length(module.networking) > 0 ? module.networking[0].vpc_id : null
}

output "vpc_cidr" {
  description = "VPC CIDR block (null for local environment)"
  value       = length(module.networking) > 0 ? module.networking[0].vpc_cidr : null
}

output "public_subnet_ids" {
  description = "List of public subnet IDs (null for local environment)"
  value       = length(module.networking) > 0 ? module.networking[0].public_subnet_ids : null
}

output "private_subnet_ids" {
  description = "List of private subnet IDs (null for local environment)"
  value       = length(module.networking) > 0 ? module.networking[0].private_subnet_ids : null
}
output "ecs_cluster_name" {
  description = "ECS cluster name (null for local environment)"
  value       = length(module.compute) > 0 ? module.compute[0].ecs_cluster_name : null
}

output "ecs_cluster_arn" {
  description = "ECS cluster ARN (null for local environment)"
  value       = length(module.compute) > 0 ? module.compute[0].ecs_cluster_arn : null
}

output "gateway_service_name" {
  description = "Gateway ECS service name (null for local environment)"
  value       = length(module.compute) > 0 ? module.compute[0].gateway_service_name : null
}

output "gateway_alb_dns_name" {
  description = "Gateway ALB DNS name used for direct management-endpoint checks"
  value       = length(module.compute) > 0 ? module.compute[0].gateway_alb_dns_name : null
}

output "processor_ecs_service_name" {
  description = "Processor ECS service name (null for local environment)"
  value       = length(module.compute) > 0 ? module.compute[0].processor_service_name : null
}

output "processor_lambda_name" {
  description = "Processor Lambda function name (null for local environment)"
  value       = length(module.compute) > 0 ? module.compute[0].processor_lambda_name : null
}

output "processor_ecs_task_definition_arn" {
  description = "Processor ECS task definition ARN (null for local environment)"
  value       = length(module.compute) > 0 ? module.compute[0].processor_task_definition_arn : null
}

output "processor_lambda_arn" {
  description = "Processor Lambda function ARN (null for local environment)"
  value       = length(module.compute) > 0 ? module.compute[0].processor_lambda_arn : null
}

output "outbox_publisher_lambda_name" {
  description = "Outbox publisher Lambda function name (null until Lambda parity is enabled)"
  value       = length(module.compute) > 0 ? module.compute[0].outbox_publisher_lambda_name : null
}

output "outbox_publisher_lambda_arn" {
  description = "Outbox publisher Lambda function ARN (null until Lambda parity is enabled)"
  value       = length(module.compute) > 0 ? module.compute[0].outbox_publisher_lambda_arn : null
}

output "outbox_retry_lambda_name" {
  description = "Scheduled outbox reconciliation Lambda function name"
  value       = length(module.compute) > 0 ? module.compute[0].outbox_retry_lambda_name : null
}

output "outbox_retry_lambda_arn" {
  description = "Scheduled outbox reconciliation Lambda function ARN"
  value       = length(module.compute) > 0 ? module.compute[0].outbox_retry_lambda_arn : null
}

output "ecr_repository_urls" {
  description = "Map of ECR repository URLs for docker push"
  value       = length(module.ecr) > 0 ? module.ecr[0].repository_urls : null
}

output "ecr_repository_names" {
  description = "Map of ECR repository names"
  value       = length(module.ecr) > 0 ? module.ecr[0].repository_names : null
}
output "cognito_user_pool_id" {
  description = "Cognito User Pool ID (null for local environment)"
  value       = length(module.auth) > 0 ? module.auth[0].user_pool_id : null
}

output "cognito_user_pool_arn" {
  description = "Cognito User Pool ARN (null for local environment)"
  value       = length(module.auth) > 0 ? module.auth[0].user_pool_arn : null
}

output "cognito_web_client_id" {
  description = "Cognito Web Client ID for application authentication"
  value       = length(module.auth) > 0 ? module.auth[0].web_client_id : null
}

output "cognito_resource_server_identifier" {
  description = "Cognito resource server prefix used by API access-token scopes"
  value       = length(module.auth) > 0 ? module.auth[0].resource_server_identifier : null
}

output "cognito_domain_url" {
  description = "Cognito hosted UI domain URL"
  value       = length(module.auth) > 0 ? module.auth[0].cognito_domain_url : null
}
output "api_gateway_endpoint" {
  description = "API Gateway invoke URL"
  value       = length(module.api_gateway) > 0 ? module.api_gateway[0].api_endpoint : null
}

output "api_gateway_id" {
  description = "API Gateway REST API ID"
  value       = length(module.api_gateway) > 0 ? module.api_gateway[0].api_id : null
}

output "waf_web_acl_arn" {
  description = "WAF Web ACL ARN (null for local/dev environment)"
  value       = length(module.api_gateway) > 0 ? module.api_gateway[0].waf_web_acl_arn : null
}
output "environment_info" {
  description = "Summary of environment configuration"
  value = {
    environment     = var.environment
    region          = var.aws_region
    name_prefix     = local.name_prefix
    is_local        = local.is_local
    is_production   = local.is_production
    nat_gateway     = var.enable_nat_gateway || (var.use_fips_endpoint && !local.is_local)
    fips_oriented   = true
    fedramp_aligned = true
  }
}
