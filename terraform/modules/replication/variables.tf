variable "enabled" {
  description = "Whether to provision replica buckets and replication rules."
  type        = bool
}

variable "environment" {
  description = "Environment name."
  type        = string
}

variable "name_prefix" {
  description = "Resource name prefix."
  type        = string
}

variable "tags" {
  description = "Common tags."
  type        = map(string)
}

variable "source_buckets" {
  description = <<-EOT
    Map of source bucket logical names to their bucket id and ARN. The
    module attaches a replication configuration to each source bucket and
    creates a matching destination bucket in the replica region.
  EOT
  type = map(object({
    id  = string
    arn = string
  }))
}
