# =============================================================================
# Local Environment Configuration (LocalStack)
# =============================================================================

terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.40"
    }
  }

  backend "local" {
    path = "terraform.tfstate"
  }
}

# =============================================================================
# LocalStack Provider
# =============================================================================

provider "aws" {
  region                      = var.aws_region
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true

  endpoints {
    s3             = var.localstack_endpoint
    sqs            = var.localstack_endpoint
    sns            = var.localstack_endpoint
    dynamodb       = var.localstack_endpoint
    kms            = var.localstack_endpoint
    iam            = var.localstack_endpoint
    sts            = var.localstack_endpoint
    cloudwatch     = var.localstack_endpoint
    logs           = var.localstack_endpoint
    lambda         = var.localstack_endpoint
    events         = var.localstack_endpoint
    secretsmanager = var.localstack_endpoint
    ssm            = var.localstack_endpoint
    apigateway     = var.localstack_endpoint
  }
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

