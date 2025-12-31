# =============================================================================
# Production Environment (AWS)
# =============================================================================
# Usage: terraform plan -var-file=envs/prod.tfvars

environment        = "prod"
aws_region         = "us-west-2"
project_name       = "fsamp"
enable_nat_gateway = false # Use VPC Endpoints
use_fips_endpoint  = true  # FIPS 140-3 compliance

tags = {
  Team       = "platform"
  CostCenter = "fsamp-prod"
  DataClass  = "confidential"
  Compliance = "FIPS-140-3"
}

