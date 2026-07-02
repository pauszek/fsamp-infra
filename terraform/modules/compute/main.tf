terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.44.0, < 7.0.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = ">= 4.0.0"
    }
  }
}
locals {
  use_self_signed_cert = var.alb_tls_enabled && var.alb_certificate_mode == "self-signed"
  use_acm_cert         = var.alb_tls_enabled && var.alb_certificate_mode == "acm"

  alb_certificate_arn = (
    local.use_acm_cert
    ? aws_acm_certificate_validation.alb_acm[0].certificate_arn
    : (local.use_self_signed_cert ? aws_acm_certificate.alb_internal[0].arn : null)
  )
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
data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

# ELB access-log delivery account for us-west-2 (region available before
# August 2022, so log delivery uses the regional ELB account, not the
# logdelivery.elasticloadbalancing.amazonaws.com service principal).
locals {
  elb_log_delivery_account = "797873946194"
}

resource "aws_s3_bucket" "alb_logs" {
  bucket        = "${var.name_prefix}-alb-logs"
  force_destroy = var.environment != "prod"

  tags = merge(var.tags, {
    Name    = "${var.name_prefix}-alb-logs"
    Purpose = "Gateway ALB access logs AU-2 AU-3 AU-12"
  })
}

# ALB access-log delivery does not support SSE-KMS; SSE-S3 (AES-256) is the
# strongest server-side encryption AWS allows here - documented SC-28
# exception (data at rest is still AES-256 encrypted).
resource "aws_s3_bucket_server_side_encryption_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  rule {
    id     = "alb-logs-lifecycle"
    status = "Enabled"
    filter {}

    transition {
      days          = 90
      storage_class = "STANDARD_IA"
    }

    expiration {
      days = var.environment == "prod" ? 2555 : 365
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_s3_bucket_policy" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ELBAccessLogDelivery"
        Effect = "Allow"
        Principal = {
          AWS = "arn:${data.aws_partition.current.partition}:iam::${local.elb_log_delivery_account}:root"
        }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.alb_logs.arn}/alb/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
      },
      {
        Sid       = "DenyUnencryptedTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.alb_logs.arn,
          "${aws_s3_bucket.alb_logs.arn}/*"
        ]
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      }
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.alb_logs]
}

resource "aws_lb" "gateway" {
  name               = "${var.name_prefix}-gateway-alb"
  internal           = true
  load_balancer_type = "application"
  security_groups    = [var.alb_security_group_id]
  subnets            = var.subnet_ids

  enable_deletion_protection = var.environment == "prod"
  drop_invalid_header_fields = true

  access_logs {
    bucket  = aws_s3_bucket.alb_logs.id
    prefix  = "alb"
    enabled = true
  }

  tags = merge(var.tags, {
    Name    = "${var.name_prefix}-gateway-alb"
    Service = "gateway"
  })

  # ELB validates write access to the log bucket when access_logs is enabled.
  depends_on = [aws_s3_bucket_policy.alb_logs]
}

# Self-signed cert imported into ACM for the internal ALB HTTPS listener
# (default mode; SC-8/SC-13). Rationale and the SC-23 compensating control:
# ADR-008. early_renewal_hours rotates the key pair on apply ~30 days before
# expiry (SC-12).
resource "tls_private_key" "alb" {
  count = local.use_self_signed_cert ? 1 : 0

  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "alb" {
  count = local.use_self_signed_cert ? 1 : 0

  private_key_pem = tls_private_key.alb[0].private_key_pem

  subject {
    common_name  = aws_lb.gateway.dns_name
    organization = "FSAMP"
  }

  dns_names = [aws_lb.gateway.dns_name]

  validity_period_hours = 8760
  early_renewal_hours   = 720

  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth",
  ]
}

resource "aws_acm_certificate" "alb_internal" {
  count = local.use_self_signed_cert ? 1 : 0

  private_key      = tls_private_key.alb[0].private_key_pem
  certificate_body = tls_self_signed_cert.alb[0].cert_pem

  lifecycle {
    create_before_destroy = true
  }

  tags = merge(var.tags, {
    Name    = "${var.name_prefix}-gateway-alb-internal"
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

# DNS-validated ACM certificate (alb_certificate_mode = "acm"): removes the
# self-signed SC-23 exception entirely - the certificate chain is verifiable
# and the API Gateway integrations enforce verification. Requires a publicly
# delegated domain in real AWS; under LocalStack Pro validation succeeds
# locally without delegation.
resource "aws_route53_zone" "alb" {
  count = local.use_acm_cert ? 1 : 0

  name = var.alb_domain_name

  lifecycle {
    precondition {
      condition     = var.alb_domain_name != null
      error_message = "alb_domain_name must be set when alb_certificate_mode = \"acm\"."
    }
  }

  tags = merge(var.tags, {
    Name    = "${var.name_prefix}-alb-zone"
    Service = "gateway"
  })
}

resource "aws_acm_certificate" "alb_acm" {
  count = local.use_acm_cert ? 1 : 0

  domain_name       = var.alb_domain_name
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = merge(var.tags, {
    Name    = "${var.name_prefix}-gateway-alb-acm"
    Service = "gateway"
  })
}

resource "aws_route53_record" "alb_cert_validation" {
  for_each = local.use_acm_cert ? {
    for dvo in aws_acm_certificate.alb_acm[0].domain_validation_options :
    dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  } : {}

  zone_id         = aws_route53_zone.alb[0].zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "alb_acm" {
  count = local.use_acm_cert ? 1 : 0

  certificate_arn         = aws_acm_certificate.alb_acm[0].arn
  validation_record_fqdns = [for r in aws_route53_record.alb_cert_validation : r.fqdn]
}

# The domain resolves to the internal ALB inside the VPC (and inside
# LocalStack); API Gateway integrations address the ALB by this name.
resource "aws_route53_record" "alb_alias" {
  count = local.use_acm_cert ? 1 : 0

  zone_id = aws_route53_zone.alb[0].zone_id
  name    = var.alb_domain_name
  type    = "A"

  alias {
    name                   = aws_lb.gateway.dns_name
    zone_id                = aws_lb.gateway.zone_id
    evaluate_target_health = false
  }
}

# HTTPS with the AWS FIPS TLS policy: only FIPS 140-3 validated (AWS-LC)
# TLS 1.2/1.3 cipher suites are negotiated on this listener.
resource "aws_lb_listener" "gateway" {
  load_balancer_arn = aws_lb.gateway.arn
  port              = var.alb_tls_enabled ? 443 : 80
  protocol          = var.alb_tls_enabled ? "HTTPS" : "HTTP"
  ssl_policy        = var.alb_tls_enabled ? "ELBSecurityPolicy-TLS13-1-2-FIPS-2023-04" : null
  certificate_arn   = local.alb_certificate_arn

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
  localstack_cognito_issuer_endpoint = replace(var.localstack_internal_endpoint, "://localstack:", "://localhost.localstack.cloud:")

  local_aws_endpoint_env = var.environment == "local" && var.localstack_internal_endpoint != "" ? {
    AWS_ENDPOINT_URL      = var.localstack_internal_endpoint
    AWS_ACCESS_KEY_ID     = "test"
    AWS_SECRET_ACCESS_KEY = "test"
  } : {}

  local_gateway_endpoint_env = var.environment == "local" && var.localstack_internal_endpoint != "" ? {
    AWS_S3_ENDPOINT       = var.localstack_internal_endpoint
    AWS_SNS_ENDPOINT      = var.localstack_internal_endpoint
    COGNITO_ISSUER_URI    = "${local.localstack_cognito_issuer_endpoint}/${var.cognito_user_pool_id}"
    COGNITO_JWKS_ENDPOINT = "${var.localstack_internal_endpoint}/${var.cognito_user_pool_id}/.well-known/jwks.json"
  } : {}

  gateway_env_vars = merge({
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
    SNS_TOPIC_ARN                 = var.file_events_topic_arn

    DYNAMODB_TABLE_NAME                      = var.dynamodb_table_name
    AWS_DYNAMODB_TABLE_NAME                  = var.dynamodb_table_name
    OUTBOX_TABLE_NAME                        = var.outbox_table_name
    AWS_DYNAMODB_OUTBOX_TABLE_NAME           = var.outbox_table_name
    DYNAMODB_IDEMPOTENCY_TABLE_NAME          = var.idempotency_table_name
    AWS_DYNAMODB_IDEMPOTENCY_TABLE_NAME      = var.idempotency_table_name
    DIRECT_PUBLISH_AFTER_OUTBOX              = "false"
    AWS_DYNAMODB_DIRECT_PUBLISH_AFTER_OUTBOX = "false"
  }, local.local_aws_endpoint_env, local.local_gateway_endpoint_env)

  processor_env_vars = merge({
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
  }, local.local_aws_endpoint_env)

  outbox_publisher_env_vars = merge({
    ENVIRONMENT                  = var.environment
    AWS_REGION                   = var.aws_region
    POWERTOOLS_SERVICE_NAME      = "outbox-publisher"
    POWERTOOLS_METRICS_NAMESPACE = "FSAMP/OutboxPublisher"
    POWERTOOLS_LOG_LEVEL         = var.environment == "prod" ? "INFO" : "DEBUG"
    SNS_TOPIC_ARN                = var.sns_topic_arn
    FILE_EVENTS_TOPIC_ARN        = var.file_events_topic_arn
    PROCESSING_EVENTS_TOPIC_ARN  = var.sns_topic_arn
    OUTBOX_TABLE_NAME            = var.outbox_table_name
    MAX_RETRY_COUNT              = "3"
    PUBLISH_CLAIM_TTL_SECONDS    = "300"
    USE_FIPS_ENDPOINT            = var.environment == "local" ? "false" : tostring(var.use_fips_endpoint)
    FIPS_REQUIRED                = var.environment == "local" ? "false" : "true"
  }, local.local_aws_endpoint_env)

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
  count = var.enable_lambdas ? 1 : 0

  function_name = "${var.name_prefix}-processor"
  role          = var.lambda_role_arn
  timeout       = var.processor_timeout
  memory_size   = var.processor_memory

  package_type = "Image"
  image_uri    = var.processor_image

  architectures = ["arm64"]

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
  count = var.enable_lambdas ? 1 : 0

  name              = "/aws/lambda/${var.name_prefix}-processor"
  retention_in_days = 365
  kms_key_id        = var.kms_key_arn

  tags = var.tags
}
resource "aws_lambda_event_source_mapping" "sqs_trigger" {
  count = var.enable_lambdas ? 1 : 0

  event_source_arn                   = var.sqs_queue_arn
  function_name                      = aws_lambda_function.processor[0].arn
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
  count = var.enable_lambdas ? 1 : 0

  function_name = "${var.name_prefix}-outbox-publisher"
  role          = var.lambda_role_arn
  timeout       = 60
  memory_size   = 256

  package_type = "Image"
  image_uri    = var.outbox_publisher_image != "" ? var.outbox_publisher_image : var.processor_image

  architectures = ["arm64"]

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
  count = var.enable_lambdas ? 1 : 0

  name              = "/aws/lambda/${var.name_prefix}-outbox-publisher"
  retention_in_days = 365
  kms_key_id        = var.kms_key_arn

  tags = var.tags
}
resource "aws_lambda_event_source_mapping" "outbox_stream" {
  count = var.enable_lambdas ? 1 : 0

  # tflint-ignore: aws_lambda_event_source_mapping_invalid_event_source_arn
  event_source_arn  = var.outbox_stream_arn
  function_name     = aws_lambda_function.outbox_publisher[0].arn
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
      condition     = var.outbox_stream_arn != ""
      error_message = "outbox_stream_arn must be set when Lambdas are enabled."
    }

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
