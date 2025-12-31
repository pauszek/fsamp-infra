# =============================================================================
# Dev Environment Variables
# =============================================================================

variable "environment" {
  type    = string
  default = "dev"
}

variable "aws_region" {
  type    = string
  default = "us-west-2"
}

variable "project_name" {
  type    = string
  default = "fsamp"
}

variable "enable_nat_gateway" {
  type    = bool
  default = false
}

variable "use_fips_endpoint" {
  type    = bool
  default = true
}

variable "tags" {
  type    = map(string)
  default = {}
}

