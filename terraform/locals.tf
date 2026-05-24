locals {
  common_tags = merge(
    {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
      Repository  = "fsamp-infra"
      Compliance  = "FIPS-140-3-Oriented"
    },
    var.tags
  )

  name_prefix = "${var.project_name}-${var.environment}"

  is_production = var.environment == "prod"
  is_local      = var.environment == "local"

  enable_waf_computed    = coalesce(var.enable_waf, local.is_production)
  enable_config_computed = coalesce(var.enable_config, var.enable_aws_config)

  log_retention_days = 365
  key_deletion_days  = local.is_production ? 30 : 7
}
