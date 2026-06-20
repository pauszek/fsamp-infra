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
  description = "Active AWS deployment region. FSAMP pins real AWS deployments to us-west-2 for the FIPS endpoint baseline and cost control."
  type        = string
  default     = "us-west-2"

  validation {
    condition     = var.aws_region == "us-west-2"
    error_message = "FSAMP active AWS deployments are pinned to us-west-2."
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
  description = "Use AWS FIPS endpoints in the supported us-west-2 deployment region."
  type        = bool
  default     = true
}

variable "local_enable_core_stack" {
  description = "Local (LocalStack Pro) only: provision the core stack (networking, Cognito, ECR) with the same Terraform modules as AWS environments."
  type        = bool
  default     = true
}

variable "local_enable_edge_stack" {
  description = "Local (LocalStack Pro) only: provision the edge stack (ECS/ALB/API Gateway). Requires the core stack; container images should be pushed to the local ECR for ECS tasks to start."
  type        = bool
  default     = false
}

variable "local_enable_lambdas" {
  description = "Local (LocalStack Pro) only: create the container-image Lambdas (processor, outbox publisher). They live in the compute module, so this takes effect only together with local_enable_edge_stack and needs images in the local ECR."
  type        = bool
  default     = false
}

variable "local_enable_audit" {
  description = "Local (LocalStack Pro) only: provision the audit module. CloudTrail and AWS Config are emulated and created; GuardDuty and Security Hub are forced off (not emulated)."
  type        = bool
  default     = false
}

variable "alb_certificate_mode" {
  description = "Certificate for the gateway ALB TLS listener: 'self-signed' (Terraform-managed, imported into ACM; documented SC-23 exception) or 'acm' (DNS-validated ACM certificate with a Route53 zone for alb_domain_name; removes the skip-verify exception)."
  type        = string
  default     = "self-signed"

  validation {
    condition     = contains(["self-signed", "acm"], var.alb_certificate_mode)
    error_message = "alb_certificate_mode must be 'self-signed' or 'acm'."
  }
}

variable "alb_domain_name" {
  description = "Domain name for the ALB certificate and Route53 alias when alb_certificate_mode = 'acm' (e.g. gateway.fsamp.example.com)."
  type        = string
  default     = null
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
    Docker image tag or immutable repo@sha256 digest for the gateway ECS
    container image. Deploy workflows pass a digest; 'latest' is only a
    bootstrap fallback for manual development plans.
  EOT
  type        = string
  default     = "latest"
}

variable "gateway_image_digest" {
  description = "Optional immutable digest for the gateway ECS container image (sha256:...). When set, Terraform deploys repository@digest instead of repository:tag."
  type        = string
  default     = ""

  validation {
    condition     = var.gateway_image_digest == "" || can(regex("^sha256:[a-f0-9]{64}$", var.gateway_image_digest))
    error_message = "gateway_image_digest must be empty or a sha256 digest in the form sha256:<64 lowercase hex characters>."
  }
}

variable "processor_image_tag" {
  description = <<-EOT
    Docker image tag or immutable repo@sha256 digest for the processor Lambda
    container image. Deploy workflows pass a digest; 'latest' is only a
    bootstrap fallback for manual development plans.
  EOT
  type        = string
  default     = "latest"
}

variable "processor_image_digest" {
  description = "Optional immutable digest for the processor Lambda container image (sha256:...). When set, Terraform deploys repository@digest instead of repository:tag."
  type        = string
  default     = ""

  validation {
    condition     = var.processor_image_digest == "" || can(regex("^sha256:[a-f0-9]{64}$", var.processor_image_digest))
    error_message = "processor_image_digest must be empty or a sha256 digest in the form sha256:<64 lowercase hex characters>."
  }
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

variable "localstack_internal_endpoint" {
  description = "LocalStack endpoint URL visible from containers managed by LocalStack (ECS tasks and Lambda containers). Used only for the local parity flow."
  type        = string
  default     = "http://localstack:4566"
}

variable "replica_region" {
  description = <<-EOT
    Optional secondary AWS region used only when cross-region replication is
    explicitly enabled for a higher-assurance DR exercise. The active runtime
    deployment remains pinned to var.aws_region (us-west-2). Leave the default
    unchanged when CRR is disabled; set a distinct secondary region only for an
    explicit DR validation run.
  EOT
  type        = string
  default     = "us-west-2"

  validation {
    condition     = can(regex("^[a-z]{2}-[a-z]+-[0-9]$", var.replica_region))
    error_message = "Replica region must be a valid region code (e.g., us-west-2)"
  }
}

variable "enable_cross_region_replication" {
  description = <<-EOT
    Enable optional cross-region replication for CloudTrail logs and selected
    S3 data buckets. Disabled by default for the thesis/free-tier baseline so
    the active platform creates resources only in us-west-2. Enable explicitly
    for a DR validation run that needs a passive replica region.
  EOT
  type        = bool
  default     = false
}
