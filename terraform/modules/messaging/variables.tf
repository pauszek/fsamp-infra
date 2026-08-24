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

variable "enable_e2e_audit_queues" {
  description = "Create local-only SNS audit subscriptions used to prove both event streams end to end."
  type        = bool
  default     = false
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

variable "processor_timeout_seconds" {
  description = "Processor Lambda timeout used to derive an SQS visibility timeout of at least six times the function timeout plus the batch window."
  type        = number
  default     = 300

  validation {
    condition     = var.processor_timeout_seconds >= 1 && var.processor_timeout_seconds <= 7199
    error_message = "processor_timeout_seconds must keep the derived SQS visibility timeout within the AWS limit."
  }
}

variable "alarm_notification_endpoint" {
  description = "Email or HTTPS endpoint subscribed to the central operations topic."
  type        = string
  default     = ""
  sensitive   = true
}

variable "alarm_notification_protocol" {
  description = "SNS protocol for the central operations subscription."
  type        = string
  default     = "email"

  validation {
    condition     = contains(["email", "https"], var.alarm_notification_protocol)
    error_message = "alarm_notification_protocol must be email or https."
  }
}
