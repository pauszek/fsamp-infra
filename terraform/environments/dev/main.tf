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

  default_tags {
    tags = {
      Environment = "dev"
      ManagedBy   = "terraform"
      Project     = "fsamp"
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
