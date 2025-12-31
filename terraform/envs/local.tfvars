# =============================================================================
# Local Environment (LocalStack)
# =============================================================================
# Usage: terraform plan -var-file=envs/local.tfvars

environment         = "local"
aws_region          = "us-west-2"
project_name        = "fsamp"
enable_nat_gateway  = false
use_fips_endpoint   = false
localstack_endpoint = "http://localhost:4566"

tags = {
  Team = "development"
}

