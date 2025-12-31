# =============================================================================
# Dev Environment Configuration (AWS)
# =============================================================================

terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.40"
    }
  }

  # Remote backend - uncomment after bootstrap
  # backend "s3" {
  #   bucket         = "fsamp-terraform-state"
  #   key            = "dev/terraform.tfstate"
  #   region         = "us-west-2"
  #   encrypt        = true
  #   dynamodb_table = "fsamp-terraform-locks"
  # }
}

# =============================================================================
# AWS Provider (FIPS 140-3)
# =============================================================================

provider "aws" {
  region            = var.aws_region
  use_fips_endpoint = var.use_fips_endpoint
}

# =============================================================================
# Root Module
# =============================================================================

module "fsamp" {
  source = "../../"

  environment        = var.environment
  aws_region         = var.aws_region
  project_name       = var.project_name
  enable_nat_gateway = var.enable_nat_gateway
  tags               = var.tags
}

