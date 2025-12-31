# =============================================================================
# Production Environment Configuration (AWS)
# =============================================================================
# Production configuration with enhanced security and monitoring
# FIPS 140-3 compliant - uses us-west-2 for FIPS endpoints
# =============================================================================

terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.40"
    }
  }

  # Remote backend for production - S3 + DynamoDB locking
  # Uncomment after running bootstrap
  # backend "s3" {
  #   bucket         = "fsamp-terraform-state-ACCOUNT_ID"  # Update with your account ID
  #   key            = "prod/terraform.tfstate"
  #   region         = "us-west-2"
  #   encrypt        = true
  #   dynamodb_table = "fsamp-terraform-locks"
  # }
}

# =============================================================================
# AWS Provider Configuration
# =============================================================================

provider "aws" {
  region = var.aws_region

  # FIPS 140-3: Use FIPS-validated endpoints (us-west-2 supports FIPS)
  use_fips_endpoint = true

  default_tags {
    tags = {
      Environment = "prod"
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
  description = "AWS region (us-west-2 for FIPS support)"
  type        = string
  default     = "us-west-2"
}

# =============================================================================
# Root Module
# =============================================================================

module "fsamp" {
  source = "../../"

  environment        = "prod"
  aws_region         = var.aws_region
  project_name       = "fsamp"
  enable_nat_gateway = false # Use VPC Endpoints for cost savings

  tags = {
    Team       = "platform"
    CostCenter = "fsamp-prod"
    DataClass  = "confidential"
    Compliance = "FIPS-140-3"
  }
}

# =============================================================================
# Outputs
# =============================================================================

output "kms_key_arn" {
  description = "ARN of the KMS key"
  value       = module.fsamp.kms_key_arn
  sensitive   = true
}

output "s3_buckets" {
  description = "S3 bucket names"
  value       = module.fsamp.s3_buckets
}

output "sqs_queue_urls" {
  description = "SQS queue URLs"
  value       = module.fsamp.sqs_queue_urls
}

output "sns_topic_arns" {
  description = "SNS topic ARNs"
  value       = module.fsamp.sns_topic_arns
}

output "dynamodb_tables" {
  description = "DynamoDB table names"
  value       = module.fsamp.dynamodb_table_names
}

output "ecr_repository_urls" {
  description = "ECR repository URLs"
  value       = module.fsamp.ecr_repository_urls
  sensitive   = true
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

output "waf_web_acl_arn" {
  description = "WAF Web ACL ARN"
  value       = module.fsamp.waf_web_acl_arn
}

