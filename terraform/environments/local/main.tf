# =============================================================================
# Local Environment Configuration (LocalStack)
# =============================================================================
# This configuration targets LocalStack for local development
# =============================================================================

terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.40"
    }
  }

  # Local backend - no remote state for local dev
  backend "local" {
    path = "terraform.tfstate"
  }
}

# =============================================================================
# LocalStack Provider Configuration
# =============================================================================

provider "aws" {
  region                      = "us-west-2"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true

  endpoints {
    s3             = "http://localhost:4566"
    sqs            = "http://localhost:4566"
    sns            = "http://localhost:4566"
    dynamodb       = "http://localhost:4566"
    kms            = "http://localhost:4566"
    iam            = "http://localhost:4566"
    sts            = "http://localhost:4566"
    cloudwatch     = "http://localhost:4566"
    logs           = "http://localhost:4566"
    lambda         = "http://localhost:4566"
    events         = "http://localhost:4566"
    secretsmanager = "http://localhost:4566"
    ssm            = "http://localhost:4566"
    apigateway     = "http://localhost:4566"
  }

  default_tags {
    tags = {
      Environment = "local"
      ManagedBy   = "terraform"
      Project     = "fsamp"
    }
  }
}

# =============================================================================
# Root Module
# =============================================================================

module "fsamp" {
  source = "../../"

  environment  = "local"
  aws_region   = "us-west-2"
  project_name = "fsamp"

  tags = {
    Team = "development"
  }
}

# =============================================================================
# Outputs
# =============================================================================

output "kms_key_arn" {
  value = module.fsamp.kms_key_arn
}

output "s3_buckets" {
  value = module.fsamp.s3_buckets
}

output "sqs_queue_urls" {
  value = module.fsamp.sqs_queue_urls
}

output "sns_topic_arns" {
  value = module.fsamp.sns_topic_arns
}

output "dynamodb_tables" {
  value = module.fsamp.dynamodb_table_names
}
