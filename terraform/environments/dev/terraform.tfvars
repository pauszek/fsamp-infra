# =============================================================================
# Dev Environment Variables
# =============================================================================
# These values override defaults from the root module.
# Copy this file and customize for your AWS account.
#
# Usage:
#   terraform apply -var-file=terraform.tfvars
# =============================================================================

# AWS Region - us-west-2 for FIPS 140-3 endpoints
aws_region = "us-west-2"

# NAT Gateway - disabled for cost savings
# VPC Endpoints are used instead for AWS service access
# Set to true only if you need external internet access from private subnets
enable_nat_gateway = false

