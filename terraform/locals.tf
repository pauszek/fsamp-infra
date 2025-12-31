# =============================================================================
# FSAMP Infrastructure - Local Values
# =============================================================================
# Computed values and environment-specific settings.
# =============================================================================

locals {
  # Common tags applied to all resources
  common_tags = merge(
    {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
      Repository  = "fsamp-infra"
      Compliance  = "FIPS-140-3"
    },
    var.tags
  )

  # Name prefix for all resources (e.g., fsamp-dev, fsamp-prod)
  name_prefix = "${var.project_name}-${var.environment}"

  # Environment flags for conditional logic
  is_production = var.environment == "prod"
  is_local      = var.environment == "local"
  is_aws        = !local.is_local

  # Feature flags with environment defaults
  enable_waf_computed = coalesce(var.enable_waf, local.is_production)

  # Cost optimization settings per environment
  log_retention_days = local.is_production ? 90 : 30
  key_deletion_days  = local.is_production ? 30 : 7
}

