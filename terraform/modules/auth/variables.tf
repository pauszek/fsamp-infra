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

variable "callback_urls" {
  description = "Allowed callback URLs for OAuth"
  type        = list(string)
  default     = ["http://localhost:3000/callback"]
}

variable "logout_urls" {
  description = "Allowed logout URLs"
  type        = list(string)
  default     = ["http://localhost:3000"]
}

variable "password_min_length" {
  description = "Minimum password length"
  type        = number
  default     = 12
}

variable "access_token_validity_minutes" {
  description = "Access / ID token lifetime in minutes. FedRAMP AC-12 recommends ≤30 min for prod."
  type        = number
  default     = 60
}

variable "refresh_token_validity_days" {
  description = "Refresh token lifetime in days. Shorter values reduce session hijack window."
  type        = number
  default     = 30
}
