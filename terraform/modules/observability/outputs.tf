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
    processor_errors              = aws_cloudwatch_metric_alarm.processor_errors.arn
    outbox_publisher_errors       = aws_cloudwatch_metric_alarm.outbox_publisher_errors.arn
    dlq_messages                  = aws_cloudwatch_metric_alarm.dlq_messages.arn
    dlq_message_age               = aws_cloudwatch_metric_alarm.dlq_message_age.arn
    outbox_publisher_dlq_messages = aws_cloudwatch_metric_alarm.outbox_publisher_dlq_messages.arn
    processor_latency             = aws_cloudwatch_metric_alarm.processor_latency.arn
    processor_throttles           = aws_cloudwatch_metric_alarm.processor_throttles.arn
    dynamodb_throttles            = aws_cloudwatch_metric_alarm.dynamodb_throttles.arn
    sqs_backlog                   = aws_cloudwatch_metric_alarm.sqs_backlog.arn
    sqs_message_age               = aws_cloudwatch_metric_alarm.sqs_message_age.arn
    gateway_5xx_target            = try(aws_cloudwatch_metric_alarm.gateway_5xx_target[0].arn, null)
    gateway_5xx_alb               = try(aws_cloudwatch_metric_alarm.gateway_5xx_alb[0].arn, null)
    outbox_publish_failures       = try(aws_cloudwatch_metric_alarm.outbox_publish_failures[0].arn, null)
    critical_health               = aws_cloudwatch_composite_alarm.critical_health.arn
  }
}
