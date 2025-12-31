# =============================================================================
# Local Environment Variables
# =============================================================================

variable "environment" {
  type    = string
  default = "local"
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

variable "localstack_endpoint" {
  type    = string
  default = "http://localhost:4566"
}

variable "tags" {
  type    = map(string)
  default = {}
}

