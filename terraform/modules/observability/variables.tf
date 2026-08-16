variable "name_prefix" {
  description = "Prefix for resource names"
  type        = string
}

variable "tags" {
  description = "Common tags"
  type        = map(string)
}

variable "alarm_sns_topic_arn" {
  description = "SNS topic ARN for CloudWatch alarm notifications"
  type        = string
  default     = ""
}

variable "gateway_alb_full_name" {
  description = "Full name of the gateway ALB (e.g. app/fsamp-gw/abc123) used for ALB-side 5xx alarms."
  type        = string
  default     = ""
}

variable "gateway_alb_target_group_full_name" {
  description = "Full name of the gateway ALB target group (e.g. targetgroup/fsamp-gw/abc123) used for target-side 5xx alarms."
  type        = string
  default     = ""
}

variable "enable_alarms" {
  description = "Create CloudWatch alarms. Disabled locally: LocalStack's alarm evaluator races its own API serializer under load, and alarm evidence belongs to AWS environments."
  type        = bool
  default     = true
}

variable "enable_gateway_alarms" {
  description = "Create ALB gateway alarms. This explicit plan-time flag must not depend on computed ALB attributes."
  type        = bool
  default     = false
}

variable "enable_outbox_alarm" {
  description = "Create the outbox publish-failure alarm. This explicit plan-time flag must not depend on the computed table name."
  type        = bool
  default     = false
}
