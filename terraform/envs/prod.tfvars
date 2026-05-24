
environment              = "prod"
aws_region               = "us-west-2"
project_name             = "fsamp"
enable_nat_gateway       = false
use_fips_endpoint        = true
enable_processor_ecs     = false
enable_private_endpoints = true

enable_cloudtrail   = true
enable_guardduty    = true
enable_security_hub = true
enable_config       = true

tags = {
  Team       = "platform"
  CostCenter = "fsamp-prod"
  DataClass  = "confidential"
  Compliance = "FIPS-140-3-Oriented"
}
