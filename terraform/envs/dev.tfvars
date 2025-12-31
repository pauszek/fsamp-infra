# =============================================================================
# Dev Environment (AWS Free Tier)
# =============================================================================
# Usage: terraform plan -var-file=envs/dev.tfvars

environment        = "dev"
aws_region         = "us-west-2"
project_name       = "fsamp"
enable_nat_gateway = false  # Use VPC Endpoints (~$30/month savings)
use_fips_endpoint  = true   # FIPS 140-3 compliance

tags = {
  Team       = "development"
  CostCenter = "fsamp-dev"
  Compliance = "FIPS-140-3"
}

