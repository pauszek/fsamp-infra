variable "environment" {
  description = "Environment name (local, dev, staging, prod)"
  type        = string
  default     = "local"

  validation {
    condition     = contains(["local", "dev", "staging", "prod"], var.environment)
    error_message = "Environment must be one of: local, dev, staging, prod"
  }
}

variable "aws_region" {
  description = "AWS region. us-west-2 recommended for FIPS 140-3 endpoint support"
  type        = string
  default     = "us-west-2"

  validation {
    condition     = can(regex("^[a-z]{2}-[a-z]+-[0-9]$", var.aws_region))
    error_message = "AWS region must be a valid region code (e.g., us-west-2)"
  }
}

variable "project_name" {
  description = "Project name used for resource naming. Must be lowercase alphanumeric with hyphens"
  type        = string
  default     = "fsamp"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,20}$", var.project_name))
    error_message = "Project name must be 3-21 characters, lowercase alphanumeric with hyphens, starting with a letter"
  }
}

variable "tags" {
  description = "Common tags for all resources. These are merged with module-specific tags"
  type        = map(string)
  default     = {}
}
variable "vpc_cidr" {
  description = "CIDR block for VPC. Must be /16 to /24"
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "VPC CIDR must be a valid IPv4 CIDR block"
  }
}

variable "enable_nat_gateway" {
  description = <<-EOT
    Enable NAT Gateway for private subnet internet access.
    Cost: ~$32/month per gateway.
    Alternative: VPC Endpoints (enabled automatically when NAT is disabled)
    Recommendation: false for dev, true only if external API access needed
  EOT
  type        = bool
  default     = false
}
variable "use_fips_endpoint" {
  description = "Use AWS FIPS endpoints where the selected region supports them (us-* regions)"
  type        = bool
  default     = true
}

variable "enable_waf" {
  description = "Enable WAF for API Gateway. Automatically enabled in prod"
  type        = bool
  default     = null
}

variable "enable_container_insights" {
  description = "Enable CloudWatch Container Insights for ECS. Adds observability but increases costs"
  type        = bool
  default     = true
}

variable "enable_processor_ecs" {
  description = "Enable optional ECS/Fargate processor. Core runtime uses Lambda processor with SQS trigger."
  type        = bool
  default     = false
}

variable "enable_private_endpoints" {
  description = "Enable paid interface VPC endpoints for private ECS/Lambda AWS API access when NAT is disabled"
  type        = bool
  default     = true
}
variable "gateway_image_tag" {
  description = <<-EOT
    Docker image tag for the gateway ECS container image.
    Set by CI/CD pipeline; defaults to 'latest' for initial Terraform apply.
    Images are pushed to ECR by the build pipeline before deploy.
  EOT
  type        = string
  default     = "latest"
}

variable "processor_image_tag" {
  description = <<-EOT
    Docker image tag for the processor Lambda container image.
    Set by CI/CD pipeline; defaults to 'latest' for initial Terraform apply.
    Images are pushed to ECR by the build pipeline before deploy.
  EOT
  type        = string
  default     = "latest"
}
variable "enable_cloudtrail" {
  description = <<-EOT
    Enable CloudTrail for API audit logging (FedRAMP AU control family).
    Records all API calls with log file integrity validation.
    Cost: ~$2/month for management events + S3 storage.
    Enabled by default for FedRAMP AU-2 alignment; disabled automatically
    for local environment via module count gate.
  EOT
  type        = bool
  default     = true
}

variable "enable_guardduty" {
  description = <<-EOT
    Enable GuardDuty for threat detection (FedRAMP SI control family).
    Monitors CloudTrail, VPC Flow Logs, and DNS for malicious activity.
    Cost: ~$4/month for low-volume workloads.
    Enabled by default for FedRAMP SI-4 alignment; disabled automatically
    for local environment via module count gate.
  EOT
  type        = bool
  default     = true
}

variable "enable_security_hub" {
  description = <<-EOT
    Enable AWS Security Hub for aggregated security findings.
    Cost: charged per security check and finding ingestion.
    Useful for prod/secure demonstrations, optional in dev.
  EOT
  type        = bool
  default     = false
}

variable "enable_aws_config" {
  description = <<-EOT
    Enable AWS Config for compliance monitoring (FedRAMP CM control family).
    Tracks resource configuration changes and evaluates compliance rules.
    Cost: ~$2/month per rule evaluation.
    Enabled by default for FedRAMP CM-2/CM-6 alignment; disabled automatically
    for local environment via module count gate.
  EOT
  type        = bool
  default     = true
}

variable "enable_config" {
  description = "Alias for enable_aws_config. When null, enable_aws_config is used."
  type        = bool
  default     = null
}
variable "localstack_endpoint" {
  description = "LocalStack endpoint URL for local development"
  type        = string
  default     = "http://localhost:4566"
}
