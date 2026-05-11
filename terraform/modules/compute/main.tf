# =============================================================================
# Compute Module - ECS Fargate, Lambda
# =============================================================================
# Serverless compute for FSAMP services
# =============================================================================

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.44.0, < 7.0.0"
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

variable "log_group_name" {
  description = "CloudWatch log group name for ECS"
  type        = string
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
  description = "Use FIPS 140-3 validated endpoints (us-* regions only)"
  type        = bool
  default     = true
}

variable "gateway_image" {
  description = "Docker image for gateway service (ECR URI)"
  type        = string
  # No default - must be provided per environment
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
  default     = "" # Falls back to processor_image when empty
}

variable "gateway_cpu" {
  description = "CPU units for gateway task"
  type        = number
  default     = 256
}

variable "gateway_memory" {
  description = "Memory (MB) for gateway task"
  type        = number
  default     = 512
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

variable "outbox_stream_arn" {
  description = "DynamoDB Streams ARN for outbox table"
  type        = string
  default     = ""
}

# =============================================================================
# ECS Cluster
# =============================================================================

resource "aws_ecs_cluster" "main" {
  name = "${var.name_prefix}-cluster"

  setting {
    name  = "containerInsights"
    value = var.enable_container_insights ? "enabled" : "disabled"
  }

  configuration {
    execute_command_configuration {
      kms_key_id = var.kms_key_arn
      logging    = "OVERRIDE"

      log_configuration {
        cloud_watch_encryption_enabled = true
        cloud_watch_log_group_name     = var.log_group_name
      }
    }
  }

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-cluster"
  })
}

resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name = aws_ecs_cluster.main.name

  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    base              = 1
    weight            = 100
    capacity_provider = "FARGATE"
  }
}

# =============================================================================
# Internal ALB - Gateway Private Backend
# =============================================================================

resource "aws_lb" "gateway" {
  name               = "${var.name_prefix}-gateway-alb"
  internal           = true
  load_balancer_type = "application"
  security_groups    = [var.alb_security_group_id]
  subnets            = var.subnet_ids

  enable_deletion_protection = var.environment == "prod"
  drop_invalid_header_fields = true

  tags = merge(var.tags, {
    Name    = "${var.name_prefix}-gateway-alb"
    Service = "gateway"
  })
}

resource "aws_lb_target_group" "gateway" {
  name        = "${var.name_prefix}-gateway-tg"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    enabled             = true
    path                = "/actuator/health"
    protocol            = "HTTP"
    matcher             = "200-399"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = merge(var.tags, {
    Name    = "${var.name_prefix}-gateway-tg"
    Service = "gateway"
  })
}

resource "aws_lb_listener" "gateway" {
  load_balancer_arn = aws_lb.gateway.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.gateway.arn
  }

  tags = merge(var.tags, {
    Name    = "${var.name_prefix}-gateway-listener"
    Service = "gateway"
  })
}

# =============================================================================
# ECS Task Definition - Gateway
# =============================================================================

resource "aws_ecs_task_definition" "gateway" {
  family                   = "${var.name_prefix}-gateway"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.gateway_cpu
  memory                   = var.gateway_memory
  execution_role_arn       = var.ecs_execution_role_arn
  task_role_arn            = var.ecs_task_role_arn

  container_definitions = jsonencode([
    {
      name  = "gateway"
      image = var.gateway_image

      portMappings = [
        {
          containerPort = 8080
          hostPort      = 8080
          protocol      = "tcp"
        }
      ]

      environment = [
        {
          name  = "SPRING_PROFILES_ACTIVE"
          value = var.environment
        },
        {
          name  = "AWS_REGION"
          value = var.aws_region
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = var.log_group_name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "gateway"
        }
      }

      healthCheck = {
        command     = ["CMD-SHELL", "curl -f http://localhost:8080/actuator/health || exit 1"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 60
      }
    }
  ])

  tags = merge(var.tags, {
    Name    = "${var.name_prefix}-gateway"
    Service = "gateway"
  })
}

# =============================================================================
# ECS Service - Gateway
# =============================================================================

resource "aws_ecs_service" "gateway" {
  name            = "${var.name_prefix}-gateway"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.gateway.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.subnet_ids
    security_groups  = [var.security_group_id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.gateway.arn
    container_name   = "gateway"
    container_port   = 8080
  }

  deployment_maximum_percent         = 200
  deployment_minimum_healthy_percent = 100
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }
  tags = merge(var.tags, {
    Name    = "${var.name_prefix}-gateway"
    Service = "gateway"
  })

  lifecycle {
    ignore_changes = [desired_count]
  }

  depends_on = [aws_lb_listener.gateway]
}

# =============================================================================
# Lambda Function - Processor
# =============================================================================

locals {
  processor_env_vars = {
    ENVIRONMENT                  = var.environment
    AWS_REGION                   = var.aws_region
    LOG_LEVEL                    = var.environment == "prod" ? "INFO" : "DEBUG"
    LOG_FORMAT                   = "json"
    POWERTOOLS_SERVICE_NAME      = "fsamp-processor"
    POWERTOOLS_METRICS_NAMESPACE = "FSAMP/Processor"
    POWERTOOLS_LOG_LEVEL         = var.environment == "prod" ? "INFO" : "DEBUG"
    USE_FIPS_ENDPOINT            = var.environment == "local" ? "false" : tostring(var.use_fips_endpoint)
    FIPS_REQUIRED                = var.environment == "local" ? "false" : "true"

    # Resource configuration (set by CI/CD or locals)
    SQS_QUEUE_URL       = var.sqs_queue_url
    SNS_TOPIC_ARN       = var.sns_topic_arn
    S3_BUCKET_NAME      = var.s3_bucket_name
    DYNAMODB_TABLE_NAME = var.dynamodb_table_name
    OUTBOX_TABLE_NAME   = var.outbox_table_name
    KMS_KEY_ID          = var.kms_key_arn
  }

  outbox_publisher_env_vars = {
    ENVIRONMENT                  = var.environment
    AWS_REGION                   = var.aws_region
    POWERTOOLS_SERVICE_NAME      = "outbox-publisher"
    POWERTOOLS_METRICS_NAMESPACE = "FSAMP/OutboxPublisher"
    POWERTOOLS_LOG_LEVEL         = var.environment == "prod" ? "INFO" : "DEBUG"
    SNS_TOPIC_ARN                = var.sns_topic_arn
    OUTBOX_TABLE_NAME            = var.outbox_table_name
    MAX_RETRY_COUNT              = "3"
    USE_FIPS_ENDPOINT            = var.environment == "local" ? "false" : tostring(var.use_fips_endpoint)
    FIPS_REQUIRED                = var.environment == "local" ? "false" : "true"
  }

  processor_ecs_env_list = [
    for k, v in local.processor_env_vars : {
      name  = k
      value = v
    }
  ]
}

# =============================================================================
# ECS Task Definition - Processor (Production)
# =============================================================================

resource "aws_ecs_task_definition" "processor" {
  count = var.enable_processor_ecs ? 1 : 0

  family                   = "${var.name_prefix}-processor"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.processor_ecs_cpu
  memory                   = var.processor_ecs_memory
  execution_role_arn       = var.ecs_execution_role_arn
  task_role_arn            = var.ecs_task_role_arn

  container_definitions = jsonencode([
    {
      name  = "processor"
      image = var.processor_image

      environment = local.processor_ecs_env_list

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = var.log_group_name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "processor"
        }
      }
    }
  ])

  tags = merge(var.tags, {
    Name    = "${var.name_prefix}-processor"
    Service = "processor"
  })

  depends_on = [
    aws_cloudwatch_log_group.processor
  ]
}

# =============================================================================
# ECS Service - Processor
# =============================================================================

resource "aws_ecs_service" "processor" {
  count = var.enable_processor_ecs ? 1 : 0

  name            = "${var.name_prefix}-processor"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.processor[0].arn
  desired_count   = var.processor_desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.subnet_ids
    security_groups  = [var.security_group_id]
    assign_public_ip = false
  }

  deployment_maximum_percent         = 200
  deployment_minimum_healthy_percent = 100

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  tags = merge(var.tags, {
    Name    = "${var.name_prefix}-processor"
    Service = "processor"
  })

  lifecycle {
    ignore_changes = [desired_count]
  }
}

resource "aws_lambda_function" "processor" {
  # checkov:skip=CKV_AWS_272: Code signing is documented as a production hardening extension; thesis demo images are already gated by CI scanning/SBOM.
  function_name = "${var.name_prefix}-processor"
  role          = var.lambda_role_arn
  timeout       = var.processor_timeout
  memory_size   = var.processor_memory

  # Container image deployment — FIPS 140-3 OpenSSL provider baked in
  package_type = "Image"
  image_uri    = var.processor_image

  # Architecture - ARM64 is cheaper and faster for Python
  architectures = ["arm64"]

  # Override CMD from Dockerfile if needed (handler path)
  image_config {
    command = ["processor.lambda_handler.lambda_handler"]
  }

  environment {
    variables = local.processor_env_vars
  }

  # KMS encryption for environment variables
  kms_key_arn = var.kms_key_arn

  # X-Ray distributed tracing
  tracing_config {
    mode = "Active"
  }

  # Dead letter queue for failed invocations
  dead_letter_config {
    target_arn = var.dlq_arn
  }

  reserved_concurrent_executions = var.environment == "prod" ? 100 : 10

  vpc_config {
    subnet_ids         = var.subnet_ids
    security_group_ids = [var.lambda_security_group_id]
  }

  tags = merge(var.tags, {
    Name    = "${var.name_prefix}-processor"
    Service = "processor"
  })
}

resource "aws_cloudwatch_log_group" "processor" {
  name              = "/aws/lambda/${var.name_prefix}-processor"
  retention_in_days = 365
  kms_key_id        = var.kms_key_arn

  tags = var.tags
}

# =============================================================================
# SQS Trigger for Lambda (Event Source Mapping)
# =============================================================================
resource "aws_lambda_event_source_mapping" "sqs_trigger" {
  event_source_arn                   = var.sqs_queue_arn
  function_name                      = aws_lambda_function.processor.arn
  batch_size                         = 10
  maximum_batching_window_in_seconds = 5

  # Enable partial batch response for better error handling
  function_response_types = ["ReportBatchItemFailures"]

  # Scaling configuration
  scaling_config {
    maximum_concurrency = var.environment == "prod" ? 50 : 10
  }

  # Filter events (optional - only process specific event types)
  # filter_criteria {
  #   filter {
  #     pattern = jsonencode({
  #       body = {
  #         event_type = ["FILE_UPLOADED", "FILE_SCANNED"]
  #       }
  #     })
  #   }
  # }
}

# =============================================================================
# Lambda Function - Outbox Publisher (Transactional Outbox Pattern)
# =============================================================================
# Triggered by DynamoDB Streams when new events are written to the outbox table.
# Publishes events to SNS and marks them as published.
# =============================================================================

resource "aws_lambda_function" "outbox_publisher" {
  # checkov:skip=CKV_AWS_272: Code signing is documented as a production hardening extension; thesis demo images are already gated by CI scanning/SBOM.
  function_name = "${var.name_prefix}-outbox-publisher"
  role          = var.lambda_role_arn
  timeout       = 60
  memory_size   = 256

  # Container image deployment — same FIPS image, different handler
  package_type = "Image"
  image_uri    = coalesce(var.outbox_publisher_image, var.processor_image)

  # ARM64 architecture
  architectures = ["arm64"]

  # Override CMD to point at outbox publisher handler
  image_config {
    command = ["processor.outbox_publisher.lambda_handler"]
  }

  environment {
    variables = local.outbox_publisher_env_vars
  }

  # KMS encryption for environment variables
  kms_key_arn = var.kms_key_arn

  # X-Ray distributed tracing
  tracing_config {
    mode = "Active"
  }

  reserved_concurrent_executions = var.environment == "prod" ? 20 : 5

  vpc_config {
    subnet_ids         = var.subnet_ids
    security_group_ids = [var.lambda_security_group_id]
  }

  tags = merge(var.tags, {
    Name    = "${var.name_prefix}-outbox-publisher"
    Service = "outbox-publisher"
    Pattern = "transactional-outbox"
  })

  depends_on = [
    aws_cloudwatch_log_group.outbox_publisher
  ]
}

# CloudWatch Log Group for Outbox Publisher
resource "aws_cloudwatch_log_group" "outbox_publisher" {
  name              = "/aws/lambda/${var.name_prefix}-outbox-publisher"
  retention_in_days = 365
  kms_key_id        = var.kms_key_arn

  tags = var.tags
}

# =============================================================================
# DynamoDB Streams Event Source Mapping for Outbox Publisher
# =============================================================================
resource "aws_lambda_event_source_mapping" "outbox_stream" {
  count = var.outbox_stream_arn != "" ? 1 : 0

  event_source_arn  = var.outbox_stream_arn
  function_name     = aws_lambda_function.outbox_publisher.arn
  batch_size        = 100
  starting_position = "LATEST"

  # Enable partial batch response for better error handling
  function_response_types = ["ReportBatchItemFailures"]

  # Maximum age of records to process (24 hours)
  maximum_record_age_in_seconds = 86400

  # Maximum retry attempts for failed records
  maximum_retry_attempts = 3

  # Bisect batch on function error (helps isolate bad records)
  bisect_batch_on_function_error = true

  # Parallelization factor (process multiple batches concurrently)
  parallelization_factor = 2

  # Filter to only process INSERT events (new outbox items)
  filter_criteria {
    filter {
      pattern = jsonencode({
        eventName = ["INSERT"]
      })
    }
  }

  # Destination for failed records (optional - send to DLQ)
  # destination_config {
  #   on_failure {
  #     destination_arn = var.dlq_arn
  #   }
  # }
}

# =============================================================================
# Auto Scaling for ECS
# =============================================================================

resource "aws_appautoscaling_target" "gateway" {
  max_capacity       = 4
  min_capacity       = 1
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.gateway.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "gateway_cpu" {
  name               = "${var.name_prefix}-gateway-cpu-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.gateway.resource_id
  scalable_dimension = aws_appautoscaling_target.gateway.scalable_dimension
  service_namespace  = aws_appautoscaling_target.gateway.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
    target_value       = 70.0
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
  }
}

resource "aws_appautoscaling_policy" "gateway_memory" {
  name               = "${var.name_prefix}-gateway-memory-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.gateway.resource_id
  scalable_dimension = aws_appautoscaling_target.gateway.scalable_dimension
  service_namespace  = aws_appautoscaling_target.gateway.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageMemoryUtilization"
    }
    target_value       = 70.0
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
  }
}

# =============================================================================
# Outputs
# =============================================================================

output "ecs_cluster_arn" {
  description = "ARN of the ECS cluster"
  value       = aws_ecs_cluster.main.arn
}

output "ecs_cluster_name" {
  description = "Name of the ECS cluster"
  value       = aws_ecs_cluster.main.name
}

output "gateway_task_definition_arn" {
  description = "ARN of the gateway task definition"
  value       = aws_ecs_task_definition.gateway.arn
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

output "gateway_alb_dns_name" {
  description = "DNS name of the internal Gateway ALB"
  value       = aws_lb.gateway.dns_name
}

output "gateway_alb_listener_arn" {
  description = "ARN of the internal Gateway ALB listener"
  value       = aws_lb_listener.gateway.arn
}

output "processor_lambda_arn" {
  description = "ARN of the processor Lambda function"
  value       = aws_lambda_function.processor.arn
}

output "processor_lambda_name" {
  description = "Name of the processor Lambda function"
  value       = aws_lambda_function.processor.function_name
}

output "outbox_publisher_lambda_arn" {
  description = "ARN of the outbox publisher Lambda function"
  value       = aws_lambda_function.outbox_publisher.arn
}

output "outbox_publisher_lambda_name" {
  description = "Name of the outbox publisher Lambda function"
  value       = aws_lambda_function.outbox_publisher.function_name
}
