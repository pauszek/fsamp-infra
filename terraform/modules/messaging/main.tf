terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.44.0, < 7.0.0"
    }
  }
}
data "aws_caller_identity" "current" {}

locals {
  e2e_audit_topics = var.enable_e2e_audit_queues ? {
    file_events       = aws_sns_topic.file_events.arn
    processing_events = aws_sns_topic.processing_events.arn
  } : {}
}

resource "aws_sns_topic" "file_events" {
  name              = "${var.name_prefix}-file-events"
  kms_master_key_id = var.kms_key_id

  tags = merge(var.tags, {
    Name        = "${var.name_prefix}-file-events"
    Purpose     = "File upload and processing events"
    Environment = var.environment
  })
}

resource "aws_sns_topic" "processing_events" {
  name              = "${var.name_prefix}-processing-events"
  kms_master_key_id = var.kms_key_id

  tags = merge(var.tags, {
    Name    = "${var.name_prefix}-processing-events"
    Purpose = "Processing completion events"
  })
}

resource "aws_sns_topic" "dlq_alerts" {
  name              = "${var.name_prefix}-operations-alerts"
  kms_master_key_id = var.kms_key_id

  tags = merge(var.tags, {
    Name    = "${var.name_prefix}-operations-alerts"
    Purpose = "Central operations and security alerts"
  })
}

resource "aws_sns_topic_subscription" "operations_alerts" {
  count = var.alarm_notification_endpoint != "" ? 1 : 0

  topic_arn = aws_sns_topic.dlq_alerts.arn
  protocol  = var.alarm_notification_protocol
  endpoint  = var.alarm_notification_endpoint
}

resource "aws_sns_topic_policy" "operations_alerts" {
  arn = aws_sns_topic.dlq_alerts.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowMonitoringServices"
        Effect = "Allow"
        Principal = {
          Service = ["cloudwatch.amazonaws.com", "events.amazonaws.com"]
        }
        Action   = "sns:Publish"
        Resource = aws_sns_topic.dlq_alerts.arn
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      },
      {
        Sid       = "DenyUnencryptedTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "sns:Publish"
        Resource  = aws_sns_topic.dlq_alerts.arn
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      }
    ]
  })
}
resource "aws_sqs_queue" "dlq" {
  name                      = "${var.name_prefix}-dlq"
  message_retention_seconds = 1209600
  kms_master_key_id         = var.kms_key_id

  tags = merge(var.tags, {
    Name    = "${var.name_prefix}-dlq"
    Purpose = "Dead letter queue for failed messages"
  })
}

# Dedicated DLQ for outbox publisher Lambda. Receives DynamoDB Streams
# batches that exhaust the maximum_retry_attempts budget configured on the
# event source mapping. Without a dedicated destination, failed batches are
# silently dropped, which would break the at-least-once delivery guarantee
# of the transactional outbox pattern. (FedRAMP CP-9, AU-2)
resource "aws_sqs_queue" "outbox_publisher_dlq" {
  name                      = "${var.name_prefix}-outbox-publisher-dlq"
  message_retention_seconds = 1209600
  kms_master_key_id         = var.kms_key_id

  tags = merge(var.tags, {
    Name    = "${var.name_prefix}-outbox-publisher-dlq"
    Purpose = "DLQ for failed DynamoDB Streams batches in the outbox publisher"
  })
}

resource "aws_sqs_queue" "file_processing" {
  name                       = "${var.name_prefix}-file-processing"
  visibility_timeout_seconds = var.processor_timeout_seconds * 6 + 5
  message_retention_seconds  = var.message_retention_seconds
  kms_master_key_id          = var.kms_key_id

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = var.dlq_max_receive_count
  })

  tags = merge(var.tags, {
    Name    = "${var.name_prefix}-file-processing"
    Purpose = "File processing queue"
  })
}

resource "aws_sqs_queue" "analysis_results" {
  name                       = "${var.name_prefix}-analysis-results"
  visibility_timeout_seconds = 60
  message_retention_seconds  = var.message_retention_seconds
  kms_master_key_id          = var.kms_key_id

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = var.dlq_max_receive_count
  })

  tags = merge(var.tags, {
    Name    = "${var.name_prefix}-analysis-results"
    Purpose = "Analysis results queue"
  })
}
resource "aws_sqs_queue_policy" "file_processing" {
  queue_url = aws_sqs_queue.file_processing.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowSNSMessages"
        Effect = "Allow"
        Principal = {
          Service = "sns.amazonaws.com"
        }
        Action   = "sqs:SendMessage"
        Resource = aws_sqs_queue.file_processing.arn
        Condition = {
          ArnEquals = {
            "aws:SourceArn" = aws_sns_topic.file_events.arn
          }
        }
      },
      {
        Sid       = "DenyUnencryptedTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "sqs:*"
        Resource  = aws_sqs_queue.file_processing.arn
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      }
    ]
  })
}

resource "aws_sqs_queue_policy" "dlq" {
  queue_url = aws_sqs_queue.dlq.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyUnencryptedTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "sqs:*"
        Resource  = aws_sqs_queue.dlq.arn
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      }
    ]
  })
}

resource "aws_sqs_queue_policy" "analysis_results" {
  queue_url = aws_sqs_queue.analysis_results.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyUnencryptedTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "sqs:*"
        Resource  = aws_sqs_queue.analysis_results.arn
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      }
    ]
  })
}

resource "aws_sqs_queue_policy" "outbox_publisher_dlq" {
  queue_url = aws_sqs_queue.outbox_publisher_dlq.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyUnencryptedTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "sqs:*"
        Resource  = aws_sqs_queue.outbox_publisher_dlq.arn
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      }
    ]
  })
}
resource "aws_sns_topic_policy" "file_events" {
  arn = aws_sns_topic.file_events.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowAccountPublish"
        Effect = "Allow"
        Principal = {
          AWS = data.aws_caller_identity.current.account_id
        }
        Action   = "sns:Publish"
        Resource = aws_sns_topic.file_events.arn
      },
      {
        Sid       = "DenyUnencryptedTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "sns:Publish"
        Resource  = aws_sns_topic.file_events.arn
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      }
    ]
  })
}

resource "aws_sns_topic_policy" "processing_events" {
  arn = aws_sns_topic.processing_events.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowAccountPublish"
        Effect = "Allow"
        Principal = {
          AWS = data.aws_caller_identity.current.account_id
        }
        Action   = "sns:Publish"
        Resource = aws_sns_topic.processing_events.arn
      },
      {
        Sid       = "DenyUnencryptedTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "sns:Publish"
        Resource  = aws_sns_topic.processing_events.arn
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      }
    ]
  })
}
resource "aws_sns_topic_subscription" "file_events_to_processing" {
  topic_arn = aws_sns_topic.file_events.arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.file_processing.arn

  raw_message_delivery = true

  filter_policy = jsonencode({
    eventType = ["FILE_UPLOADED"]
  })
}

resource "aws_sqs_queue" "e2e_audit" {
  for_each = local.e2e_audit_topics

  name                      = "${var.name_prefix}-${replace(each.key, "_", "-")}-audit"
  message_retention_seconds = var.message_retention_seconds
  kms_master_key_id         = var.kms_key_id

  tags = merge(var.tags, {
    Name        = "${var.name_prefix}-${replace(each.key, "_", "-")}-audit"
    Purpose     = "Local E2E event-delivery evidence"
    Environment = var.environment
  })
}

resource "aws_sqs_queue_policy" "e2e_audit" {
  for_each = local.e2e_audit_topics

  queue_url = aws_sqs_queue.e2e_audit[each.key].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowSNSMessages"
        Effect = "Allow"
        Principal = {
          Service = "sns.amazonaws.com"
        }
        Action   = "sqs:SendMessage"
        Resource = aws_sqs_queue.e2e_audit[each.key].arn
        Condition = {
          ArnEquals = {
            "aws:SourceArn" = each.value
          }
        }
      },
      {
        Sid       = "DenyUnencryptedTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "sqs:*"
        Resource  = aws_sqs_queue.e2e_audit[each.key].arn
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      }
    ]
  })
}

resource "aws_sns_topic_subscription" "e2e_audit" {
  for_each = local.e2e_audit_topics

  topic_arn            = each.value
  protocol             = "sqs"
  endpoint             = aws_sqs_queue.e2e_audit[each.key].arn
  raw_message_delivery = true

  depends_on = [aws_sqs_queue_policy.e2e_audit]
}
