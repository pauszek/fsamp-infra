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
  name              = "${var.name_prefix}-dlq-alerts"
  kms_master_key_id = var.kms_key_id

  tags = merge(var.tags, {
    Name    = "${var.name_prefix}-dlq-alerts"
    Purpose = "Dead letter queue alerts"
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
  visibility_timeout_seconds = 300
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
}
resource "aws_cloudwatch_metric_alarm" "dlq_messages" {
  alarm_name          = "${var.name_prefix}-dlq-messages"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 300
  statistic           = "Sum"
  threshold           = 0
  alarm_description   = "Alert when messages appear in DLQ"

  dimensions = {
    QueueName = aws_sqs_queue.dlq.name
  }

  alarm_actions = [aws_sns_topic.dlq_alerts.arn]

  tags = var.tags
}
