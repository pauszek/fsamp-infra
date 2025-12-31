# =============================================================================
# Dev Environment Configuration (AWS)
# =============================================================================
# This configuration targets real AWS for development/testing
# =============================================================================

terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.40"
    }
  }

  # Remote backend - uncomment when ready to use AWS
  # backend "s3" {
  #   bucket         = "fsamp-terraform-state"
  #   key            = "dev/terraform.tfstate"
  #   region         = "eu-central-1"
  #   encrypt        = true
  #   dynamodb_table = "fsamp-terraform-locks"
  # }
}

# =============================================================================
# AWS Provider Configuration
# =============================================================================

provider "aws" {
  region = var.aws_region

  # FIPS 140-3: Use FIPS-validated endpoints for compliance
  use_fips_endpoint = var.aws_region == "us-east-1" || var.aws_region == "us-east-2" || var.aws_region == "us-west-1" || var.aws_region == "us-west-2"

  default_tags {
    tags = {
      Environment = "dev"
      ManagedBy   = "terraform"
      Project     = "fsamp"
      Compliance  = "FIPS-140-3"
    }
  }
}

# =============================================================================
# Variables
# =============================================================================

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "eu-central-1"
}

# =============================================================================
# Root Module
# =============================================================================

module "fsamp" {
  source = "../../"

  environment  = "dev"
  aws_region   = var.aws_region
  project_name = "fsamp"

  tags = {
    Team       = "development"
    CostCenter = "fsamp-dev"
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

output "ecr_repository_urls" {
  value = module.fsamp.ecr_repository_urls
}

output "cognito_user_pool_id" {
  description = "Cognito User Pool ID"
  value       = module.fsamp.cognito_user_pool_id
}

output "cognito_web_client_id" {
  description = "Cognito Web Client ID"
  value       = module.fsamp.cognito_web_client_id
}

output "api_gateway_endpoint" {
  description = "API Gateway invoke URL"
  value       = module.fsamp.api_gateway_endpoint
}

output "vpc_id" {
  description = "VPC ID"
  value       = module.fsamp.vpc_id
}

output "ecs_cluster_name" {
  description = "ECS Cluster name"
  value       = module.fsamp.ecs_cluster_name
}

