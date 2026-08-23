variable "environment" {
  description = "Environment name"
  type        = string
}

variable "name_prefix" {
  description = "Prefix for resource names"
  type        = string
}

variable "tags" {
  description = "Common tags"
  type        = map(string)
}

variable "kms_key_arn" {
  description = "KMS key ARN for API Gateway and WAF log encryption"
  type        = string
}

variable "cognito_user_pool_arn" {
  description = "ARN of Cognito User Pool for authorization"
  type        = string
  default     = null
}

variable "cognito_resource_server_identifier" {
  description = "Cognito resource-server identifier used to require route-specific OAuth scopes outside the local password-flow test environment."
  type        = string
  default     = null
}

variable "enable_cognito_authorizer" {
  description = "Create and attach the Cognito User Pool authorizer for protected API methods."
  type        = bool
  default     = false
}

variable "enable_waf" {
  description = "Enable WAF for API Gateway"
  type        = bool
  default     = true
}

variable "throttle_rate_limit" {
  description = "Rate limit for API (requests per second)"
  type        = number
  default     = 100
}

variable "throttle_burst_limit" {
  description = "Burst limit for API"
  type        = number
  default     = 200
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for VPC Link"
  type        = list(string)
  default     = []
}

variable "vpc_link_security_group_ids" {
  description = "Security groups attached to API Gateway VPC Link V2 ENIs"
  type        = list(string)
  default     = []
}

variable "enable_alb_integration" {
  description = "Create API Gateway methods and VPC Link integrations for the internal ALB."
  type        = bool
  default     = false
}

variable "alb_arn" {
  description = "ARN of the internal ALB for the Gateway service"
  type        = string
  default     = null
}

variable "alb_dns_name" {
  description = "DNS name of the ALB for the Gateway service"
  type        = string
  default     = null
}

variable "alb_tls_enabled" {
  description = "Use HTTPS for VPC Link integrations to the internal ALB (must match the compute module's alb_tls_enabled)."
  type        = bool
  default     = true
}

variable "alb_tls_verified" {
  description = "The ALB certificate chain is verifiable (ACM DNS-validated certificate); integrations enforce certificate verification instead of the self-signed compensating control."
  type        = bool
  default     = false
}
