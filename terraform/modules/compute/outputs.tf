output "ecs_cluster_arn" {
  description = "ARN of the ECS cluster"
  value       = aws_ecs_cluster.main.arn
}

output "ecs_cluster_name" {
  description = "Name of the ECS cluster"
  value       = aws_ecs_cluster.main.name
}

output "gateway_service_name" {
  description = "Name of the gateway ECS service"
  value       = aws_ecs_service.gateway.name
}

output "processor_task_definition_arn" {
  description = "ARN of the processor ECS task definition"
  value       = var.enable_processor_ecs ? aws_ecs_task_definition.processor[0].arn : null
}

output "processor_service_name" {
  description = "Name of the processor ECS service"
  value       = var.enable_processor_ecs ? aws_ecs_service.processor[0].name : null
}

output "gateway_alb_arn" {
  description = "ARN of the internal Gateway ALB"
  value       = aws_lb.gateway.arn
}

output "gateway_alb_arn_suffix" {
  description = "ARN suffix of the internal Gateway ALB (e.g. app/<name>/<id>) used for CloudWatch ALB metrics"
  value       = aws_lb.gateway.arn_suffix
}

output "gateway_alb_target_group_arn_suffix" {
  description = "ARN suffix of the gateway ALB target group used for CloudWatch ALB metrics"
  value       = aws_lb_target_group.gateway.arn_suffix
}

output "gateway_alb_dns_name" {
  description = "DNS name of the internal Gateway ALB"
  value       = aws_lb.gateway.dns_name
}

output "processor_lambda_arn" {
  description = "ARN of the processor Lambda function"
  value       = var.enable_lambdas ? aws_lambda_function.processor[0].arn : null
}

output "processor_lambda_name" {
  description = "Name of the processor Lambda function"
  value       = var.enable_lambdas ? aws_lambda_function.processor[0].function_name : null
}

output "outbox_publisher_lambda_arn" {
  description = "ARN of the outbox publisher Lambda function"
  value       = var.enable_lambdas ? aws_lambda_function.outbox_publisher[0].arn : null
}

output "outbox_publisher_lambda_name" {
  description = "Name of the outbox publisher Lambda function"
  value       = var.enable_lambdas ? aws_lambda_function.outbox_publisher[0].function_name : null
}

output "outbox_retry_lambda_arn" {
  description = "ARN of the scheduled outbox reconciliation Lambda function"
  value       = var.enable_lambdas ? aws_lambda_function.outbox_retry[0].arn : null
}

output "outbox_retry_lambda_name" {
  description = "Name of the scheduled outbox reconciliation Lambda function"
  value       = var.enable_lambdas ? aws_lambda_function.outbox_retry[0].function_name : null
}

output "gateway_endpoint_host" {
  description = "Host the API Gateway integrations use to reach the ALB: the Route53 domain in acm mode, the ALB DNS name otherwise"
  value       = local.use_acm_cert ? var.alb_domain_name : aws_lb.gateway.dns_name
}

output "alb_tls_verified" {
  description = "True when the ALB presents a DNS-validated ACM certificate (integrations enforce verification)"
  value       = local.use_acm_cert
}
