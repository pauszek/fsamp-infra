# =============================================================================
# API Gateway Module - REST API with WAF
# =============================================================================
# Public API endpoint with security features for FSAMP Gateway service
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

variable "cognito_user_pool_arn" {
  description = "ARN of Cognito User Pool for authorization"
  type        = string
  default     = null
}

variable "enable_waf" {
  description = "Enable WAF for API Gateway"
  type        = bool
  default     = true
}

variable "throttle_rate_limit" {
  description = "Rate limit for API (requests per second)"
  type        = number
  default     = 100
}

variable "throttle_burst_limit" {
  description = "Burst limit for API"
  type        = number
  default     = 200
}

variable "vpc_id" {
  description = "VPC ID for VPC Link"
  type        = string
  default     = null
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for VPC Link"
  type        = list(string)
  default     = []
}

variable "alb_listener_arn" {
  description = "ARN of the ALB listener for the Gateway service"
  type        = string
  default     = null
}

variable "alb_dns_name" {
  description = "DNS name of the ALB for the Gateway service"
  type        = string
  default     = null
}

# =============================================================================
# Data Sources
# =============================================================================

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

# =============================================================================
# API Gateway REST API
# =============================================================================

resource "aws_api_gateway_rest_api" "main" {
  name        = "${var.name_prefix}-api"
  description = "FSAMP REST API - ${var.environment}"

  endpoint_configuration {
    types = ["REGIONAL"]
  }

  # Enable API Gateway logging
  minimum_compression_size = 1024

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-api"
  })
}

# =============================================================================
# API Resources
# =============================================================================

# /files resource
resource "aws_api_gateway_resource" "files" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_rest_api.main.root_resource_id
  path_part   = "files"
}

# /files/{fileId} resource
resource "aws_api_gateway_resource" "file" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_resource.files.id
  path_part   = "{fileId}"
}

# /files/upload resource
resource "aws_api_gateway_resource" "upload" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_resource.files.id
  path_part   = "upload"
}

# /health resource
resource "aws_api_gateway_resource" "health" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_rest_api.main.root_resource_id
  path_part   = "health"
}

# =============================================================================
# Cognito Authorizer (if enabled)
# =============================================================================

resource "aws_api_gateway_authorizer" "cognito" {
  count = var.cognito_user_pool_arn != null ? 1 : 0

  name            = "${var.name_prefix}-cognito-authorizer"
  rest_api_id     = aws_api_gateway_rest_api.main.id
  type            = "COGNITO_USER_POOLS"
  provider_arns   = [var.cognito_user_pool_arn]
  identity_source = "method.request.header.Authorization"
}

# =============================================================================
# VPC Link (for private ALB integration)
# =============================================================================

resource "aws_api_gateway_vpc_link" "main" {
  count = var.alb_listener_arn != null ? 1 : 0

  name        = "${var.name_prefix}-vpc-link"
  description = "VPC Link to private ALB"
  target_arns = [var.alb_listener_arn]

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-vpc-link"
  })
}

# =============================================================================
# File Upload Endpoint (POST /files/upload)
# =============================================================================

resource "aws_api_gateway_method" "upload_post" {
  count = var.alb_dns_name != null ? 1 : 0

  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.upload.id
  http_method   = "POST"
  authorization = var.cognito_user_pool_arn != null ? "COGNITO_USER_POOLS" : "NONE"
  authorizer_id = var.cognito_user_pool_arn != null ? aws_api_gateway_authorizer.cognito[0].id : null

  request_parameters = {
    "method.request.header.X-Idempotency-Key" = false
    "method.request.header.Content-Type"      = true
  }
}

resource "aws_api_gateway_integration" "upload_post" {
  count = var.alb_dns_name != null ? 1 : 0

  rest_api_id             = aws_api_gateway_rest_api.main.id
  resource_id             = aws_api_gateway_resource.upload.id
  http_method             = aws_api_gateway_method.upload_post[0].http_method
  type                    = "HTTP_PROXY"
  integration_http_method = "POST"
  uri                     = "http://${var.alb_dns_name}/api/v1/files/upload"
  connection_type         = "VPC_LINK"
  connection_id           = aws_api_gateway_vpc_link.main[0].id
  timeout_milliseconds    = 29000

  request_parameters = {
    "integration.request.header.X-Idempotency-Key" = "method.request.header.X-Idempotency-Key"
    "integration.request.header.Content-Type"      = "method.request.header.Content-Type"
  }
}

resource "aws_api_gateway_method_response" "upload_post_201" {
  count = var.alb_dns_name != null ? 1 : 0

  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.upload.id
  http_method = aws_api_gateway_method.upload_post[0].http_method
  status_code = "201"

  response_parameters = {
    "method.response.header.X-Correlation-Id" = true
  }
}

# =============================================================================
# Get File Endpoint (GET /files/{fileId})
# =============================================================================

resource "aws_api_gateway_method" "file_get" {
  count = var.alb_dns_name != null ? 1 : 0

  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.file.id
  http_method   = "GET"
  authorization = var.cognito_user_pool_arn != null ? "COGNITO_USER_POOLS" : "NONE"
  authorizer_id = var.cognito_user_pool_arn != null ? aws_api_gateway_authorizer.cognito[0].id : null

  request_parameters = {
    "method.request.path.fileId" = true
  }
}

resource "aws_api_gateway_integration" "file_get" {
  count = var.alb_dns_name != null ? 1 : 0

  rest_api_id             = aws_api_gateway_rest_api.main.id
  resource_id             = aws_api_gateway_resource.file.id
  http_method             = aws_api_gateway_method.file_get[0].http_method
  type                    = "HTTP_PROXY"
  integration_http_method = "GET"
  uri                     = "http://${var.alb_dns_name}/api/v1/files/{fileId}"
  connection_type         = "VPC_LINK"
  connection_id           = aws_api_gateway_vpc_link.main[0].id
  timeout_milliseconds    = 29000

  request_parameters = {
    "integration.request.path.fileId" = "method.request.path.fileId"
  }
}

# =============================================================================
# Delete File Endpoint (DELETE /files/{fileId})
# =============================================================================

resource "aws_api_gateway_method" "file_delete" {
  count = var.alb_dns_name != null ? 1 : 0

  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.file.id
  http_method   = "DELETE"
  authorization = var.cognito_user_pool_arn != null ? "COGNITO_USER_POOLS" : "NONE"
  authorizer_id = var.cognito_user_pool_arn != null ? aws_api_gateway_authorizer.cognito[0].id : null

  request_parameters = {
    "method.request.path.fileId" = true
  }
}

resource "aws_api_gateway_integration" "file_delete" {
  count = var.alb_dns_name != null ? 1 : 0

  rest_api_id             = aws_api_gateway_rest_api.main.id
  resource_id             = aws_api_gateway_resource.file.id
  http_method             = aws_api_gateway_method.file_delete[0].http_method
  type                    = "HTTP_PROXY"
  integration_http_method = "DELETE"
  uri                     = "http://${var.alb_dns_name}/api/v1/files/{fileId}"
  connection_type         = "VPC_LINK"
  connection_id           = aws_api_gateway_vpc_link.main[0].id
  timeout_milliseconds    = 29000

  request_parameters = {
    "integration.request.path.fileId" = "method.request.path.fileId"
  }
}

# =============================================================================
# Mock Methods (placeholder - will be replaced with actual integrations)
# =============================================================================

# GET /health - public health check
resource "aws_api_gateway_method" "health_get" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.health.id
  http_method   = "GET"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "health_get" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.health.id
  http_method = aws_api_gateway_method.health_get.http_method
  type        = "MOCK"

  request_templates = {
    "application/json" = jsonencode({
      statusCode = 200
    })
  }
}

resource "aws_api_gateway_method_response" "health_get_200" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.health.id
  http_method = aws_api_gateway_method.health_get.http_method
  status_code = "200"

  response_models = {
    "application/json" = "Empty"
  }
}

resource "aws_api_gateway_integration_response" "health_get_200" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.health.id
  http_method = aws_api_gateway_method.health_get.http_method
  status_code = aws_api_gateway_method_response.health_get_200.status_code

  response_templates = {
    "application/json" = jsonencode({
      status  = "healthy"
      service = "fsamp-api"
    })
  }
}

# =============================================================================
# API Deployment & Stage
# =============================================================================

resource "aws_api_gateway_deployment" "main" {
  rest_api_id = aws_api_gateway_rest_api.main.id

  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_resource.files.id,
      aws_api_gateway_resource.file.id,
      aws_api_gateway_resource.upload.id,
      aws_api_gateway_resource.health.id,
      aws_api_gateway_method.health_get.id,
      aws_api_gateway_integration.health_get.id,
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [
    aws_api_gateway_method.health_get,
    aws_api_gateway_integration.health_get,
  ]
}

resource "aws_api_gateway_stage" "main" {
  deployment_id = aws_api_gateway_deployment.main.id
  rest_api_id   = aws_api_gateway_rest_api.main.id
  stage_name    = var.environment

  # Enable CloudWatch logging
  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_access.arn
    format = jsonencode({
      requestId         = "$context.requestId"
      ip                = "$context.identity.sourceIp"
      caller            = "$context.identity.caller"
      user              = "$context.identity.user"
      requestTime       = "$context.requestTime"
      httpMethod        = "$context.httpMethod"
      resourcePath      = "$context.resourcePath"
      status            = "$context.status"
      protocol          = "$context.protocol"
      responseLength    = "$context.responseLength"
      integrationError  = "$context.integrationErrorMessage"
      integrationStatus = "$context.integrationStatus"
    })
  }

  xray_tracing_enabled = true

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-api-${var.environment}"
  })
}

# Method Settings (throttling)
resource "aws_api_gateway_method_settings" "all" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  stage_name  = aws_api_gateway_stage.main.stage_name
  method_path = "*/*"

  settings {
    throttling_rate_limit  = var.throttle_rate_limit
    throttling_burst_limit = var.throttle_burst_limit
    metrics_enabled        = true
    logging_level          = var.environment == "prod" ? "ERROR" : "INFO"
  }
}

# =============================================================================
# CloudWatch Log Groups
# =============================================================================

resource "aws_cloudwatch_log_group" "api_access" {
  name              = "/aws/apigateway/${var.name_prefix}-access-logs"
  retention_in_days = var.environment == "prod" ? 90 : 30

  tags = var.tags
}

resource "aws_cloudwatch_log_group" "api_execution" {
  name              = "API-Gateway-Execution-Logs_${aws_api_gateway_rest_api.main.id}/${var.environment}"
  retention_in_days = var.environment == "prod" ? 90 : 30

  tags = var.tags
}

# =============================================================================
# WAF (Web Application Firewall)
# =============================================================================

resource "aws_wafv2_web_acl" "api" {
  count = var.enable_waf ? 1 : 0

  name        = "${var.name_prefix}-api-waf"
  description = "WAF for FSAMP API Gateway"
  scope       = "REGIONAL"

  default_action {
    allow {}
  }

  # AWS Managed Rules - Common Rule Set
  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 1

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name_prefix}-common-rules"
      sampled_requests_enabled   = true
    }
  }

  # AWS Managed Rules - Known Bad Inputs
  rule {
    name     = "AWSManagedRulesKnownBadInputsRuleSet"
    priority = 2

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name_prefix}-bad-inputs"
      sampled_requests_enabled   = true
    }
  }

  # Rate Limiting Rule
  rule {
    name     = "RateLimitRule"
    priority = 3

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = 2000
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name_prefix}-rate-limit"
      sampled_requests_enabled   = true
    }
  }

  # SQL Injection Protection
  rule {
    name     = "AWSManagedRulesSQLiRuleSet"
    priority = 4

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesSQLiRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name_prefix}-sqli"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.name_prefix}-waf"
    sampled_requests_enabled   = true
  }

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-api-waf"
  })
}

# Associate WAF with API Gateway
resource "aws_wafv2_web_acl_association" "api" {
  count = var.enable_waf ? 1 : 0

  resource_arn = aws_api_gateway_stage.main.arn
  web_acl_arn  = aws_wafv2_web_acl.api[0].arn
}

# =============================================================================
# Outputs
# =============================================================================

output "api_id" {
  description = "API Gateway REST API ID"
  value       = aws_api_gateway_rest_api.main.id
}

output "api_endpoint" {
  description = "API Gateway invoke URL"
  value       = aws_api_gateway_stage.main.invoke_url
}

output "api_stage_name" {
  description = "API Gateway stage name"
  value       = aws_api_gateway_stage.main.stage_name
}

output "waf_web_acl_arn" {
  description = "WAF Web ACL ARN"
  value       = var.enable_waf ? aws_wafv2_web_acl.api[0].arn : null
}

output "api_execution_arn" {
  description = "API Gateway execution ARN (for Lambda permissions)"
  value       = aws_api_gateway_rest_api.main.execution_arn
}

output "vpc_link_id" {
  description = "VPC Link ID for ALB integration"
  value       = length(aws_api_gateway_vpc_link.main) > 0 ? aws_api_gateway_vpc_link.main[0].id : null
}

