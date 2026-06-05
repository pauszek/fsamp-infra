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
  description = "KMS key ARN for CloudWatch log encryption"
  type        = string
}

variable "log_retention_days" {
  description = "CloudWatch log retention in days"
  type        = number
  default     = 30
}

variable "alarm_sns_topic_arn" {
  description = "SNS topic ARN for CloudWatch alarm notifications"
  type        = string
  default     = ""
}

variable "gateway_alb_full_name" {
  description = "Full name of the gateway ALB (e.g. app/fsamp-gw/abc123) used for ALB-side 5xx alarms. Empty value disables the alarm."
  type        = string
  default     = ""
}

variable "gateway_alb_target_group_full_name" {
  description = "Full name of the gateway ALB target group (e.g. targetgroup/fsamp-gw/abc123) used for target-side 5xx alarms. Empty value disables the alarm."
  type        = string
  default     = ""
}

variable "outbox_table_name" {
  description = "DynamoDB outbox table name. Empty value disables the stuck outbox alarm."
  type        = string
  default     = ""
}
