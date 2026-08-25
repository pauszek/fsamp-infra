output "cloudtrail_s3_bucket" {
  description = "S3 bucket for CloudTrail logs"
  value       = var.enable_cloudtrail ? aws_s3_bucket.cloudtrail_logs[0].id : null
}

output "cloudtrail_s3_bucket_arn" {
  description = "ARN of the S3 bucket holding CloudTrail logs (for cross-region replication wiring)."
  value       = var.enable_cloudtrail ? aws_s3_bucket.cloudtrail_logs[0].arn : null
}
