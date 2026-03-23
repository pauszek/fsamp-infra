# =============================================================================
# Storage Module - S3, DynamoDB
# =============================================================================
# Encrypted storage with FIPS 140-3 compliance
# =============================================================================

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.40"
    }
  }
}

# =============================================================================
# Variables
# =============================================================================

variable "environment" {
  description = "Environment name"
  type        = string
}

variable "name_prefix" {
  description = "Prefix for resource names"
  type        = string
}

variable "kms_key_arn" {
  description = "ARN of the KMS key for encryption"
  type        = string
}

variable "kms_key_id" {
  description = "ID of the KMS key for encryption"
  type        = string
}

variable "tags" {
  description = "Common tags"
  type        = map(string)
}

# =============================================================================
# S3 Buckets
# =============================================================================

locals {
  buckets = {
    files      = "${var.name_prefix}-files"
    processed  = "${var.name_prefix}-processed"
    quarantine = "${var.name_prefix}-quarantine"
  }
}

resource "aws_s3_bucket" "buckets" {
  for_each = local.buckets

  bucket        = each.value
  force_destroy = var.environment != "prod"

  tags = merge(var.tags, {
    Name    = each.value
    Purpose = each.key
  })
}

resource "aws_s3_bucket_versioning" "buckets" {
  for_each = aws_s3_bucket.buckets

  bucket = each.value.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "buckets" {
  for_each = aws_s3_bucket.buckets

  bucket = each.value.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "buckets" {
  for_each = aws_s3_bucket.buckets

  bucket = each.value.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "files" {
  bucket = aws_s3_bucket.buckets["files"].id

  rule {
    id     = "transition-to-ia"
    status = "Enabled"

    filter {}

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    transition {
      days          = 90
      storage_class = "GLACIER"
    }

    noncurrent_version_transition {
      noncurrent_days = 30
      storage_class   = "STANDARD_IA"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "quarantine" {
  bucket = aws_s3_bucket.buckets["quarantine"].id

  rule {
    id     = "expire-quarantine"
    status = "Enabled"

    filter {}

    expiration {
      days = 30
    }
  }
}

# =============================================================================
# S3 Bucket Policies - Enforce TLS (FedRAMP SC-8, SC-23)
# =============================================================================
# Deny any requests not using HTTPS (aws:SecureTransport = false).
# This ensures all S3 access uses TLS encrypted transport.
# =============================================================================

resource "aws_s3_bucket_policy" "enforce_tls" {
  for_each = aws_s3_bucket.buckets

  bucket = each.value.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyUnencryptedTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          each.value.arn,
          "${each.value.arn}/*"
        ]
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      },
      {
        Sid       = "DenyOutdatedTLS"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          each.value.arn,
          "${each.value.arn}/*"
        ]
        Condition = {
          NumericLessThan = {
            "s3:TlsVersion" = 1.2
          }
        }
      }
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.buckets]
}

# =============================================================================
# S3 Server Access Logging (FedRAMP AC-6(9), AU-3)
# =============================================================================
# Log all access to data buckets for audit trail.
# =============================================================================

resource "aws_s3_bucket" "access_logs" {
  bucket        = "${var.name_prefix}-access-logs"
  force_destroy = var.environment != "prod"

  tags = merge(var.tags, {
    Name    = "${var.name_prefix}-access-logs"
    Purpose = "S3 server access logs"
  })
}

resource "aws_s3_bucket_server_side_encryption_configuration" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  rule {
    id     = "access-logs-lifecycle"
    status = "Enabled"
    filter {}

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    expiration {
      days = var.environment == "prod" ? 365 : 90
    }
  }
}

resource "aws_s3_bucket_logging" "buckets" {
  for_each = aws_s3_bucket.buckets

  bucket        = each.value.id
  target_bucket = aws_s3_bucket.access_logs.id
  target_prefix = "${each.key}/"
}

# =============================================================================
# DynamoDB Tables
# =============================================================================

resource "aws_dynamodb_table" "file_metadata" {
  name         = "${var.name_prefix}-file-metadata"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "fileId"
  range_key    = "uploadTimestamp"

  attribute {
    name = "fileId"
    type = "S"
  }

  attribute {
    name = "uploadTimestamp"
    type = "S"
  }

  attribute {
    name = "status"
    type = "S"
  }

  global_secondary_index {
    name            = "status-index"
    hash_key        = "status"
    range_key       = "uploadTimestamp"
    projection_type = "ALL"
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = var.kms_key_arn
  }

  point_in_time_recovery {
    enabled = true
  }

  ttl {
    attribute_name = "expiresAt"
    enabled        = true
  }

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-file-metadata"
  })
}

resource "aws_dynamodb_table" "events" {
  name         = "${var.name_prefix}-events"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "eventId"
  range_key    = "timestamp"

  attribute {
    name = "eventId"
    type = "S"
  }

  attribute {
    name = "timestamp"
    type = "S"
  }

  attribute {
    name = "correlationId"
    type = "S"
  }

  global_secondary_index {
    name            = "correlation-index"
    hash_key        = "correlationId"
    range_key       = "timestamp"
    projection_type = "ALL"
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = var.kms_key_arn
  }

  point_in_time_recovery {
    enabled = true
  }

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-events"
  })
}

# =============================================================================
# Outbox Table (Transactional Outbox Pattern)
# =============================================================================
# Enables reliable event publishing with at-least-once delivery guarantee.
# DynamoDB Streams triggers the Outbox Publisher Lambda to publish events.
# =============================================================================

resource "aws_dynamodb_table" "outbox" {
  name         = "${var.name_prefix}-outbox"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "PK"
  range_key    = "SK"

  # Enable DynamoDB Streams for CDC (Change Data Capture)
  stream_enabled   = true
  stream_view_type = "NEW_IMAGE"

  attribute {
    name = "PK"
    type = "S"
  }

  attribute {
    name = "SK"
    type = "S"
  }

  # GSI for querying events by status (PENDING, PUBLISHED, FAILED)
  attribute {
    name = "GSI1PK"
    type = "S"
  }

  attribute {
    name = "GSI1SK"
    type = "S"
  }

  global_secondary_index {
    name            = "GSI1"
    hash_key        = "GSI1PK"
    range_key       = "GSI1SK"
    projection_type = "ALL"
  }

  # Server-side encryption with KMS
  server_side_encryption {
    enabled     = true
    kms_key_arn = var.kms_key_arn
  }

  # Point-in-time recovery for audit trail
  point_in_time_recovery {
    enabled = true
  }

  # TTL for automatic cleanup of old published events
  ttl {
    attribute_name = "ttl"
    enabled        = true
  }

  tags = merge(var.tags, {
    Name    = "${var.name_prefix}-outbox"
    Purpose = "Transactional Outbox Pattern"
  })
}

# =============================================================================
# Idempotency Keys Table
# =============================================================================
# Implements the Idempotency Key pattern for safe API retries.
# Stores idempotency keys with responses for deduplication.
# TTL automatically cleans up keys after 24 hours.
# =============================================================================

resource "aws_dynamodb_table" "idempotency_keys" {
  name         = "${var.name_prefix}-idempotency-keys"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "idempotencyKey"
  range_key    = "userId"

  attribute {
    name = "idempotencyKey"
    type = "S"
  }

  attribute {
    name = "userId"
    type = "S"
  }

  # Server-side encryption with KMS
  server_side_encryption {
    enabled     = true
    kms_key_arn = var.kms_key_arn
  }

  # TTL for automatic cleanup (keys expire after 24 hours)
  ttl {
    attribute_name = "ttl"
    enabled        = true
  }

  tags = merge(var.tags, {
    Name    = "${var.name_prefix}-idempotency-keys"
    Purpose = "Idempotency Key Pattern"
  })
}

# =============================================================================
# Outputs
# =============================================================================

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

output "dynamodb_table_arns" {
  description = "Map of table purposes to ARNs"
  value = {
    file_metadata    = aws_dynamodb_table.file_metadata.arn
    events           = aws_dynamodb_table.events.arn
    outbox           = aws_dynamodb_table.outbox.arn
    idempotency_keys = aws_dynamodb_table.idempotency_keys.arn
  }
}

output "outbox_stream_arn" {
  description = "ARN of the DynamoDB Streams for the outbox table"
  value       = aws_dynamodb_table.outbox.stream_arn
}
