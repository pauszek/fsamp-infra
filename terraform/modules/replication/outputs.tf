output "replica_bucket_arns" {
  description = "Map of source bucket logical name to replica bucket ARN."
  value       = { for k, b in aws_s3_bucket.replica : k => b.arn }
}

output "replica_kms_key_arn" {
  description = "ARN of the replica region KMS key."
  value       = try(aws_kms_key.replica[0].arn, null)
}

output "replication_role_arn" {
  description = "ARN of the IAM role assumed by S3 replication."
  value       = try(aws_iam_role.replication[0].arn, null)
}
