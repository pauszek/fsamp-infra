output "bucket_names" {
  description = "Map of bucket purposes to names"
  value = {
    for k, v in aws_s3_bucket.buckets : k => v.id
  }
}

output "bucket_arns" {
  description = "Map of bucket purposes to ARNs"
  value = {
    for k, v in aws_s3_bucket.buckets : k => v.arn
  }
}

output "dynamodb_table_names" {
  description = "Map of table purposes to names"
  value = {
    file_metadata    = aws_dynamodb_table.file_metadata.name
    events           = aws_dynamodb_table.events.name
    outbox           = aws_dynamodb_table.outbox.name
    idempotency_keys = aws_dynamodb_table.idempotency_keys.name
  }
}

output "outbox_stream_arn" {
  description = "ARN of the DynamoDB Streams for the outbox table"
  value       = aws_dynamodb_table.outbox.stream_arn
}
