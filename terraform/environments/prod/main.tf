# =============================================================================
# Production Environment Configuration (AWS)
# =============================================================================
# Production configuration with enhanced security and monitoring
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
  # Uncomment when ready to deploy to AWS
  # backend "s3" {
  #   bucket         = "fsamp-terraform-state"
  #   key            = "prod/terraform.tfstate"
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
  description = "AWS region"
  type        = string
  default     = "eu-central-1"
}

# =============================================================================
# Root Module
# =============================================================================

module "fsamp" {
  source = "../../"

  environment  = "prod"
  aws_region   = var.aws_region
  project_name = "fsamp"

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
