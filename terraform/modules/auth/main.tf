# =============================================================================
# Auth Module - Cognito User Pool
# =============================================================================
# Authentication and authorization for FSAMP platform
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

variable "callback_urls" {
  description = "Allowed callback URLs for OAuth"
  type        = list(string)
  default     = ["http://localhost:3000/callback"]
}

variable "logout_urls" {
  description = "Allowed logout URLs"
  type        = list(string)
  default     = ["http://localhost:3000"]
}

variable "password_min_length" {
  description = "Minimum password length"
  type        = number
  default     = 12
}

variable "access_token_validity_minutes" {
  description = "Access / ID token lifetime in minutes. FedRAMP AC-12 recommends ≤30 min for prod."
  type        = number
  default     = 60
}

variable "refresh_token_validity_days" {
  description = "Refresh token lifetime in days. Shorter values reduce session hijack window."
  type        = number
  default     = 30
}

# =============================================================================
# Cognito User Pool
# =============================================================================

resource "aws_cognito_user_pool" "main" {
  name = "${var.name_prefix}-user-pool"

  # Username configuration
  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  # Password policy (FIPS-aligned strong passwords)
  password_policy {
    minimum_length                   = var.password_min_length
    require_lowercase                = true
    require_uppercase                = true
    require_numbers                  = true
    require_symbols                  = true
    temporary_password_validity_days = 7
  }

  # MFA Configuration
  mfa_configuration = var.environment == "prod" ? "ON" : "OPTIONAL"

  software_token_mfa_configuration {
    enabled = true
  }

  # Account recovery
  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  # User attribute schema
  schema {
    name                     = "email"
    attribute_data_type      = "String"
    mutable                  = true
    required                 = true
    developer_only_attribute = false

    string_attribute_constraints {
      min_length = 5
      max_length = 254
    }
  }

  schema {
    name                     = "name"
    attribute_data_type      = "String"
    mutable                  = true
    required                 = false
    developer_only_attribute = false

    string_attribute_constraints {
      min_length = 1
      max_length = 256
    }
  }

  # Email configuration
  email_configuration {
    email_sending_account = "COGNITO_DEFAULT"
  }

  # Verification messages
  verification_message_template {
    default_email_option = "CONFIRM_WITH_CODE"
    email_subject        = "FSAMP - Verify your email"
    email_message        = "Your verification code is {####}"
  }

  # Advanced security (if prod)
  user_pool_add_ons {
    advanced_security_mode = var.environment == "prod" ? "ENFORCED" : "OFF"
  }

  # Device tracking
  device_configuration {
    challenge_required_on_new_device      = true
    device_only_remembered_on_user_prompt = true
  }

  # Deletion protection
  deletion_protection = var.environment == "prod" ? "ACTIVE" : "INACTIVE"

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-user-pool"
  })
}

# =============================================================================
# User Pool Domain
# =============================================================================

resource "aws_cognito_user_pool_domain" "main" {
  domain       = var.name_prefix
  user_pool_id = aws_cognito_user_pool.main.id
}

# =============================================================================
# App Client - Web Application
# =============================================================================

resource "aws_cognito_user_pool_client" "web" {
  name         = "${var.name_prefix}-web-client"
  user_pool_id = aws_cognito_user_pool.main.id

  # No client secret for web app (SPA)
  generate_secret = false

  # OAuth configuration
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_scopes = [
    "email",
    "openid",
    "profile"
  ]

  callback_urls = var.callback_urls
  logout_urls   = var.logout_urls

  supported_identity_providers = ["COGNITO"]

  # Token validity (FedRAMP AC-12 — session timeouts)
  access_token_validity  = var.access_token_validity_minutes
  id_token_validity      = var.access_token_validity_minutes
  refresh_token_validity = var.refresh_token_validity_days

  token_validity_units {
    access_token  = "minutes"
    id_token      = "minutes"
    refresh_token = "days"
  }

  # Prevent user existence errors
  prevent_user_existence_errors = "ENABLED"

  # Auth flows
  explicit_auth_flows = [
    "ALLOW_USER_SRP_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH"
  ]

  # Read/write attributes
  read_attributes = [
    "email",
    "email_verified",
    "name"
  ]

  write_attributes = [
    "email",
    "name"
  ]
}

# =============================================================================
# App Client - Backend Service (M2M)
# =============================================================================

resource "aws_cognito_user_pool_client" "service" {
  name         = "${var.name_prefix}-service-client"
  user_pool_id = aws_cognito_user_pool.main.id

  # Client secret for service-to-service auth
  generate_secret = true

  # OAuth configuration for client credentials
  allowed_oauth_flows                  = ["client_credentials"]
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_scopes = [
    aws_cognito_resource_server.api.scope_identifiers[0],
    aws_cognito_resource_server.api.scope_identifiers[1]
  ]

  supported_identity_providers = ["COGNITO"]

  # Token validity (FedRAMP AC-12 — session timeouts)
  access_token_validity = var.access_token_validity_minutes

  token_validity_units {
    access_token = "minutes"
  }

  # Prevent user existence errors
  prevent_user_existence_errors = "ENABLED"
}

# =============================================================================
# Resource Server (API Scopes)
# =============================================================================

resource "aws_cognito_resource_server" "api" {
  identifier   = "https://${var.name_prefix}-api"
  name         = "${var.name_prefix}-api"
  user_pool_id = aws_cognito_user_pool.main.id

  scope {
    scope_name        = "files.read"
    scope_description = "Read files"
  }

  scope {
    scope_name        = "files.write"
    scope_description = "Write files"
  }
}

# =============================================================================
# User Groups
# =============================================================================

resource "aws_cognito_user_group" "admins" {
  name         = "admins"
  user_pool_id = aws_cognito_user_pool.main.id
  description  = "Platform administrators"
  precedence   = 1
}

resource "aws_cognito_user_group" "users" {
  name         = "users"
  user_pool_id = aws_cognito_user_pool.main.id
  description  = "Regular users"
  precedence   = 10
}

# =============================================================================
# Outputs
# =============================================================================

output "user_pool_id" {
  description = "Cognito User Pool ID"
  value       = aws_cognito_user_pool.main.id
}

output "user_pool_arn" {
  description = "Cognito User Pool ARN"
  value       = aws_cognito_user_pool.main.arn
}

output "user_pool_endpoint" {
  description = "Cognito User Pool endpoint"
  value       = aws_cognito_user_pool.main.endpoint
}

output "user_pool_domain" {
  description = "Cognito User Pool domain"
  value       = aws_cognito_user_pool_domain.main.domain
}

output "web_client_id" {
  description = "Web application client ID"
  value       = aws_cognito_user_pool_client.web.id
}

output "service_client_id" {
  description = "Service client ID (for M2M auth)"
  value       = aws_cognito_user_pool_client.service.id
}

output "service_client_secret" {
  description = "Service client secret (for M2M auth)"
  value       = aws_cognito_user_pool_client.service.client_secret
  sensitive   = true
}

output "cognito_domain_url" {
  description = "Full Cognito hosted UI domain URL"
  value       = "https://${aws_cognito_user_pool_domain.main.domain}.auth.${data.aws_region.current.region}.amazoncognito.com"
}

# =============================================================================
# Data Sources
# =============================================================================

data "aws_region" "current" {}
