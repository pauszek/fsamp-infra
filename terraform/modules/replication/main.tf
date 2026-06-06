terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source                = "hashicorp/aws"
      version               = ">= 6.44.0, < 7.0.0"
      configuration_aliases = [aws.replica]
    }
  }
}

# This module provisions cross-region replication for buckets that hold
# tenant data and audit logs. It owns:
#   - the destination buckets in the replica region (with versioning,
#     SSE-KMS, public access block, TLS-only policy);
#   - a dedicated KMS key in the replica region used to encrypt the
#     replicated objects;
#   - the IAM role and policy that S3 assumes to perform replication;
#   - the aws_s3_bucket_replication_configuration on the source buckets.
#
# The module is intentionally feature-flagged via the count gate on
# var.enabled. When disabled, no replica resources are created and no
# replication configuration is attached to the source buckets, which
# allows local and dev environments to skip the cost and complexity.
#
# FedRAMP control mapping:
#   - CP-9 Information System Backup
#   - AU-9 Protection of Audit Information
#   - SC-28(1) Cryptographic Protection (replica also encrypted)
#
data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "primary" {}

# Replica-region KMS key. The source bucket SSE-KMS uses the primary KMS
# key, but replicated objects must be re-encrypted with a key that lives
# in the destination region; otherwise S3 replication fails. The key is
# also used by replicated CloudTrail logs that the audit module copies
# into the replica trail bucket.
resource "aws_kms_key" "replica" {
  count = var.enabled ? 1 : 0

  provider = aws.replica

  description             = "FSAMP replica region key (${var.environment}) - SSE-KMS for replicated tenant data and audit logs"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AccountRoot"
        Effect = "Allow"
        Principal = {
          AWS = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "AllowS3Replication"
        Effect = "Allow"
        Principal = {
          Service = "s3.amazonaws.com"
        }
        Action = [
          "kms:Encrypt",
          "kms:GenerateDataKey*",
          "kms:DescribeKey"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      }
    ]
  })

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-replica-key"
  })

}

resource "aws_kms_alias" "replica" {
  count = var.enabled ? 1 : 0

  provider = aws.replica

  name          = "alias/${var.name_prefix}-replica-key"
  target_key_id = aws_kms_key.replica[0].key_id
}

# Destination buckets, one per source.
resource "aws_s3_bucket" "replica" {
  for_each = var.enabled ? var.source_buckets : {}

  provider = aws.replica

  bucket        = "${each.value.id}-replica"
  force_destroy = var.environment != "prod"

  tags = merge(var.tags, {
    Name          = "${each.value.id}-replica"
    Purpose       = "Cross-region replica"
    SourceBucket  = each.value.id
    PrimaryRegion = data.aws_region.primary.region
  })
}

resource "aws_s3_bucket_versioning" "replica" {
  for_each = aws_s3_bucket.replica

  provider = aws.replica
  bucket   = each.value.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "replica" {
  for_each = aws_s3_bucket.replica

  provider = aws.replica
  bucket   = each.value.id

  rule {
    id     = "replica-retention"
    status = "Enabled"

    filter {}

    transition {
      days          = 365
      storage_class = "GLACIER"
    }

    expiration {
      days = var.environment == "prod" ? 2555 : 365
    }

    noncurrent_version_expiration {
      noncurrent_days = var.environment == "prod" ? 2555 : 365
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.replica]
}

resource "aws_s3_bucket_server_side_encryption_configuration" "replica" {
  for_each = aws_s3_bucket.replica

  provider = aws.replica
  bucket   = each.value.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.replica[0].arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "replica" {
  for_each = aws_s3_bucket.replica

  provider = aws.replica
  bucket   = each.value.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "replica_tls" {
  for_each = aws_s3_bucket.replica

  provider = aws.replica
  bucket   = each.value.id

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
            "aws:SecureTransport"       = "false"
            "aws:PrincipalIsAWSService" = "false"
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
          Bool = {
            "aws:PrincipalIsAWSService" = "false"
          }
          NumericLessThan = {
            "s3:TlsVersion" = 1.2
          }
        }
      }
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.replica]
}

# IAM role assumed by the S3 replication subsystem in the primary region.
resource "aws_iam_role" "replication" {
  count = var.enabled ? 1 : 0

  name = "${var.name_prefix}-s3-replication"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "s3.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-s3-replication"
  })
}

resource "aws_iam_role_policy" "replication" {
  count = var.enabled ? 1 : 0

  name = "${var.name_prefix}-s3-replication"
  role = aws_iam_role.replication[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadSourceBuckets"
        Effect = "Allow"
        Action = [
          "s3:GetReplicationConfiguration",
          "s3:ListBucket",
          "s3:GetBucketVersioning"
        ]
        Resource = [for b in var.source_buckets : b.arn]
      },
      {
        Sid    = "ReadObjectsFromSourceBuckets"
        Effect = "Allow"
        Action = [
          "s3:GetObjectVersionForReplication",
          "s3:GetObjectVersionAcl",
          "s3:GetObjectVersionTagging",
          "s3:GetObjectRetention",
          "s3:GetObjectLegalHold"
        ]
        Resource = [for b in var.source_buckets : "${b.arn}/*"]
      },
      {
        Sid    = "WriteToReplicaBuckets"
        Effect = "Allow"
        Action = [
          "s3:ReplicateObject",
          "s3:ReplicateDelete",
          "s3:ReplicateTags"
        ]
        Resource = [for b in aws_s3_bucket.replica : "${b.arn}/*"]
      },
      {
        Sid    = "DecryptSourceObjects"
        Effect = "Allow"
        Action = [
          "kms:Decrypt"
        ]
        Resource = "*"
        Condition = {
          StringLike = {
            "kms:ViaService" = "s3.${data.aws_region.primary.region}.amazonaws.com"
          }
        }
      },
      {
        Sid    = "EncryptReplicaObjects"
        Effect = "Allow"
        Action = [
          "kms:Encrypt",
          "kms:GenerateDataKey"
        ]
        Resource = aws_kms_key.replica[0].arn
      }
    ]
  })
}

# Attach replication configuration to each source bucket. AWS requires
# the source bucket to have versioning enabled, which the storage module
# already guarantees.
resource "aws_s3_bucket_replication_configuration" "this" {
  for_each = var.enabled ? var.source_buckets : {}

  role   = aws_iam_role.replication[0].arn
  bucket = each.value.id

  rule {
    id     = "replicate-${each.key}"
    status = "Enabled"

    filter {}

    delete_marker_replication {
      status = "Enabled"
    }

    source_selection_criteria {
      sse_kms_encrypted_objects {
        status = "Enabled"
      }
    }

    destination {
      bucket        = aws_s3_bucket.replica[each.key].arn
      storage_class = "STANDARD"

      encryption_configuration {
        replica_kms_key_id = aws_kms_key.replica[0].arn
      }

      replication_time {
        status = "Enabled"
        time {
          minutes = 15
        }
      }

      metrics {
        status = "Enabled"
        event_threshold {
          minutes = 15
        }
      }
    }
  }

  depends_on = [
    aws_iam_role_policy.replication,
    aws_s3_bucket_versioning.replica
  ]
}
