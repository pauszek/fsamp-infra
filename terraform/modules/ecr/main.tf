terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.44.0, < 7.0.0"
    }
  }
}
variable "environment" {
  description = "Environment name"
  type        = string
}

variable "name_prefix" {
  description = "Prefix for resource names"
  type        = string
}

variable "kms_key_arn" {
  description = "ARN of the KMS key for encryption"
  type        = string
}

variable "tags" {
  description = "Common tags"
  type        = map(string)
}

variable "image_retention_count" {
  description = "Number of images to retain per repository"
  type        = number
  default     = 10
}

variable "scan_on_push" {
  description = "Enable vulnerability scanning on push"
  type        = bool
  default     = true
}
locals {
  repositories = {
    gateway   = "${var.name_prefix}-gateway"
    processor = "${var.name_prefix}-processor"
  }
}
resource "aws_ecr_repository" "repos" {
  for_each = local.repositories

  name                 = each.value
  image_tag_mutability = "IMMUTABLE"

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = var.kms_key_arn
  }

  image_scanning_configuration {
    scan_on_push = var.scan_on_push
  }

  tags = merge(var.tags, {
    Name        = each.value
    Service     = each.key
    Environment = var.environment
    Compliance  = "FIPS-140-3-Oriented"
  })
}

# FedRAMP RA-5 (Vulnerability Monitoring): switch ECR registry-wide to
# Amazon Inspector enhanced scanning, which provides continuous scanning
# of in-use images and richer SBOM-based findings than the default basic
# scanner. This is a registry-wide setting; it must be applied once per
# account/region and is therefore safe to manage from this module because
# the FSAMP project owns the entire registry inside its dedicated AWS
# account boundary.
resource "aws_ecr_registry_scanning_configuration" "enhanced" {
  scan_type = "ENHANCED"

  rule {
    scan_frequency = "CONTINUOUS_SCAN"
    repository_filter {
      filter      = "${var.name_prefix}-*"
      filter_type = "WILDCARD"
    }
  }
}
resource "aws_ecr_lifecycle_policy" "repos" {
  for_each = aws_ecr_repository.repos

  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last ${var.image_retention_count} images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["v", "release"]
          countType     = "imageCountMoreThan"
          countNumber   = var.image_retention_count
        }
        action = {
          type = "expire"
        }
      },
      {
        rulePriority = 2
        description  = "Delete untagged images older than 7 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action = {
          type = "expire"
        }
      },
      {
        rulePriority = 3
        description  = "Keep only last 5 dev images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["dev", "snapshot"]
          countType     = "imageCountMoreThan"
          countNumber   = 5
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}
data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

resource "aws_ecr_repository_policy" "repos" {
  for_each = aws_ecr_repository.repos

  repository = each.value.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowPull"
        Effect = "Allow"
        Principal = {
          AWS = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action = [
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:BatchCheckLayerAvailability"
        ]
      },
      {
        Sid    = "AllowPush"
        Effect = "Allow"
        Principal = {
          AWS = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action = [
          "ecr:PutImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload"
        ]
      }
    ]
  })
}
output "repository_urls" {
  description = "ECR repository URLs"
  value = {
    for k, v in aws_ecr_repository.repos : k => v.repository_url
  }
}

output "repository_arns" {
  description = "ECR repository ARNs"
  value = {
    for k, v in aws_ecr_repository.repos : k => v.arn
  }
}

output "repository_names" {
  description = "ECR repository names"
  value = {
    for k, v in aws_ecr_repository.repos : k => v.name
  }
}
