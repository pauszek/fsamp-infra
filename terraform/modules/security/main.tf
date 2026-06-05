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

variable "tags" {
  description = "Common tags"
  type        = map(string)
}

variable "key_deletion_window" {
  description = "KMS key deletion window in days"
  type        = number
  default     = 7
}

variable "enable_key_rotation" {
  description = "Enable automatic KMS key rotation"
  type        = bool
  default     = true
}
resource "aws_kms_key" "master" {
  description             = "FSAMP Master Key - FIPS 140-3-oriented encryption"
  deletion_window_in_days = var.key_deletion_window
  enable_key_rotation     = var.enable_key_rotation
  is_enabled              = true

  key_usage                = "ENCRYPT_DECRYPT"
  customer_master_key_spec = "SYMMETRIC_DEFAULT"

  policy = jsonencode({
    Version = "2012-10-17"
    Id      = "${var.name_prefix}-key-policy"
    Statement = [
      {
        Sid    = "Enable IAM User Permissions"
        Effect = "Allow"
        Principal = {
          AWS = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "Allow Service Principals"
        Effect = "Allow"
        Principal = {
          Service = [
            "s3.amazonaws.com",
            "sqs.amazonaws.com",
            "sns.amazonaws.com",
            "dynamodb.amazonaws.com",
            "ecr.amazonaws.com",
            "config.amazonaws.com",
            "lambda.amazonaws.com",
            "logs.amazonaws.com"
          ]
        }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:DescribeKey"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "kms:CallerAccount" = data.aws_caller_identity.current.account_id
          }
          StringLike = {
            "kms:ViaService" = [
              "s3.${data.aws_region.current.region}.amazonaws.com",
              "sqs.${data.aws_region.current.region}.amazonaws.com",
              "sns.${data.aws_region.current.region}.amazonaws.com",
              "dynamodb.${data.aws_region.current.region}.amazonaws.com",
              "ecr.${data.aws_region.current.region}.amazonaws.com",
              "config.${data.aws_region.current.region}.amazonaws.com",
              "lambda.${data.aws_region.current.region}.amazonaws.com",
              "logs.${data.aws_region.current.region}.amazonaws.com"
            ]
          }
        }
      },
      {
        Sid    = "AllowCloudTrailLogEncryption"
        Effect = "Allow"
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        }
        Action = [
          "kms:GenerateDataKey*",
          "kms:DescribeKey"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:SourceArn" = "arn:${data.aws_partition.current.partition}:cloudtrail:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:trail/${var.name_prefix}-trail"
          }
          StringLike = {
            "kms:EncryptionContext:aws:cloudtrail:arn" = "arn:${data.aws_partition.current.partition}:cloudtrail:*:${data.aws_caller_identity.current.account_id}:trail/*"
          }
        }
      }
    ]
  })

  tags = merge(var.tags, {
    Name        = "${var.name_prefix}-master-key"
    Environment = var.environment
    Compliance  = "FIPS-140-3-Oriented"
    Purpose     = "Data encryption at rest"
  })

}

resource "aws_kms_alias" "master" {
  name          = "alias/${var.name_prefix}-master-key"
  target_key_id = aws_kms_key.master.key_id
}
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}
resource "aws_iam_role" "ecs_task_role" {
  name = "${var.name_prefix}-ecs-task-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "ecs_task_policy" {
  name = "${var.name_prefix}-ecs-task-policy"
  role = aws_iam_role.ecs_task_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "KMSAccess"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
          "kms:DescribeKey"
        ]
        Resource = [aws_kms_key.master.arn]
      },
      {
        Sid    = "S3Access"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket"
        ]
        Resource = [
          "arn:${data.aws_partition.current.partition}:s3:::${var.name_prefix}-*",
          "arn:${data.aws_partition.current.partition}:s3:::${var.name_prefix}-*/*"
        ]
      },
      {
        Sid    = "SQSAccess"
        Effect = "Allow"
        Action = [
          "sqs:SendMessage",
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes"
        ]
        Resource = "arn:${data.aws_partition.current.partition}:sqs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:${var.name_prefix}-*"
      },
      {
        Sid    = "SNSAccess"
        Effect = "Allow"
        Action = [
          "sns:Publish"
        ]
        Resource = "arn:${data.aws_partition.current.partition}:sns:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:${var.name_prefix}-*"
      },
      {
        Sid    = "DynamoDBAccess"
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:UpdateItem",
          "dynamodb:DeleteItem",
          "dynamodb:Query",
          "dynamodb:TransactWriteItems"
        ]
        Resource = [
          "arn:${data.aws_partition.current.partition}:dynamodb:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:table/${var.name_prefix}-*",
          "arn:${data.aws_partition.current.partition}:dynamodb:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:table/${var.name_prefix}-*/index/*"
        ]
      },
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:${data.aws_partition.current.partition}:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:/ecs/${var.name_prefix}*:*"
      }
    ]
  })
}
resource "aws_iam_role" "lambda_role" {
  name = "${var.name_prefix}-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "lambda_vpc" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_role_policy_attachment" "lambda_xray" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AWSXRayDaemonWriteAccess"
}

resource "aws_iam_role_policy" "lambda_policy" {
  name = "${var.name_prefix}-lambda-policy"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "KMSAccess"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
          "kms:DescribeKey"
        ]
        Resource = [aws_kms_key.master.arn]
      },
      {
        Sid    = "S3Access"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject"
        ]
        Resource = [
          "arn:${data.aws_partition.current.partition}:s3:::${var.name_prefix}-*/*"
        ]
      },
      {
        Sid    = "SQSAccess"
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
          "sqs:ChangeMessageVisibility"
        ]
        Resource = "arn:${data.aws_partition.current.partition}:sqs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:${var.name_prefix}-*"
      },
      {
        Sid    = "SNSPublish"
        Effect = "Allow"
        Action = [
          "sns:Publish"
        ]
        Resource = "arn:${data.aws_partition.current.partition}:sns:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:${var.name_prefix}-*"
      },
      {
        Sid    = "DynamoDBAccess"
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:UpdateItem",
          "dynamodb:DeleteItem",
          "dynamodb:Query",
          "dynamodb:TransactWriteItems",
          "dynamodb:DescribeStream",
          "dynamodb:GetRecords",
          "dynamodb:GetShardIterator",
          "dynamodb:ListStreams"
        ]
        Resource = [
          "arn:${data.aws_partition.current.partition}:dynamodb:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:table/${var.name_prefix}-*",
          "arn:${data.aws_partition.current.partition}:dynamodb:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:table/${var.name_prefix}-*/index/*",
          "arn:${data.aws_partition.current.partition}:dynamodb:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:table/${var.name_prefix}-*/stream/*"
        ]
      }
    ]
  })
}
resource "aws_iam_role" "ecs_execution_role" {
  name = "${var.name_prefix}-ecs-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "ecs_execution_policy" {
  role       = aws_iam_role.ecs_execution_role.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "ecs_execution_kms" {
  name = "${var.name_prefix}-ecs-execution-kms"
  role = aws_iam_role.ecs_execution_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "KMSDecrypt"
        Effect = "Allow"
        Action = [
          "kms:Decrypt"
        ]
        Resource = [aws_kms_key.master.arn]
      },
      {
        Sid    = "SecretsManager"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue"
        ]
        Resource = "arn:${data.aws_partition.current.partition}:secretsmanager:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:secret:${var.name_prefix}-*"
      },
      {
        Sid    = "SSMParameters"
        Effect = "Allow"
        Action = [
          "ssm:GetParameters",
          "ssm:GetParameter"
        ]
        Resource = "arn:${data.aws_partition.current.partition}:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter/${var.name_prefix}/*"
      }
    ]
  })
}
output "kms_key_arn" {
  description = "ARN of the KMS master key"
  value       = aws_kms_key.master.arn
}

output "kms_key_id" {
  description = "ID of the KMS master key"
  value       = aws_kms_key.master.key_id
}

output "kms_key_alias" {
  description = "Alias of the KMS master key"
  value       = aws_kms_alias.master.name
}

output "ecs_task_role_arn" {
  description = "ARN of the ECS task role"
  value       = aws_iam_role.ecs_task_role.arn
}

output "ecs_task_role_name" {
  description = "Name of the ECS task role"
  value       = aws_iam_role.ecs_task_role.name
}

output "ecs_execution_role_arn" {
  description = "ARN of the ECS execution role"
  value       = aws_iam_role.ecs_execution_role.arn
}

output "ecs_execution_role_name" {
  description = "Name of the ECS execution role"
  value       = aws_iam_role.ecs_execution_role.name
}

output "lambda_role_arn" {
  description = "ARN of the Lambda execution role"
  value       = aws_iam_role.lambda_role.arn
}

output "lambda_role_name" {
  description = "Name of the Lambda execution role"
  value       = aws_iam_role.lambda_role.name
}
