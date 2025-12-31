# =============================================================================
# Local Environment Outputs
# =============================================================================
# Re-exports from root module. Use: terraform output -json
# =============================================================================

output "environment_info" {
  description = "Environment configuration summary"
  value       = module.fsamp.environment_info
}

output "kms_key_arn" {
  description = "KMS key ARN"
  value       = module.fsamp.kms_key_arn
}

output "s3_buckets" {
  description = "S3 bucket names"
  value       = module.fsamp.s3_buckets
}

output "sqs_queue_urls" {
  description = "SQS queue URLs"
  value       = module.fsamp.sqs_queue_urls
}

output "sns_topic_arns" {
  description = "SNS topic ARNs"
  value       = module.fsamp.sns_topic_arns
}

output "dynamodb_table_names" {
  description = "DynamoDB table names"
  value       = module.fsamp.dynamodb_table_names
}

