# =============================================================================
# Audit Module - CloudTrail, GuardDuty, AWS Config
# =============================================================================
# FedRAMP-aligned audit and compliance monitoring services.
# All services are feature-flagged for cost control in dev/local environments.
#
# NIST SP 800-53 Control Families:
# - AU (Audit and Accountability) → CloudTrail
# - SI (System and Information Integrity) → GuardDuty
# - CM (Configuration Management) → AWS Config
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

variable "tags" {
  description = "Common tags"
  type        = map(string)
}

variable "kms_key_arn" {
  description = "ARN of the KMS key for encryption"
  type        = string
}

variable "enable_cloudtrail" {
  description = "Enable CloudTrail for API audit logging (FedRAMP AU family)"
  type        = bool
  default     = true
}

variable "enable_guardduty" {
  description = "Enable GuardDuty for threat detection (FedRAMP SI family)"
  type        = bool
  default     = true
}

variable "enable_aws_config" {
  description = "Enable AWS Config for compliance monitoring (FedRAMP CM family)"
  type        = bool
  default     = true
}

# =============================================================================
# Data Sources
# =============================================================================

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# =============================================================================
# CloudTrail - API Audit Logging (NIST AU-2, AU-3, AU-6, AU-12)
# =============================================================================
# Records all API calls for security audit and compliance.
# - Multi-region trail for complete coverage
# - Log file validation for integrity (AU-9)
# - KMS encryption for confidentiality
# - S3 bucket with lifecycle policy for cost control
# =============================================================================

resource "aws_s3_bucket" "cloudtrail_logs" {
  count = var.enable_cloudtrail ? 1 : 0

  bucket        = "${var.name_prefix}-cloudtrail-logs"
  force_destroy = var.environment != "prod"

  tags = merge(var.tags, {
    Name    = "${var.name_prefix}-cloudtrail-logs"
    Purpose = "CloudTrail audit logs"
  })
}

resource "aws_s3_bucket_versioning" "cloudtrail_logs" {
  count  = var.enable_cloudtrail ? 1 : 0
  bucket = aws_s3_bucket.cloudtrail_logs[0].id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cloudtrail_logs" {
  count  = var.enable_cloudtrail ? 1 : 0
  bucket = aws_s3_bucket.cloudtrail_logs[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "cloudtrail_logs" {
  count  = var.enable_cloudtrail ? 1 : 0
  bucket = aws_s3_bucket.cloudtrail_logs[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "cloudtrail_logs" {
  count  = var.enable_cloudtrail ? 1 : 0
  bucket = aws_s3_bucket.cloudtrail_logs[0].id

  rule {
    id     = "cloudtrail-lifecycle"
    status = "Enabled"
    filter {}

    transition {
      days          = 90
      storage_class = "STANDARD_IA"
    }

    transition {
      days          = 365
      storage_class = "GLACIER"
    }

    expiration {
      days = var.environment == "prod" ? 2555 : 365 # 7 years prod, 1 year non-prod
    }
  }
}

# S3 bucket policy allowing CloudTrail to write logs
resource "aws_s3_bucket_policy" "cloudtrail_logs" {
  count  = var.enable_cloudtrail ? 1 : 0
  bucket = aws_s3_bucket.cloudtrail_logs[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AWSCloudTrailAclCheck"
        Effect = "Allow"
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        }
        Action   = "s3:GetBucketAcl"
        Resource = aws_s3_bucket.cloudtrail_logs[0].arn
      },
      {
        Sid    = "AWSCloudTrailWrite"
        Effect = "Allow"
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.cloudtrail_logs[0].arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl" = "bucket-owner-full-control"
          }
        }
      },
      {
        Sid       = "DenyUnencryptedTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.cloudtrail_logs[0].arn,
          "${aws_s3_bucket.cloudtrail_logs[0].arn}/*"
        ]
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      }
    ]
  })
}

resource "aws_cloudtrail" "main" {
  count = var.enable_cloudtrail ? 1 : 0

  name                          = "${var.name_prefix}-trail"
  s3_bucket_name                = aws_s3_bucket.cloudtrail_logs[0].id
  is_multi_region_trail         = true
  include_global_service_events = true
  enable_log_file_validation    = true # AU-9: Integrity verification
  kms_key_id                    = var.kms_key_arn

  # Log management events (API calls)
  event_selector {
    read_write_type           = "All"
    include_management_events = true

    # Log S3 data events for file access auditing
    data_resource {
      type   = "AWS::S3::Object"
      values = ["arn:aws:s3"]
    }
  }

  tags = merge(var.tags, {
    Name       = "${var.name_prefix}-trail"
    Compliance = "NIST-AU-2"
  })

  depends_on = [aws_s3_bucket_policy.cloudtrail_logs]
}

# =============================================================================
# GuardDuty - Threat Detection (NIST SI-4, IR-4, IR-5)
# =============================================================================
# Continuously monitors for malicious activity and unauthorized behavior.
# Analyzes CloudTrail, VPC Flow Logs, and DNS logs.
# =============================================================================

resource "aws_guardduty_detector" "main" {
  count = var.enable_guardduty ? 1 : 0

  enable = true

  # Send findings to CloudWatch Events for alerting
  finding_publishing_frequency = var.environment == "prod" ? "FIFTEEN_MINUTES" : "SIX_HOURS"

  datasources {
    s3_logs {
      enable = true
    }

    kubernetes {
      audit_logs {
        enable = false # Not using EKS
      }
    }

    malware_protection {
      scan_ec2_instance_with_findings {
        ebs_volumes {
          enable = false # Not using EC2 instances
        }
      }
    }
  }

  tags = merge(var.tags, {
    Name       = "${var.name_prefix}-guardduty"
    Compliance = "NIST-SI-4"
  })
}

# =============================================================================
# AWS Config - Compliance Monitoring (NIST CM-2, CM-6, CM-8)
# =============================================================================
# Tracks resource configuration changes and evaluates compliance rules.
# =============================================================================

# S3 bucket for AWS Config delivery
resource "aws_s3_bucket" "config_logs" {
  count = var.enable_aws_config ? 1 : 0

  bucket        = "${var.name_prefix}-config-logs"
  force_destroy = var.environment != "prod"

  tags = merge(var.tags, {
    Name    = "${var.name_prefix}-config-logs"
    Purpose = "AWS Config delivery channel"
  })
}

resource "aws_s3_bucket_server_side_encryption_configuration" "config_logs" {
  count  = var.enable_aws_config ? 1 : 0
  bucket = aws_s3_bucket.config_logs[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "config_logs" {
  count  = var.enable_aws_config ? 1 : 0
  bucket = aws_s3_bucket.config_logs[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "config_logs" {
  count  = var.enable_aws_config ? 1 : 0
  bucket = aws_s3_bucket.config_logs[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AWSConfigBucketPermission"
        Effect = "Allow"
        Principal = {
          Service = "config.amazonaws.com"
        }
        Action   = "s3:GetBucketAcl"
        Resource = aws_s3_bucket.config_logs[0].arn
      },
      {
        Sid    = "AWSConfigBucketDelivery"
        Effect = "Allow"
        Principal = {
          Service = "config.amazonaws.com"
        }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.config_logs[0].arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/Config/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl" = "bucket-owner-full-control"
          }
        }
      },
      {
        Sid       = "DenyUnencryptedTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.config_logs[0].arn,
          "${aws_s3_bucket.config_logs[0].arn}/*"
        ]
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      }
    ]
  })
}

# IAM role for AWS Config
resource "aws_iam_role" "config" {
  count = var.enable_aws_config ? 1 : 0

  name = "${var.name_prefix}-config-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "config.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "config" {
  count = var.enable_aws_config ? 1 : 0

  role       = aws_iam_role.config[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWS_ConfigRole"
}

resource "aws_iam_role_policy" "config_s3" {
  count = var.enable_aws_config ? 1 : 0

  name = "${var.name_prefix}-config-s3-policy"
  role = aws_iam_role.config[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["s3:PutObject", "s3:GetBucketAcl"]
        Resource = [
          aws_s3_bucket.config_logs[0].arn,
          "${aws_s3_bucket.config_logs[0].arn}/*"
        ]
      }
    ]
  })
}

# AWS Config Recorder
resource "aws_config_configuration_recorder" "main" {
  count = var.enable_aws_config ? 1 : 0

  name     = "${var.name_prefix}-recorder"
  role_arn = aws_iam_role.config[0].arn

  recording_group {
    all_supported = true
  }
}

# AWS Config Delivery Channel
resource "aws_config_delivery_channel" "main" {
  count = var.enable_aws_config ? 1 : 0

  name           = "${var.name_prefix}-delivery"
  s3_bucket_name = aws_s3_bucket.config_logs[0].id

  snapshot_delivery_properties {
    delivery_frequency = "Six_Hours"
  }

  depends_on = [aws_config_configuration_recorder.main]
}

# AWS Config Recorder Status
resource "aws_config_configuration_recorder_status" "main" {
  count = var.enable_aws_config ? 1 : 0

  name       = aws_config_configuration_recorder.main[0].name
  is_enabled = true

  depends_on = [aws_config_delivery_channel.main]
}

# =============================================================================
# AWS Config Rules - FIPS / FedRAMP Compliance
# =============================================================================

# Rule: S3 buckets must have server-side encryption enabled
resource "aws_config_config_rule" "s3_encryption" {
  count = var.enable_aws_config ? 1 : 0

  name = "${var.name_prefix}-s3-bucket-encryption"

  source {
    owner             = "AWS"
    source_identifier = "S3_BUCKET_SERVER_SIDE_ENCRYPTION_ENABLED"
  }

  tags = merge(var.tags, {
    Compliance = "NIST-SC-28"
  })

  depends_on = [aws_config_configuration_recorder.main]
}

# Rule: CloudTrail must be enabled
resource "aws_config_config_rule" "cloudtrail_enabled" {
  count = var.enable_aws_config ? 1 : 0

  name = "${var.name_prefix}-cloudtrail-enabled"

  source {
    owner             = "AWS"
    source_identifier = "CLOUD_TRAIL_ENABLED"
  }

  tags = merge(var.tags, {
    Compliance = "NIST-AU-2"
  })

  depends_on = [aws_config_configuration_recorder.main]
}

# Rule: IAM root access key should not exist
resource "aws_config_config_rule" "iam_root_access_key" {
  count = var.enable_aws_config ? 1 : 0

  name = "${var.name_prefix}-iam-root-access-key"

  source {
    owner             = "AWS"
    source_identifier = "IAM_ROOT_ACCESS_KEY_CHECK"
  }

  tags = merge(var.tags, {
    Compliance = "NIST-AC-6"
  })

  depends_on = [aws_config_configuration_recorder.main]
}

# Rule: S3 bucket public read prohibited
resource "aws_config_config_rule" "s3_public_read" {
  count = var.enable_aws_config ? 1 : 0

  name = "${var.name_prefix}-s3-public-read-prohibited"

  source {
    owner             = "AWS"
    source_identifier = "S3_BUCKET_PUBLIC_READ_PROHIBITED"
  }

  tags = merge(var.tags, {
    Compliance = "NIST-AC-3"
  })

  depends_on = [aws_config_configuration_recorder.main]
}

# Rule: DynamoDB tables should have encryption enabled
resource "aws_config_config_rule" "dynamodb_encryption" {
  count = var.enable_aws_config ? 1 : 0

  name = "${var.name_prefix}-dynamodb-table-encrypted-kms"

  source {
    owner             = "AWS"
    source_identifier = "DYNAMODB_TABLE_ENCRYPTED_KMS"
  }

  tags = merge(var.tags, {
    Compliance = "NIST-SC-28"
  })

  depends_on = [aws_config_configuration_recorder.main]
}

# =============================================================================
# Outputs
# =============================================================================

output "cloudtrail_arn" {
  description = "ARN of the CloudTrail trail"
  value       = var.enable_cloudtrail ? aws_cloudtrail.main[0].arn : null
}

output "cloudtrail_s3_bucket" {
  description = "S3 bucket for CloudTrail logs"
  value       = var.enable_cloudtrail ? aws_s3_bucket.cloudtrail_logs[0].id : null
}

output "guardduty_detector_id" {
  description = "GuardDuty detector ID"
  value       = var.enable_guardduty ? aws_guardduty_detector.main[0].id : null
}

output "config_recorder_id" {
  description = "AWS Config recorder ID"
  value       = var.enable_aws_config ? aws_config_configuration_recorder.main[0].id : null
}
