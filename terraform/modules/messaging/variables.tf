variable "environment" {
  description = "Environment name"
  type        = string
}

variable "name_prefix" {
  description = "Prefix for resource names"
  type        = string
}

variable "kms_key_id" {
  description = "ID of the KMS key for encryption"
  type        = string
}

variable "tags" {
  description = "Common tags"
  type        = map(string)
}

variable "message_retention_seconds" {
  description = "SQS message retention period in seconds"
  type        = number
  default     = 86400
}

variable "dlq_max_receive_count" {
  description = "Max receive count before moving to DLQ"
  type        = number
  default     = 3
}
