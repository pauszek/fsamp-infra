terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.44.0, < 7.0.0"
    }
  }
}
resource "aws_cloudwatch_log_group" "ecs" {
  name              = var.log_group_name
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn

  tags = merge(var.tags, {
    Name        = var.log_group_name
    Environment = var.environment
  })
}

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

  depends_on = [aws_cloudwatch_log_group.ecs]
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

      environment = local.gateway_env_list

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

  depends_on = [aws_cloudwatch_log_group.ecs]
}
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
locals {
  gateway_env_vars = {
    SPRING_PROFILES_ACTIVE = var.environment
    AWS_REGION             = var.aws_region
    AWS_FIPS_ENDPOINTS     = var.environment == "local" ? "false" : tostring(var.use_fips_endpoint)
    AWS_USE_FIPS_ENDPOINT  = var.environment == "local" ? "false" : tostring(var.use_fips_endpoint)
    FIPS_APPROVED_ONLY     = "true"
    FSAMP_FIPS_ENABLED     = var.environment == "local" ? "false" : "true"

    COGNITO_USER_POOL_ID = var.cognito_user_pool_id
    COGNITO_CLIENT_ID    = var.cognito_client_id

    KMS_KEY_ID     = var.kms_key_arn
    AWS_KMS_KEY_ID = var.kms_key_arn

    S3_BUCKET_NAME     = var.s3_bucket_name
    AWS_S3_BUCKET_NAME = var.s3_bucket_name

    SNS_FILE_EVENTS_TOPIC_ARN     = var.file_events_topic_arn
    AWS_SNS_FILE_EVENTS_TOPIC_ARN = var.file_events_topic_arn

    DYNAMODB_TABLE_NAME                      = var.dynamodb_table_name
    AWS_DYNAMODB_TABLE_NAME                  = var.dynamodb_table_name
    OUTBOX_TABLE_NAME                        = var.outbox_table_name
    AWS_DYNAMODB_OUTBOX_TABLE_NAME           = var.outbox_table_name
    DYNAMODB_IDEMPOTENCY_TABLE_NAME          = var.idempotency_table_name
    AWS_DYNAMODB_IDEMPOTENCY_TABLE_NAME      = var.idempotency_table_name
    DIRECT_PUBLISH_AFTER_OUTBOX              = "false"
    AWS_DYNAMODB_DIRECT_PUBLISH_AFTER_OUTBOX = "false"
  }

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
    PUBLISH_CLAIM_TTL_SECONDS    = "300"
    USE_FIPS_ENDPOINT            = var.environment == "local" ? "false" : tostring(var.use_fips_endpoint)
    FIPS_REQUIRED                = var.environment == "local" ? "false" : "true"
  }

  processor_ecs_env_list = [
    for k, v in local.processor_env_vars : {
      name  = k
      value = v
    }
  ]

  gateway_env_list = [
    for k, v in local.gateway_env_vars : {
      name  = k
      value = v
    }
  ]
}
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

  depends_on = [aws_cloudwatch_log_group.ecs]
}
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
  # Container-image Lambdas cannot use AWS Signer code signing profiles
  # (CKV_AWS_272) because that feature is restricted to ZIP-based functions.
  # Supply-chain integrity is therefore enforced one layer down:
  #   - ECR repositories run with image_tag_mutability=IMMUTABLE so tags
  #     cannot be re-pushed once published.
  #   - All images are signed keyless with cosign and Sigstore Fulcio in
  #     the build pipeline; the Lambda execution role only has read access
  #     to the FSAMP-owned ECR registry.
  #   - Inspector enhanced continuous scanning (FedRAMP RA-5) covers the
  #     image after deployment.
  # checkov:skip=CKV_AWS_272: Container Lambdas use cosign + ECR immutable tags + Inspector enhanced scanning instead.
  function_name = "${var.name_prefix}-processor"
  role          = var.lambda_role_arn
  timeout       = var.processor_timeout
  memory_size   = var.processor_memory

  package_type = "Image"
  image_uri    = var.processor_image

  architectures = ["x86_64"]

  image_config {
    command = ["processor.lambda_handler.lambda_handler"]
  }

  environment {
    variables = local.processor_env_vars
  }

  kms_key_arn = var.kms_key_arn

  tracing_config {
    mode = "Active"
  }

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
resource "aws_lambda_event_source_mapping" "sqs_trigger" {
  event_source_arn                   = var.sqs_queue_arn
  function_name                      = aws_lambda_function.processor.arn
  batch_size                         = 10
  maximum_batching_window_in_seconds = 5

  function_response_types = ["ReportBatchItemFailures"]

  scaling_config {
    maximum_concurrency = var.environment == "prod" ? 50 : 10
  }

}
resource "aws_lambda_function" "outbox_publisher" {
  # See processor function above for the supply-chain rationale; the same
  # constraints apply to all container-image Lambdas in the platform.
  # checkov:skip=CKV_AWS_272: Container Lambdas use cosign + ECR immutable tags + Inspector enhanced scanning instead.
  function_name = "${var.name_prefix}-outbox-publisher"
  role          = var.lambda_role_arn
  timeout       = 60
  memory_size   = 256

  package_type = "Image"
  image_uri    = var.outbox_publisher_image != "" ? var.outbox_publisher_image : var.processor_image

  architectures = ["x86_64"]

  image_config {
    command = ["processor.outbox_publisher.lambda_handler"]
  }

  environment {
    variables = local.outbox_publisher_env_vars
  }

  kms_key_arn = var.kms_key_arn

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

resource "aws_cloudwatch_log_group" "outbox_publisher" {
  name              = "/aws/lambda/${var.name_prefix}-outbox-publisher"
  retention_in_days = 365
  kms_key_id        = var.kms_key_arn

  tags = var.tags
}
resource "aws_lambda_event_source_mapping" "outbox_stream" {
  count = var.outbox_stream_arn != "" ? 1 : 0

  event_source_arn  = var.outbox_stream_arn
  function_name     = aws_lambda_function.outbox_publisher.arn
  batch_size        = 100
  starting_position = "LATEST"

  function_response_types = ["ReportBatchItemFailures"]

  maximum_record_age_in_seconds = 86400

  maximum_retry_attempts = 3

  bisect_batch_on_function_error = true

  parallelization_factor = 2

  # Persist failed batches that exhaust retries to a dedicated SQS queue
  # so the at-least-once guarantee of the outbox pattern survives
  # downstream errors. Without this, DDB Streams records dropped after
  # max_retries are lost permanently. (FedRAMP CP-9, AU-2)
  destination_config {
    on_failure {
      destination_arn = var.outbox_publisher_dlq_arn
    }
  }

  lifecycle {
    precondition {
      condition     = var.outbox_publisher_dlq_arn != ""
      error_message = "outbox_publisher_dlq_arn must be set when outbox_stream_arn enables the outbox stream mapping."
    }
  }

  filter_criteria {
    filter {
      pattern = jsonencode({
        eventName = ["INSERT"]
      })
    }
  }

}
resource "aws_appautoscaling_target" "gateway" {
  max_capacity       = 4
  min_capacity       = 1
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.gateway.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-gateway-autoscaling-target"
  })
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
