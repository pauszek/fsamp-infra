provider "aws" {
  region            = var.aws_region
  use_fips_endpoint = var.use_fips_endpoint && !local.is_local

  skip_credentials_validation = local.is_local
  skip_metadata_api_check     = local.is_local
  skip_requesting_account_id  = local.is_local
  access_key                  = local.is_local ? "test" : null
  secret_key                  = local.is_local ? "test" : null

  dynamic "endpoints" {
    for_each = local.is_local ? [1] : []
    content {
      s3             = var.localstack_endpoint
      sqs            = var.localstack_endpoint
      sns            = var.localstack_endpoint
      dynamodb       = var.localstack_endpoint
      kms            = var.localstack_endpoint
      iam            = var.localstack_endpoint
      sts            = var.localstack_endpoint
      cloudwatch     = var.localstack_endpoint
      logs           = var.localstack_endpoint
      lambda         = var.localstack_endpoint
      events         = var.localstack_endpoint
      secretsmanager = var.localstack_endpoint
      ssm            = var.localstack_endpoint
      apigateway     = var.localstack_endpoint
      ecr            = var.localstack_endpoint
      ecs            = var.localstack_endpoint
      cognitoidp     = var.localstack_endpoint
    }
  }
}

# Replica region provider used for cross-region replication of CloudTrail
# logs and tenant data buckets (FedRAMP CP-9, AU-9). The region is selected
# via var.replica_region. The provider intentionally points at the same
# LocalStack endpoint for local runs because LocalStack does not model
# cross-region replication, so the provider is a no-op there.
provider "aws" {
  alias             = "replica"
  region            = var.replica_region
  use_fips_endpoint = var.use_fips_endpoint && !local.is_local

  skip_credentials_validation = local.is_local
  skip_metadata_api_check     = local.is_local
  skip_requesting_account_id  = local.is_local
  access_key                  = local.is_local ? "test" : null
  secret_key                  = local.is_local ? "test" : null

  dynamic "endpoints" {
    for_each = local.is_local ? [1] : []
    content {
      s3       = var.localstack_endpoint
      kms      = var.localstack_endpoint
      iam      = var.localstack_endpoint
      sts      = var.localstack_endpoint
      dynamodb = var.localstack_endpoint
    }
  }
}
