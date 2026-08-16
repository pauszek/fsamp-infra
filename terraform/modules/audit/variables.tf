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
  description = "ARN of the KMS key for encryption"
  type        = string
}

variable "enable_cloudtrail" {
  description = "Enable CloudTrail for API audit logging (FedRAMP AU family)"
  type        = bool
  default     = true
}

variable "enable_guardduty" {
  description = "Enable GuardDuty for threat detection (FedRAMP SI family)"
  type        = bool
  default     = true
}

variable "enable_security_hub" {
  description = "Enable AWS Security Hub for aggregated security findings"
  type        = bool
  default     = false
}

variable "enable_aws_config" {
  description = "Enable AWS Config for compliance monitoring (FedRAMP CM family)"
  type        = bool
  default     = true
}

variable "data_bucket_arns" {
  description = "FSAMP data bucket ARNs whose object-level events are recorded by CloudTrail."
  type        = list(string)
  default     = []
}

variable "alert_topic_arn" {
  description = "Central operations SNS topic receiving security and compliance findings."
  type        = string
  default     = ""
}

variable "enable_alerting" {
  description = "Create EventBridge routes to the operations topic. Keep this plan-time value independent of the computed topic ARN."
  type        = bool
  default     = false
}
