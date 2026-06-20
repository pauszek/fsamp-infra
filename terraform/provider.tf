provider "aws" {
  region            = var.aws_region
  use_fips_endpoint = var.use_fips_endpoint && !local.is_local

  skip_credentials_validation = local.is_local
  skip_metadata_api_check     = local.is_local
  skip_requesting_account_id  = local.is_local
  access_key                  = local.is_local ? "test" : null
  secret_key                  = local.is_local ? "test" : null
  # Virtual-host bucket addressing (bucket.localhost) does not match
  # LocalStack's routing; path-style keeps S3 calls on the plain endpoint.
  s3_use_path_style = local.is_local

  dynamic "endpoints" {
    for_each = local.is_local ? [1] : []
    content {
      s3                     = var.localstack_endpoint
      sqs                    = var.localstack_endpoint
      sns                    = var.localstack_endpoint
      dynamodb               = var.localstack_endpoint
      kms                    = var.localstack_endpoint
      iam                    = var.localstack_endpoint
      sts                    = var.localstack_endpoint
      cloudwatch             = var.localstack_endpoint
      logs                   = var.localstack_endpoint
      lambda                 = var.localstack_endpoint
      events                 = var.localstack_endpoint
      secretsmanager         = var.localstack_endpoint
      ssm                    = var.localstack_endpoint
      apigateway             = var.localstack_endpoint
      ecr                    = var.localstack_endpoint
      ecs                    = var.localstack_endpoint
      cognitoidp             = var.localstack_endpoint
      ec2                    = var.localstack_endpoint
      elbv2                  = var.localstack_endpoint
      acm                    = var.localstack_endpoint
      route53                = var.localstack_endpoint
      apigatewayv2           = var.localstack_endpoint
      cloudfront             = var.localstack_endpoint
      wafv2                  = var.localstack_endpoint
      cloudtrail             = var.localstack_endpoint
      configservice          = var.localstack_endpoint
      applicationautoscaling = var.localstack_endpoint
    }
  }
}

# Replica provider used only when optional CRR is explicitly enabled. The
# baseline default points at us-west-2 and creates no replica resources; DR
# exercises must set var.replica_region to a distinct secondary region.
# LocalStack points at the same endpoint because it does not model CRR.
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
