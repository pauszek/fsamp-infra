terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.44.0, < 7.0.0"
    }
  }
}
resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${var.name_prefix}"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn

  tags = merge(var.tags, {
    Name        = "/aws/lambda/${var.name_prefix}"
    Environment = var.environment
  })
}

resource "aws_cloudwatch_log_group" "api_gateway" {
  name              = "/aws/apigateway/${var.name_prefix}"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn

  tags = merge(var.tags, {
    Name        = "/aws/apigateway/${var.name_prefix}"
    Environment = var.environment
  })
}
resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "${var.name_prefix}-dashboard"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 8
        height = 6
        properties = {
          title  = "Lambda Processor - Invocations"
          region = data.aws_region.current.region
          metrics = [
            ["AWS/Lambda", "Invocations", "FunctionName", "${var.name_prefix}-processor", { "stat" : "Sum", "color" : "#2ca02c" }],
            [".", "Errors", ".", ".", { "stat" : "Sum", "color" : "#d62728" }],
            [".", "Throttles", ".", ".", { "stat" : "Sum", "color" : "#ff7f0e" }]
          ]
          period  = 60
          view    = "timeSeries"
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
          title  = "Lambda Processor - Duration"
          region = data.aws_region.current.region
          metrics = [
            ["AWS/Lambda", "Duration", "FunctionName", "${var.name_prefix}-processor", { "stat" : "Average", "color" : "#1f77b4" }],
            ["...", { "stat" : "p50", "color" : "#2ca02c" }],
            ["...", { "stat" : "p95", "color" : "#ff7f0e" }],
            ["...", { "stat" : "p99", "color" : "#d62728" }]
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
          title  = "Lambda Processor - Concurrency"
          region = data.aws_region.current.region
          metrics = [
            ["AWS/Lambda", "ConcurrentExecutions", "FunctionName", "${var.name_prefix}-processor", { "stat" : "Maximum", "color" : "#9467bd" }]
          ]
          period = 60
          view   = "timeSeries"
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 8
        height = 6
        properties = {
          title  = "📤 Outbox Publisher - Invocations"
          region = data.aws_region.current.region
          metrics = [
            ["AWS/Lambda", "Invocations", "FunctionName", "${var.name_prefix}-outbox-publisher", { "stat" : "Sum", "color" : "#2ca02c" }],
            [".", "Errors", ".", ".", { "stat" : "Sum", "color" : "#d62728" }]
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
          region = data.aws_region.current.region
          metrics = [
            ["AWS/SQS", "NumberOfMessagesSent", "QueueName", "${var.name_prefix}-file-processing", { "stat" : "Sum", "color" : "#2ca02c" }],
            [".", "NumberOfMessagesReceived", ".", ".", { "stat" : "Sum", "color" : "#1f77b4" }],
            [".", "ApproximateNumberOfMessagesVisible", ".", ".", { "stat" : "Average", "color" : "#ff7f0e" }]
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
          region = data.aws_region.current.region
          metrics = [
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", "${var.name_prefix}-dlq", { "stat" : "Sum", "color" : "#d62728" }],
            [".", "NumberOfMessagesSent", ".", ".", { "stat" : "Sum", "color" : "#ff7f0e" }]
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
      {
        type   = "metric"
        x      = 0
        y      = 12
        width  = 8
        height = 6
        properties = {
          title  = "💾 DynamoDB - Consumed Capacity"
          region = data.aws_region.current.region
          metrics = [
            ["AWS/DynamoDB", "ConsumedReadCapacityUnits", "TableName", "${var.name_prefix}-file-metadata", { "stat" : "Sum", "color" : "#1f77b4" }],
            [".", "ConsumedWriteCapacityUnits", ".", ".", { "stat" : "Sum", "color" : "#2ca02c" }]
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
          title  = "DynamoDB Outbox - Operations"
          region = data.aws_region.current.region
          metrics = [
            ["AWS/DynamoDB", "ConsumedReadCapacityUnits", "TableName", "${var.name_prefix}-outbox", { "stat" : "Sum", "color" : "#1f77b4" }],
            [".", "ConsumedWriteCapacityUnits", ".", ".", { "stat" : "Sum", "color" : "#2ca02c" }],
            [".", "TransactionConflict", ".", ".", { "stat" : "Sum", "color" : "#d62728" }]
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
          title  = "DynamoDB - Throttled Requests"
          region = data.aws_region.current.region
          metrics = [
            ["AWS/DynamoDB", "ThrottledRequests", "TableName", "${var.name_prefix}-file-metadata", { "stat" : "Sum", "color" : "#d62728" }],
            [".", "ThrottledRequests", "TableName", "${var.name_prefix}-outbox", { "stat" : "Sum", "color" : "#ff7f0e" }]
          ]
          period = 60
          view   = "timeSeries"
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 18
        width  = 8
        height = 6
        properties = {
          title  = "Files Processed"
          region = data.aws_region.current.region
          metrics = [
            ["FSAMP/Processor", "FilesProcessed", { "stat" : "Sum", "color" : "#2ca02c" }],
            [".", "FilesProcessedSuccess", { "stat" : "Sum", "color" : "#1f77b4" }],
            [".", "FilesProcessedFailed", { "stat" : "Sum", "color" : "#d62728" }]
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
          title  = "Processing Duration (Custom)"
          region = data.aws_region.current.region
          metrics = [
            ["FSAMP/Processor", "ProcessingDuration", { "stat" : "Average", "color" : "#1f77b4" }],
            ["...", { "stat" : "p95", "color" : "#ff7f0e" }],
            ["...", { "stat" : "p99", "color" : "#d62728" }]
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
          region = data.aws_region.current.region
          metrics = [
            ["FSAMP/OutboxPublisher", "EventsPublished", { "stat" : "Sum", "color" : "#2ca02c" }],
            [".", "EventsFailedToPublish", { "stat" : "Sum", "color" : "#d62728" }],
            [".", "EventsRetried", { "stat" : "Sum", "color" : "#ff7f0e" }]
          ]
          period = 60
          view   = "timeSeries"
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 24
        width  = 12
        height = 6
        properties = {
          title  = "S3 Bucket Metrics"
          region = data.aws_region.current.region
          metrics = [
            ["AWS/S3", "NumberOfObjects", "BucketName", "${var.name_prefix}-files", "StorageType", "AllStorageTypes", { "stat" : "Average", "period" : 86400 }],
            [".", "BucketSizeBytes", ".", ".", ".", ".", { "stat" : "Average", "period" : 86400 }]
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
          region = data.aws_region.current.region
          metrics = [
            ["AWS/SNS", "NumberOfMessagesPublished", "TopicName", "${var.name_prefix}-events", { "stat" : "Sum", "color" : "#2ca02c" }],
            [".", "NumberOfNotificationsFailed", ".", ".", { "stat" : "Sum", "color" : "#d62728" }]
          ]
          period = 60
          view   = "timeSeries"
        }
      },
      {
        type   = "log"
        x      = 0
        y      = 30
        width  = 24
        height = 6
        properties = {
          title  = "Recent Errors (All Services)"
          region = data.aws_region.current.region
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
      {
        type   = "metric"
        x      = 0
        y      = 36
        width  = 6
        height = 4
        properties = {
          title  = "Success Rate"
          region = data.aws_region.current.region
          metrics = [
            [{
              expression = "100 - 100 * errors / MAX([errors + invocations, 1])"
              label      = "Success %"
              id         = "e1"
              color      = "#2ca02c"
            }],
            ["AWS/Lambda", "Errors", "FunctionName", "${var.name_prefix}-processor", { "stat" : "Sum", "id" : "errors", "visible" : false }],
            [".", "Invocations", ".", ".", { "stat" : "Sum", "id" : "invocations", "visible" : false }]
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
          region = data.aws_region.current.region
          metrics = [
            ["AWS/Lambda", "Invocations", "FunctionName", "${var.name_prefix}-processor", { "stat" : "Sum", "color" : "#1f77b4" }]
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
          region = data.aws_region.current.region
          metrics = [
            ["AWS/Lambda", "Duration", "FunctionName", "${var.name_prefix}-processor", { "stat" : "Average", "color" : "#ff7f0e" }]
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
          region = data.aws_region.current.region
          metrics = [
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", "${var.name_prefix}-dlq", { "stat" : "Sum", "color" : "#d62728" }]
          ]
          period = 300
          view   = "singleValue"
        }
      }
    ]
  })
}
data "aws_region" "current" {}
resource "aws_cloudwatch_metric_alarm" "processor_errors" {
  count = var.enable_alarms ? 1 : 0

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

resource "aws_cloudwatch_metric_alarm" "outbox_publisher_errors" {
  count = var.enable_alarms ? 1 : 0

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

resource "aws_cloudwatch_metric_alarm" "dlq_messages" {
  count = var.enable_alarms ? 1 : 0

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

# DLQ messages must be drained before SQS retention expires (default 14 days)
# otherwise failed events vanish silently. (FedRAMP AU-2, CP-9)
resource "aws_cloudwatch_metric_alarm" "dlq_message_age" {
  count = var.enable_alarms ? 1 : 0

  alarm_name          = "${var.name_prefix}-dlq-message-age"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "ApproximateAgeOfOldestMessage"
  namespace           = "AWS/SQS"
  period              = 3600
  statistic           = "Maximum"
  threshold           = 86400 # 24h - well under 14d retention
  alarm_description   = "DLQ message older than 24h - failed event was not investigated and will be lost when SQS retention expires"
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = "${var.name_prefix}-dlq"
  }

  alarm_actions = var.alarm_sns_topic_arn != "" ? [var.alarm_sns_topic_arn] : []

  tags = merge(var.tags, {
    Name     = "${var.name_prefix}-dlq-message-age"
    Severity = "high"
  })
}

# Outbox publisher DLQ alarm: any message landing here means a DynamoDB
# Streams batch was permanently dropped after exhausting retries.
resource "aws_cloudwatch_metric_alarm" "outbox_publisher_dlq_messages" {
  count = var.enable_alarms ? 1 : 0

  alarm_name          = "${var.name_prefix}-outbox-publisher-dlq-messages"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 300
  statistic           = "Sum"
  threshold           = 0
  alarm_description   = "Outbox publisher DLQ has messages - DynamoDB Streams batch dropped after retries exhausted; outbox at-least-once guarantee compromised"
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = "${var.name_prefix}-outbox-publisher-dlq"
  }

  alarm_actions = var.alarm_sns_topic_arn != "" ? [var.alarm_sns_topic_arn] : []
  ok_actions    = var.alarm_sns_topic_arn != "" ? [var.alarm_sns_topic_arn] : []

  tags = merge(var.tags, {
    Name     = "${var.name_prefix}-outbox-publisher-dlq-messages"
    Severity = "critical"
  })
}

resource "aws_cloudwatch_metric_alarm" "processor_latency" {
  count = var.enable_alarms ? 1 : 0

  alarm_name          = "${var.name_prefix}-processor-high-latency"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "Duration"
  namespace           = "AWS/Lambda"
  period              = 300
  extended_statistic  = "p95"
  threshold           = 60000
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

resource "aws_cloudwatch_metric_alarm" "processor_throttles" {
  count = var.enable_alarms ? 1 : 0

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

resource "aws_cloudwatch_metric_alarm" "dynamodb_throttles" {
  count = var.enable_alarms ? 1 : 0

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

resource "aws_cloudwatch_metric_alarm" "sqs_backlog" {
  count = var.enable_alarms ? 1 : 0

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

resource "aws_cloudwatch_metric_alarm" "sqs_message_age" {
  count = var.enable_alarms ? 1 : 0

  alarm_name          = "${var.name_prefix}-sqs-message-age"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "ApproximateAgeOfOldestMessage"
  namespace           = "AWS/SQS"
  period              = 300
  statistic           = "Maximum"
  threshold           = 300
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

resource "aws_cloudwatch_metric_alarm" "gateway_5xx_target" {
  count = var.enable_alarms && var.gateway_alb_target_group_full_name != "" && var.gateway_alb_full_name != "" ? 1 : 0

  alarm_name          = "${var.name_prefix}-gateway-5xx"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "HTTPCode_Target_5XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = 300
  statistic           = "Sum"
  threshold           = 5
  alarm_description   = "Gateway service is returning HTTP 5xx responses through the ALB"
  treat_missing_data  = "notBreaching"

  dimensions = {
    TargetGroup  = var.gateway_alb_target_group_full_name
    LoadBalancer = var.gateway_alb_full_name
  }

  alarm_actions = var.alarm_sns_topic_arn != "" ? [var.alarm_sns_topic_arn] : []
  ok_actions    = var.alarm_sns_topic_arn != "" ? [var.alarm_sns_topic_arn] : []

  tags = merge(var.tags, {
    Name     = "${var.name_prefix}-gateway-5xx"
    Severity = "critical"
  })
}

resource "aws_cloudwatch_metric_alarm" "gateway_5xx_alb" {
  count = var.enable_alarms && var.gateway_alb_full_name != "" ? 1 : 0

  alarm_name          = "${var.name_prefix}-gateway-alb-5xx"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "HTTPCode_ELB_5XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = 300
  statistic           = "Sum"
  threshold           = 5
  alarm_description   = "ALB-side HTTP 5xx responses (load balancer cannot route to a healthy target)"
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = var.gateway_alb_full_name
  }

  alarm_actions = var.alarm_sns_topic_arn != "" ? [var.alarm_sns_topic_arn] : []
  ok_actions    = var.alarm_sns_topic_arn != "" ? [var.alarm_sns_topic_arn] : []

  tags = merge(var.tags, {
    Name     = "${var.name_prefix}-gateway-alb-5xx"
    Severity = "critical"
  })
}

# Publish failures are emitted by the outbox publisher itself. DynamoDB
# consumed capacity is not used as an event counter.
resource "aws_cloudwatch_metric_alarm" "outbox_publish_failures" {
  count = var.enable_alarms && var.outbox_table_name != "" ? 1 : 0

  alarm_name          = "${var.name_prefix}-outbox-publish-failures"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  threshold           = 0
  alarm_description   = "Outbox publisher reported failed publish or retry attempts"
  treat_missing_data  = "notBreaching"

  metric_query {
    id          = "total_failures"
    expression  = "FILL(publish_failures, 0) + FILL(retry_failures, 0)"
    label       = "Outbox Publish Failures"
    return_data = true
  }

  metric_query {
    id = "publish_failures"
    metric {
      metric_name = "EventsFailedToPublish"
      namespace   = "FSAMP/OutboxPublisher"
      period      = 300
      stat        = "Sum"
    }
  }

  metric_query {
    id = "retry_failures"
    metric {
      metric_name = "EventsRetryFailed"
      namespace   = "FSAMP/OutboxPublisher"
      period      = 300
      stat        = "Sum"
    }
  }

  alarm_actions = var.alarm_sns_topic_arn != "" ? [var.alarm_sns_topic_arn] : []
  ok_actions    = var.alarm_sns_topic_arn != "" ? [var.alarm_sns_topic_arn] : []

  tags = merge(var.tags, {
    Name     = "${var.name_prefix}-outbox-publish-failures"
    Severity = "high"
  })
}

resource "aws_cloudwatch_composite_alarm" "critical_health" {
  count = var.enable_alarms ? 1 : 0

  alarm_name = "${var.name_prefix}-critical-health"

  alarm_rule = join(" OR ", concat(
    [
      "ALARM(${aws_cloudwatch_metric_alarm.dlq_messages[0].alarm_name})",
      "ALARM(${aws_cloudwatch_metric_alarm.outbox_publisher_dlq_messages[0].alarm_name})",
      "ALARM(${aws_cloudwatch_metric_alarm.processor_errors[0].alarm_name})",
      "ALARM(${aws_cloudwatch_metric_alarm.outbox_publisher_errors[0].alarm_name})",
    ],
    [for a in aws_cloudwatch_metric_alarm.gateway_5xx_target : "ALARM(${a.alarm_name})"],
    [for a in aws_cloudwatch_metric_alarm.gateway_5xx_alb : "ALARM(${a.alarm_name})"],
    [for a in aws_cloudwatch_metric_alarm.outbox_publish_failures : "ALARM(${a.alarm_name})"],
  ))

  alarm_description = "CRITICAL: FSAMP system health degraded - requires immediate attention"

  alarm_actions = var.alarm_sns_topic_arn != "" ? [var.alarm_sns_topic_arn] : []
  ok_actions    = var.alarm_sns_topic_arn != "" ? [var.alarm_sns_topic_arn] : []

  tags = merge(var.tags, {
    Name     = "${var.name_prefix}-critical-health"
    Severity = "critical"
  })
}
