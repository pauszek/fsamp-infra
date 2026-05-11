# =============================================================================
# Dev Environment (AWS)
# =============================================================================
# Usage: terraform plan -var-file=envs/dev.tfvars

environment              = "dev"
aws_region               = "us-west-2"
project_name             = "fsamp"
enable_nat_gateway       = false # Use VPC Endpoints (~$30/month savings)
use_fips_endpoint        = true  # FIPS 140-3 compliance
enable_processor_ecs     = false
enable_private_endpoints = true

# Cost controls: LocalStack remains the required test path; dev keeps only core controls.
enable_cloudtrail   = true
enable_guardduty    = false
enable_security_hub = false
enable_config       = false

tags = {
  Team       = "development"
  CostCenter = "fsamp-dev"
  Compliance = "FIPS-140-3"
}
