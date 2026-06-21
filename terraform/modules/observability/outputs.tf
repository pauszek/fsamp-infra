output "log_group_names" {
  description = "Map of service to log group names"
  value = {
    ecs         = "/ecs/${var.name_prefix}"
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
  value       = "https://${data.aws_region.current.region}.console.aws.amazon.com/cloudwatch/home?region=${data.aws_region.current.region}#dashboards:name=${aws_cloudwatch_dashboard.main.dashboard_name}"
}

output "alarm_arns" {
  description = "Map of alarm names to ARNs"
  value = {
    processor_errors              = try(aws_cloudwatch_metric_alarm.processor_errors[0].arn, null)
    outbox_publisher_errors       = try(aws_cloudwatch_metric_alarm.outbox_publisher_errors[0].arn, null)
    dlq_messages                  = try(aws_cloudwatch_metric_alarm.dlq_messages[0].arn, null)
    dlq_message_age               = try(aws_cloudwatch_metric_alarm.dlq_message_age[0].arn, null)
    outbox_publisher_dlq_messages = try(aws_cloudwatch_metric_alarm.outbox_publisher_dlq_messages[0].arn, null)
    processor_latency             = try(aws_cloudwatch_metric_alarm.processor_latency[0].arn, null)
    processor_throttles           = try(aws_cloudwatch_metric_alarm.processor_throttles[0].arn, null)
    dynamodb_throttles            = try(aws_cloudwatch_metric_alarm.dynamodb_throttles[0].arn, null)
    sqs_backlog                   = try(aws_cloudwatch_metric_alarm.sqs_backlog[0].arn, null)
    sqs_message_age               = try(aws_cloudwatch_metric_alarm.sqs_message_age[0].arn, null)
    gateway_5xx_target            = try(aws_cloudwatch_metric_alarm.gateway_5xx_target[0].arn, null)
    gateway_5xx_alb               = try(aws_cloudwatch_metric_alarm.gateway_5xx_alb[0].arn, null)
    outbox_publish_failures       = try(aws_cloudwatch_metric_alarm.outbox_publish_failures[0].arn, null)
    critical_health               = try(aws_cloudwatch_composite_alarm.critical_health[0].arn, null)
  }
}
