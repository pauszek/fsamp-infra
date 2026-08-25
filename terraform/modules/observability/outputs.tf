output "log_group_names" {
  description = "Map of service to log group names"
  value = {
    ecs                    = "/ecs/${var.name_prefix}"
    processor_lambda       = "/aws/lambda/${var.name_prefix}-processor"
    outbox_lambda          = "/aws/lambda/${var.name_prefix}-outbox-publisher"
    outbox_retry_lambda    = "/aws/lambda/${var.name_prefix}-outbox-retry"
    api_gateway_access_log = "/aws/apigateway/${var.name_prefix}-access-logs"
  }
}
