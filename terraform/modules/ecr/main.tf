# =============================================================================
# ECR Module - Container Registry
# =============================================================================
# Private container registry for microservices with FIPS 140-3 encryption
# =============================================================================

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.40"
    }
  }
}

# =============================================================================
# Variables
# =============================================================================

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

# =============================================================================
# Locals
# =============================================================================

locals {
  repositories = {
    gateway   = "${var.name_prefix}-gateway"
    processor = "${var.name_prefix}-processor"
  }
}

# =============================================================================
# ECR Repositories
# =============================================================================

resource "aws_ecr_repository" "repos" {
  for_each = local.repositories

  name                 = each.value
  image_tag_mutability = "IMMUTABLE" # Enterprise best practice - prevents tag overwriting

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = var.kms_key_arn
  }

  image_scanning_configuration {
    scan_on_push = var.scan_on_push
  }

  tags = merge(var.tags, {
    Name       = each.value
    Service    = each.key
    Compliance = "FIPS-140-3"
  })
}

# =============================================================================
# Lifecycle Policies (retain last N images)
# =============================================================================

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

# =============================================================================
# Repository Policies (cross-account access if needed)
# =============================================================================

data "aws_caller_identity" "current" {}

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
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
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
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
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

# =============================================================================
# Outputs
# =============================================================================

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

