
environment              = "dev"
aws_region               = "us-west-2"
project_name             = "fsamp"
enable_nat_gateway       = false
use_fips_endpoint        = true
enable_processor_ecs     = false
enable_private_endpoints = true

enable_cloudtrail   = true
enable_guardduty    = false
enable_security_hub = false
enable_config       = false

tags = {
  Team       = "development"
  CostCenter = "fsamp-dev"
  Compliance = "FIPS-140-3-Oriented"
}
