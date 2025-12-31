# =============================================================================
# FSAMP Infrastructure - Root Module Variables
# =============================================================================
# Variables are defined here for clarity and documentation.
# Default values are suitable for local development.
# =============================================================================

# -----------------------------------------------------------------------------
# Core Configuration
# -----------------------------------------------------------------------------

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

# -----------------------------------------------------------------------------
# Networking Configuration
# -----------------------------------------------------------------------------

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

# -----------------------------------------------------------------------------
# Feature Flags
# -----------------------------------------------------------------------------

variable "enable_waf" {
  description = "Enable WAF for API Gateway. Automatically enabled in prod"
  type        = bool
  default     = null # null = auto-determine based on environment
}

variable "enable_container_insights" {
  description = "Enable CloudWatch Container Insights for ECS. Adds observability but increases costs"
  type        = bool
  default     = true
}

