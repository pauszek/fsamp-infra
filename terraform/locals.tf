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
  is_staging    = var.environment == "staging"
  is_local      = var.environment == "local"

  # LocalStack Pro is a first-class deployment target: the same Terraform
  # modules provision the local environment. Core (networking, auth, ECR)
  # is on by default; the edge stack (ECS/ALB/API Gateway) and the container
  # Lambdas are opt-in because they need images in the local ECR first. Audit
  # (CloudTrail/GuardDuty/Config/Security Hub) stays off locally - not emulated.
  deploy_core = !local.is_local || var.local_enable_core_stack
  deploy_edge = local.deploy_core && (!local.is_local || var.local_enable_edge_stack)

  # FedRAMP SC-7(8): WAF is required on every internet-facing environment,
  # not just production. Staging is treated as internet-facing because it
  # exposes the same Cognito-protected API as prod for validation runs.
  enable_waf_computed    = coalesce(var.enable_waf, local.is_production || local.is_staging)
  enable_config_computed = coalesce(var.enable_config, var.enable_aws_config)

  # FedRAMP CP-9 / AU-9: replicate audit logs and tenant data to a second
  # region for prod and staging by default. Local and dev intentionally
  # skip CRR to keep iteration cheap.
  enable_crr_computed = coalesce(
    var.enable_cross_region_replication,
    local.is_production || local.is_staging
  )

  log_retention_days = 365
  key_deletion_days  = local.is_production ? 30 : 7
}
