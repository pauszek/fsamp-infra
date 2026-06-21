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

variable "ecs_task_role_arn" {
  description = "ARN of the ECS task role"
  type        = string
}

variable "ecs_execution_role_arn" {
  description = "ARN of the ECS execution role"
  type        = string
}

variable "lambda_role_arn" {
  description = "ARN of the Lambda execution role"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID for ECS"
  type        = string
}

variable "subnet_ids" {
  description = "Subnet IDs for ECS tasks"
  type        = list(string)
}

variable "security_group_id" {
  description = "Security group ID for ECS tasks"
  type        = string
}

variable "lambda_security_group_id" {
  description = "Security group ID for Lambda functions"
  type        = string
}

variable "alb_security_group_id" {
  description = "Security group ID for the internal Gateway ALB"
  type        = string
}

variable "alb_tls_enabled" {
  description = "Terminate TLS with the AWS FIPS security policy on the internal gateway ALB listener (SC-8/SC-13). Rollback lever only; keep enabled in all AWS environments."
  type        = bool
  default     = true
}

variable "log_group_name" {
  description = "CloudWatch log group name for ECS"
  type        = string
}

variable "log_retention_days" {
  description = "CloudWatch log retention in days for ECS task logs"
  type        = number
  default     = 365
}

variable "sqs_queue_arn" {
  description = "SQS queue ARN for Lambda trigger"
  type        = string
}

variable "dlq_arn" {
  description = "Dead letter queue ARN for Lambda"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-west-2"
}

variable "use_fips_endpoint" {
  description = "Use AWS FIPS endpoints in the us-west-2 deployment baseline"
  type        = bool
  default     = true
}

variable "localstack_internal_endpoint" {
  description = "LocalStack endpoint URL visible from LocalStack-managed ECS/Lambda containers. Empty outside local parity runs."
  type        = string
  default     = ""
}

variable "gateway_image" {
  description = "Docker image for gateway service (ECR URI)"
  type        = string
}

variable "sqs_queue_url" {
  description = "SQS queue URL for processor environment"
  type        = string
  default     = ""
}

variable "sns_topic_arn" {
  description = "SNS topic ARN for processor events"
  type        = string
  default     = ""
}

variable "file_events_topic_arn" {
  description = "SNS topic ARN for gateway FILE_UPLOADED events"
  type        = string
  default     = ""
}

variable "s3_bucket_name" {
  description = "S3 bucket name for processor file storage"
  type        = string
  default     = ""
}

variable "dynamodb_table_name" {
  description = "DynamoDB table name for processor metadata"
  type        = string
  default     = ""
}

variable "processor_image" {
  description = "ECR image URI for processor Lambda (container image deployment)"
  type        = string
}

variable "outbox_publisher_image" {
  description = "ECR image URI for outbox publisher Lambda (container image deployment)"
  type        = string
  default     = ""
}

variable "gateway_cpu" {
  description = "CPU units for gateway task. Spring Boot 3.5 with ACCP and BC-FIPS providers needs at least 512 to start within reasonable time."
  type        = number
  default     = 512

  validation {
    condition     = contains([256, 512, 1024, 2048, 4096], var.gateway_cpu)
    error_message = "Fargate gateway_cpu must be one of 256, 512, 1024, 2048, 4096."
  }
}

variable "gateway_memory" {
  description = "Memory (MB) for gateway task. Java 21 + Spring Boot + Tika + AWS SDK v2 typically needs 1024 MB minimum to avoid OOM during cold start under load."
  type        = number
  default     = 1024

  validation {
    condition     = var.gateway_memory >= 512
    error_message = "Fargate gateway_memory must be at least 512 MB; values below 1024 are likely to cause OOM with the FIPS provider stack."
  }
}

variable "processor_memory" {
  description = "Memory (MB) for processor Lambda"
  type        = number
  default     = 512
}

variable "processor_timeout" {
  description = "Timeout (seconds) for processor Lambda"
  type        = number
  default     = 300
}

variable "processor_ecs_cpu" {
  description = "CPU units for processor ECS task"
  type        = number
  default     = 256
}

variable "processor_ecs_memory" {
  description = "Memory (MB) for processor ECS task"
  type        = number
  default     = 512
}

variable "processor_desired_count" {
  description = "Desired count for processor ECS service"
  type        = number
  default     = 1
}

variable "enable_processor_ecs" {
  description = "Enable optional ECS/Fargate processor service. Core runtime uses Lambda processor."
  type        = bool
  default     = false
}

variable "enable_container_insights" {
  description = "Enable CloudWatch Container Insights for ECS"
  type        = bool
  default     = true
}

variable "outbox_table_name" {
  description = "DynamoDB outbox table name"
  type        = string
  default     = ""
}

variable "idempotency_table_name" {
  description = "DynamoDB idempotency table name for gateway retries"
  type        = string
  default     = ""
}

variable "cognito_user_pool_id" {
  description = "Cognito User Pool ID for gateway JWT validation"
  type        = string
  default     = ""
}

variable "cognito_client_id" {
  description = "Cognito web client ID for gateway JWT audience validation"
  type        = string
  default     = ""
}

variable "outbox_stream_arn" {
  description = "DynamoDB Streams ARN for outbox table"
  type        = string
  default     = ""
}

variable "outbox_publisher_dlq_arn" {
  description = "ARN of the SQS queue that receives outbox publisher batches that exhaust their retry budget. Required by the transactional outbox at-least-once guarantee."
  type        = string
  default     = ""
}

variable "enable_lambdas" {
  description = "Create the processor and outbox-publisher container Lambdas. Disable locally until images exist in the local ECR."
  type        = bool
  default     = true
}

variable "alb_certificate_mode" {
  description = "Certificate for the ALB TLS listener: 'self-signed' (Terraform-managed, imported into ACM; documented SC-23 exception) or 'acm' (DNS-validated ACM certificate with a Route53 zone for alb_domain_name)."
  type        = string
  default     = "self-signed"

  validation {
    condition     = contains(["self-signed", "acm"], var.alb_certificate_mode)
    error_message = "alb_certificate_mode must be 'self-signed' or 'acm'."
  }
}

variable "alb_domain_name" {
  description = "Domain for the ALB certificate and Route53 alias when alb_certificate_mode = 'acm'."
  type        = string
  default     = null
}
