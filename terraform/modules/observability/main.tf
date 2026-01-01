# =============================================================================
# Observability Module - CloudWatch, X-Ray
# =============================================================================
# Centralized logging, metrics, tracing, dashboards and alarms
# Provides comprehensive observability for FSAMP platform
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

variable "log_retention_days" {
  description = "CloudWatch log retention in days"
  type        = number
  default     = 30
}

variable "processor_lambda_name" {
  description = "Name of the processor Lambda function"
  type        = string
  default     = ""
}

variable "outbox_publisher_lambda_name" {
  description = "Name of the outbox publisher Lambda function"
  type        = string
  default     = ""
}

variable "alarm_sns_topic_arn" {
  description = "SNS topic ARN for CloudWatch alarm notifications"
  type        = string
  default     = ""
}

# =============================================================================
# CloudWatch Log Groups
# =============================================================================

resource "aws_cloudwatch_log_group" "ecs" {
  name              = "/ecs/${var.name_prefix}"
  retention_in_days = var.log_retention_days

  tags = merge(var.tags, {
    Name = "/ecs/${var.name_prefix}"
  })
}

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${var.name_prefix}"
  retention_in_days = var.log_retention_days

  tags = merge(var.tags, {
    Name = "/aws/lambda/${var.name_prefix}"
  })
}

resource "aws_cloudwatch_log_group" "api_gateway" {
  name              = "/aws/apigateway/${var.name_prefix}"
  retention_in_days = var.log_retention_days

  tags = merge(var.tags, {
    Name = "/aws/apigateway/${var.name_prefix}"
  })
}

# =============================================================================
# CloudWatch Dashboard
# =============================================================================
# Comprehensive dashboard for FSAMP platform monitoring:
# - Lambda metrics (Processor, Outbox Publisher)
# - SQS queue metrics
# - DynamoDB operations
# - S3 storage metrics
# - Custom application metrics
# - Error logs
# =============================================================================

resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "${var.name_prefix}-dashboard"

  dashboard_body = jsonencode({
    widgets = [
      # ==============================================
      # Row 1: Lambda Processor Metrics
      # ==============================================
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 8
        height = 6
        properties = {
          title  = "📊 Lambda Processor - Invocations"
          region = data.aws_region.current.name
          metrics = [
            ["AWS/Lambda", "Invocations", "FunctionName", "${var.name_prefix}-processor", { "stat": "Sum", "color": "#2ca02c" }],
            [".", "Errors", ".", ".", { "stat": "Sum", "color": "#d62728" }],
            [".", "Throttles", ".", ".", { "stat": "Sum", "color": "#ff7f0e" }]
          ]
          period = 60
          view   = "timeSeries"
          stacked = false
        }
      },
      {
        type   = "metric"
        x      = 8
        y      = 0
        width  = 8
        height = 6
        properties = {
          title  = "⏱️ Lambda Processor - Duration"
          region = data.aws_region.current.name
          metrics = [
            ["AWS/Lambda", "Duration", "FunctionName", "${var.name_prefix}-processor", { "stat": "Average", "color": "#1f77b4" }],
            ["...", { "stat": "p50", "color": "#2ca02c" }],
            ["...", { "stat": "p95", "color": "#ff7f0e" }],
            ["...", { "stat": "p99", "color": "#d62728" }]
          ]
          period = 60
          view   = "timeSeries"
        }
      },
      {
        type   = "metric"
        x      = 16
        y      = 0
        width  = 8
        height = 6
        properties = {
          title  = "🔄 Lambda Processor - Concurrency"
          region = data.aws_region.current.name
          metrics = [
            ["AWS/Lambda", "ConcurrentExecutions", "FunctionName", "${var.name_prefix}-processor", { "stat": "Maximum", "color": "#9467bd" }]
          ]
          period = 60
          view   = "timeSeries"
        }
      },
      # ==============================================
      # Row 2: Outbox Publisher & SQS Metrics
      # ==============================================
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 8
        height = 6
        properties = {
          title  = "📤 Outbox Publisher - Invocations"
          region = data.aws_region.current.name
          metrics = [
            ["AWS/Lambda", "Invocations", "FunctionName", "${var.name_prefix}-outbox-publisher", { "stat": "Sum", "color": "#2ca02c" }],
            [".", "Errors", ".", ".", { "stat": "Sum", "color": "#d62728" }]
          ]
          period = 60
          view   = "timeSeries"
        }
      },
      {
        type   = "metric"
        x      = 8
        y      = 6
        width  = 8
        height = 6
        properties = {
          title  = "📬 SQS Queue - Messages"
          region = data.aws_region.current.name
          metrics = [
            ["AWS/SQS", "NumberOfMessagesSent", "QueueName", "${var.name_prefix}-file-processing", { "stat": "Sum", "color": "#2ca02c" }],
            [".", "NumberOfMessagesReceived", ".", ".", { "stat": "Sum", "color": "#1f77b4" }],
            [".", "ApproximateNumberOfMessagesVisible", ".", ".", { "stat": "Average", "color": "#ff7f0e" }]
          ]
          period = 60
          view   = "timeSeries"
        }
      },
      {
        type   = "metric"
        x      = 16
        y      = 6
        width  = 8
        height = 6
        properties = {
          title  = "💀 Dead Letter Queue"
          region = data.aws_region.current.name
          metrics = [
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", "${var.name_prefix}-dlq", { "stat": "Sum", "color": "#d62728" }],
            [".", "NumberOfMessagesSent", ".", ".", { "stat": "Sum", "color": "#ff7f0e" }]
          ]
          period = 60
          view   = "timeSeries"
          annotations = {
            horizontal = [
              {
                label = "Alert threshold"
                value = 1
                color = "#d62728"
              }
            ]
          }
        }
      },
      # ==============================================
      # Row 3: DynamoDB Metrics
      # ==============================================
      {
        type   = "metric"
        x      = 0
        y      = 12
        width  = 8
        height = 6
        properties = {
          title  = "💾 DynamoDB - Consumed Capacity"
          region = data.aws_region.current.name
          metrics = [
            ["AWS/DynamoDB", "ConsumedReadCapacityUnits", "TableName", "${var.name_prefix}-file-metadata", { "stat": "Sum", "color": "#1f77b4" }],
            [".", "ConsumedWriteCapacityUnits", ".", ".", { "stat": "Sum", "color": "#2ca02c" }]
          ]
          period = 60
          view   = "timeSeries"
        }
      },
      {
        type   = "metric"
        x      = 8
        y      = 12
        width  = 8
        height = 6
        properties = {
          title  = "📦 DynamoDB Outbox - Operations"
          region = data.aws_region.current.name
          metrics = [
            ["AWS/DynamoDB", "ConsumedReadCapacityUnits", "TableName", "${var.name_prefix}-outbox", { "stat": "Sum", "color": "#1f77b4" }],
            [".", "ConsumedWriteCapacityUnits", ".", ".", { "stat": "Sum", "color": "#2ca02c" }],
            [".", "TransactionConflict", ".", ".", { "stat": "Sum", "color": "#d62728" }]
          ]
          period = 60
          view   = "timeSeries"
        }
      },
      {
        type   = "metric"
        x      = 16
        y      = 12
        width  = 8
        height = 6
        properties = {
          title  = "⚠️ DynamoDB - Throttled Requests"
          region = data.aws_region.current.name
          metrics = [
            ["AWS/DynamoDB", "ThrottledRequests", "TableName", "${var.name_prefix}-file-metadata", { "stat": "Sum", "color": "#d62728" }],
            [".", "ThrottledRequests", "TableName", "${var.name_prefix}-outbox", { "stat": "Sum", "color": "#ff7f0e" }]
          ]
          period = 60
          view   = "timeSeries"
        }
      },
      # ==============================================
      # Row 4: Custom Application Metrics (Powertools)
      # ==============================================
      {
        type   = "metric"
        x      = 0
        y      = 18
        width  = 8
        height = 6
        properties = {
          title  = "📁 Files Processed"
          region = data.aws_region.current.name
          metrics = [
            ["FSAMP/Processor", "FilesProcessed", { "stat": "Sum", "color": "#2ca02c" }],
            [".", "FilesProcessedSuccess", { "stat": "Sum", "color": "#1f77b4" }],
            [".", "FilesProcessedFailed", { "stat": "Sum", "color": "#d62728" }]
          ]
          period = 60
          view   = "timeSeries"
        }
      },
      {
        type   = "metric"
        x      = 8
        y      = 18
        width  = 8
        height = 6
        properties = {
          title  = "⏱️ Processing Duration (Custom)"
          region = data.aws_region.current.name
          metrics = [
            ["FSAMP/Processor", "ProcessingDuration", { "stat": "Average", "color": "#1f77b4" }],
            ["...", { "stat": "p95", "color": "#ff7f0e" }],
            ["...", { "stat": "p99", "color": "#d62728" }]
          ]
          period = 60
          view   = "timeSeries"
        }
      },
      {
        type   = "metric"
        x      = 16
        y      = 18
        width  = 8
        height = 6
        properties = {
          title  = "📤 Outbox Events Published"
          region = data.aws_region.current.name
          metrics = [
            ["FSAMP/OutboxPublisher", "EventsPublished", { "stat": "Sum", "color": "#2ca02c" }],
            [".", "EventsFailedToPublish", { "stat": "Sum", "color": "#d62728" }],
            [".", "EventsRetried", { "stat": "Sum", "color": "#ff7f0e" }]
          ]
          period = 60
          view   = "timeSeries"
        }
      },
      # ==============================================
      # Row 5: S3 & SNS Metrics
      # ==============================================
      {
        type   = "metric"
        x      = 0
        y      = 24
        width  = 12
        height = 6
        properties = {
          title  = "🗂️ S3 Bucket Metrics"
          region = data.aws_region.current.name
          metrics = [
            ["AWS/S3", "NumberOfObjects", "BucketName", "${var.name_prefix}-files", "StorageType", "AllStorageTypes", { "stat": "Average", "period": 86400 }],
            [".", "BucketSizeBytes", ".", ".", ".", ".", { "stat": "Average", "period": 86400 }]
          ]
          view = "singleValue"
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 24
        width  = 12
        height = 6
        properties = {
          title  = "📢 SNS Topic - Messages"
          region = data.aws_region.current.name
          metrics = [
            ["AWS/SNS", "NumberOfMessagesPublished", "TopicName", "${var.name_prefix}-events", { "stat": "Sum", "color": "#2ca02c" }],
            [".", "NumberOfNotificationsFailed", ".", ".", { "stat": "Sum", "color": "#d62728" }]
          ]
          period = 60
          view   = "timeSeries"
        }
      },
      # ==============================================
      # Row 6: Error Logs
      # ==============================================
      {
        type   = "log"
        x      = 0
        y      = 30
        width  = 24
        height = 6
        properties = {
          title  = "🚨 Recent Errors (All Services)"
          region = data.aws_region.current.name
          query  = <<-EOT
            SOURCE '/aws/lambda/${var.name_prefix}-processor' 
            | SOURCE '/aws/lambda/${var.name_prefix}-outbox-publisher'
            | SOURCE '/ecs/${var.name_prefix}'
            | filter @message like /ERROR|error|Error|CRITICAL|Exception/
            | sort @timestamp desc
            | limit 50
          EOT
        }
      },
      # ==============================================
      # Row 7: Key Performance Indicators
      # ==============================================
      {
        type   = "metric"
        x      = 0
        y      = 36
        width  = 6
        height = 4
        properties = {
          title  = "Success Rate"
          region = data.aws_region.current.name
          metrics = [
            [{
              expression = "100 - 100 * errors / MAX([errors + invocations, 1])"
              label      = "Success %"
              id         = "e1"
              color      = "#2ca02c"
            }],
            ["AWS/Lambda", "Errors", "FunctionName", "${var.name_prefix}-processor", { "stat": "Sum", "id": "errors", "visible": false }],
            [".", "Invocations", ".", ".", { "stat": "Sum", "id": "invocations", "visible": false }]
          ]
          period = 300
          view   = "singleValue"
          stat   = "Average"
        }
      },
      {
        type   = "metric"
        x      = 6
        y      = 36
        width  = 6
        height = 4
        properties = {
          title  = "Total Files Today"
          region = data.aws_region.current.name
          metrics = [
            ["AWS/Lambda", "Invocations", "FunctionName", "${var.name_prefix}-processor", { "stat": "Sum", "color": "#1f77b4" }]
          ]
          period = 86400
          view   = "singleValue"
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 36
        width  = 6
        height = 4
        properties = {
          title  = "Avg Duration"
          region = data.aws_region.current.name
          metrics = [
            ["AWS/Lambda", "Duration", "FunctionName", "${var.name_prefix}-processor", { "stat": "Average", "color": "#ff7f0e" }]
          ]
          period = 3600
          view   = "singleValue"
        }
      },
      {
        type   = "metric"
        x      = 18
        y      = 36
        width  = 6
        height = 4
        properties = {
          title  = "DLQ Messages"
          region = data.aws_region.current.name
          metrics = [
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", "${var.name_prefix}-dlq", { "stat": "Sum", "color": "#d62728" }]
          ]
          period = 300
          view   = "singleValue"
        }
      }
    ]
  })
}

# =============================================================================
# Data Sources
# =============================================================================

data "aws_region" "current" {}

# =============================================================================
# CloudWatch Alarms
# =============================================================================
# Critical alarms for FSAMP platform monitoring:
# - Lambda errors
# - DLQ messages (failed processing)
# - DynamoDB throttling
# - Processing latency
# =============================================================================

# Alarm: Lambda Processor Errors
resource "aws_cloudwatch_metric_alarm" "processor_errors" {
  alarm_name          = "${var.name_prefix}-processor-errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Sum"
  threshold           = 5
  alarm_description   = "Lambda Processor has high error rate"
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = "${var.name_prefix}-processor"
  }

  alarm_actions = var.alarm_sns_topic_arn != "" ? [var.alarm_sns_topic_arn] : []
  ok_actions    = var.alarm_sns_topic_arn != "" ? [var.alarm_sns_topic_arn] : []

  tags = merge(var.tags, {
    Name     = "${var.name_prefix}-processor-errors"
    Severity = "high"
  })
}

# Alarm: Outbox Publisher Errors
resource "aws_cloudwatch_metric_alarm" "outbox_publisher_errors" {
  alarm_name          = "${var.name_prefix}-outbox-publisher-errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Sum"
  threshold           = 3
  alarm_description   = "Outbox Publisher Lambda has errors - events may not be published"
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = "${var.name_prefix}-outbox-publisher"
  }

  alarm_actions = var.alarm_sns_topic_arn != "" ? [var.alarm_sns_topic_arn] : []
  ok_actions    = var.alarm_sns_topic_arn != "" ? [var.alarm_sns_topic_arn] : []

  tags = merge(var.tags, {
    Name     = "${var.name_prefix}-outbox-publisher-errors"
    Severity = "high"
  })
}

# Alarm: DLQ Messages (Failed Processing)
resource "aws_cloudwatch_metric_alarm" "dlq_messages" {
  alarm_name          = "${var.name_prefix}-dlq-messages"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 300
  statistic           = "Sum"
  threshold           = 0
  alarm_description   = "Messages in Dead Letter Queue - failed processing requires attention"
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = "${var.name_prefix}-dlq"
  }

  alarm_actions = var.alarm_sns_topic_arn != "" ? [var.alarm_sns_topic_arn] : []
  ok_actions    = var.alarm_sns_topic_arn != "" ? [var.alarm_sns_topic_arn] : []

  tags = merge(var.tags, {
    Name     = "${var.name_prefix}-dlq-messages"
    Severity = "critical"
  })
}

# Alarm: High Processing Latency
resource "aws_cloudwatch_metric_alarm" "processor_latency" {
  alarm_name          = "${var.name_prefix}-processor-high-latency"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "Duration"
  namespace           = "AWS/Lambda"
  period              = 300
  extended_statistic  = "p95"
  threshold           = 60000  # 60 seconds
  alarm_description   = "Lambda Processor p95 latency is high"
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = "${var.name_prefix}-processor"
  }

  alarm_actions = var.alarm_sns_topic_arn != "" ? [var.alarm_sns_topic_arn] : []

  tags = merge(var.tags, {
    Name     = "${var.name_prefix}-processor-high-latency"
    Severity = "medium"
  })
}

# Alarm: Lambda Throttling
resource "aws_cloudwatch_metric_alarm" "processor_throttles" {
  alarm_name          = "${var.name_prefix}-processor-throttles"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "Throttles"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Sum"
  threshold           = 10
  alarm_description   = "Lambda Processor is being throttled - may need increased concurrency"
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = "${var.name_prefix}-processor"
  }

  alarm_actions = var.alarm_sns_topic_arn != "" ? [var.alarm_sns_topic_arn] : []

  tags = merge(var.tags, {
    Name     = "${var.name_prefix}-processor-throttles"
    Severity = "medium"
  })
}

# Alarm: DynamoDB Throttling
resource "aws_cloudwatch_metric_alarm" "dynamodb_throttles" {
  alarm_name          = "${var.name_prefix}-dynamodb-throttles"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "ThrottledRequests"
  namespace           = "AWS/DynamoDB"
  period              = 300
  statistic           = "Sum"
  threshold           = 5
  alarm_description   = "DynamoDB table is being throttled"
  treat_missing_data  = "notBreaching"

  dimensions = {
    TableName = "${var.name_prefix}-file-metadata"
  }

  alarm_actions = var.alarm_sns_topic_arn != "" ? [var.alarm_sns_topic_arn] : []

  tags = merge(var.tags, {
    Name     = "${var.name_prefix}-dynamodb-throttles"
    Severity = "medium"
  })
}

# Alarm: SQS Queue Backlog
resource "aws_cloudwatch_metric_alarm" "sqs_backlog" {
  alarm_name          = "${var.name_prefix}-sqs-backlog"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 300
  statistic           = "Average"
  threshold           = 1000
  alarm_description   = "SQS queue has large backlog - processing may be falling behind"
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = "${var.name_prefix}-file-processing"
  }

  alarm_actions = var.alarm_sns_topic_arn != "" ? [var.alarm_sns_topic_arn] : []

  tags = merge(var.tags, {
    Name     = "${var.name_prefix}-sqs-backlog"
    Severity = "medium"
  })
}

# Alarm: SQS Message Age (Processing Delay)
resource "aws_cloudwatch_metric_alarm" "sqs_message_age" {
  alarm_name          = "${var.name_prefix}-sqs-message-age"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "ApproximateAgeOfOldestMessage"
  namespace           = "AWS/SQS"
  period              = 300
  statistic           = "Maximum"
  threshold           = 300  # 5 minutes
  alarm_description   = "Old messages in queue - processing may be stuck"
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = "${var.name_prefix}-file-processing"
  }

  alarm_actions = var.alarm_sns_topic_arn != "" ? [var.alarm_sns_topic_arn] : []

  tags = merge(var.tags, {
    Name     = "${var.name_prefix}-sqs-message-age"
    Severity = "medium"
  })
}

# Composite Alarm: Critical System Health
resource "aws_cloudwatch_composite_alarm" "critical_health" {
  alarm_name = "${var.name_prefix}-critical-health"

  alarm_rule = join(" OR ", [
    "ALARM(${aws_cloudwatch_metric_alarm.dlq_messages.alarm_name})",
    "ALARM(${aws_cloudwatch_metric_alarm.processor_errors.alarm_name})",
    "ALARM(${aws_cloudwatch_metric_alarm.outbox_publisher_errors.alarm_name})"
  ])

  alarm_description = "CRITICAL: FSAMP system health degraded - requires immediate attention"

  alarm_actions = var.alarm_sns_topic_arn != "" ? [var.alarm_sns_topic_arn] : []
  ok_actions    = var.alarm_sns_topic_arn != "" ? [var.alarm_sns_topic_arn] : []

  tags = merge(var.tags, {
    Name     = "${var.name_prefix}-critical-health"
    Severity = "critical"
  })
}

# =============================================================================
# Outputs
# =============================================================================

output "log_group_names" {
  description = "Map of service to log group names"
  value = {
    ecs         = aws_cloudwatch_log_group.ecs.name
    lambda      = aws_cloudwatch_log_group.lambda.name
    api_gateway = aws_cloudwatch_log_group.api_gateway.name
  }
}

output "dashboard_name" {
  description = "CloudWatch dashboard name"
  value       = aws_cloudwatch_dashboard.main.dashboard_name
}

output "dashboard_url" {
  description = "URL to CloudWatch dashboard"
  value       = "https://${data.aws_region.current.name}.console.aws.amazon.com/cloudwatch/home?region=${data.aws_region.current.name}#dashboards:name=${aws_cloudwatch_dashboard.main.dashboard_name}"
}

output "alarm_arns" {
  description = "Map of alarm names to ARNs"
  value = {
    processor_errors        = aws_cloudwatch_metric_alarm.processor_errors.arn
    outbox_publisher_errors = aws_cloudwatch_metric_alarm.outbox_publisher_errors.arn
    dlq_messages            = aws_cloudwatch_metric_alarm.dlq_messages.arn
    processor_latency       = aws_cloudwatch_metric_alarm.processor_latency.arn
    processor_throttles     = aws_cloudwatch_metric_alarm.processor_throttles.arn
    dynamodb_throttles      = aws_cloudwatch_metric_alarm.dynamodb_throttles.arn
    sqs_backlog             = aws_cloudwatch_metric_alarm.sqs_backlog.arn
    sqs_message_age         = aws_cloudwatch_metric_alarm.sqs_message_age.arn
    critical_health         = aws_cloudwatch_composite_alarm.critical_health.arn
  }
}
