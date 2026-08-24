terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.44.0, < 7.0.0"
    }
  }
}
resource "aws_cognito_user_pool" "main" {
  name = "${var.name_prefix}-user-pool"

  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  password_policy {
    minimum_length                   = var.password_min_length
    require_lowercase                = true
    require_uppercase                = true
    require_numbers                  = true
    require_symbols                  = true
    temporary_password_validity_days = 7
  }

  # FedRAMP IA-2(1): MFA required for all environments that handle
  # production-shaped credentials. Staging mirrors prod so it must enforce
  # MFA. Dev keeps OPTIONAL to avoid blocking exploratory work.
  mfa_configuration = (
    var.environment == "prod" || var.environment == "staging"
    ? "ON"
    : "OPTIONAL"
  )

  software_token_mfa_configuration {
    enabled = true
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

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

  email_configuration {
    email_sending_account = "COGNITO_DEFAULT"
  }

  verification_message_template {
    default_email_option = "CONFIRM_WITH_CODE"
    email_subject        = "FSAMP - Verify your email"
    email_message        = "Your verification code is {####}"
  }

  user_pool_add_ons {
    # FedRAMP SI-4 / AC-7: threat detection (compromised credentials,
    # risky logins, IP rate limiting). Enforced in environments exposed
    # to validation traffic (staging, prod), audit-only in dev so risky
    # development behaviour is observable but does not block work.
    advanced_security_mode = (
      var.environment == "prod" || var.environment == "staging"
      ? "ENFORCED"
      : (var.environment == "dev" ? "AUDIT" : "OFF")
    )
  }

  device_configuration {
    challenge_required_on_new_device      = true
    device_only_remembered_on_user_prompt = true
  }

  deletion_protection = var.environment == "prod" ? "ACTIVE" : "INACTIVE"

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-user-pool"
  })
}
resource "aws_cognito_user_pool_domain" "main" {
  domain       = var.name_prefix
  user_pool_id = aws_cognito_user_pool.main.id
}
resource "aws_cognito_user_pool_client" "web" {
  name         = "${var.name_prefix}-web-client"
  user_pool_id = aws_cognito_user_pool.main.id

  generate_secret = false

  allowed_oauth_flows                  = ["code"]
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_scopes = [
    "email",
    "openid",
    "profile",
    "${aws_cognito_resource_server.api.identifier}/files.read",
    "${aws_cognito_resource_server.api.identifier}/files.write",
    "${aws_cognito_resource_server.api.identifier}/files.delete"
  ]

  callback_urls = var.callback_urls
  logout_urls   = var.logout_urls

  supported_identity_providers = ["COGNITO"]

  access_token_validity  = var.access_token_validity_minutes
  id_token_validity      = var.access_token_validity_minutes
  refresh_token_validity = var.refresh_token_validity_days

  token_validity_units {
    access_token  = "minutes"
    id_token      = "minutes"
    refresh_token = "days"
  }

  prevent_user_existence_errors = "ENABLED"
  # FedRAMP IA-5: revoke compromised refresh tokens. Without this Cognito
  # ignores RevokeToken API calls and refresh tokens remain valid until
  # natural expiration.
  enable_token_revocation = true

  explicit_auth_flows = concat(
    [
      "ALLOW_USER_SRP_AUTH",
      "ALLOW_REFRESH_TOKEN_AUTH",
    ],
    # Local e2e authenticates with USER_PASSWORD_AUTH against LocalStack;
    # AWS environments keep the SRP-only posture (IA-5).
    var.enable_password_auth_flow ? [
      "ALLOW_USER_PASSWORD_AUTH",
      "ALLOW_ADMIN_USER_PASSWORD_AUTH",
    ] : []
  )

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
# Machine-to-machine client for the client-credentials flow. No workload
# consumes it yet; a future consumer must read the secret from Secrets
# Manager rather than an environment variable (IA-5).
resource "aws_cognito_user_pool_client" "service" {
  name         = "${var.name_prefix}-service-client"
  user_pool_id = aws_cognito_user_pool.main.id

  generate_secret = true

  allowed_oauth_flows                  = ["client_credentials"]
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_scopes = [
    aws_cognito_resource_server.api.scope_identifiers[0],
    aws_cognito_resource_server.api.scope_identifiers[1]
  ]

  supported_identity_providers = ["COGNITO"]

  access_token_validity = var.access_token_validity_minutes

  token_validity_units {
    access_token = "minutes"
  }

  prevent_user_existence_errors = "ENABLED"
  enable_token_revocation       = true
}
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

  scope {
    scope_name        = "files.delete"
    scope_description = "Delete files"
  }
}
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
data "aws_region" "current" {}
