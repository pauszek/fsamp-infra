mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
      arn        = "arn:aws:iam::123456789012:user/terraform-test"
      user_id    = "AIDATEST"
    }
  }

  mock_data "aws_partition" {
    defaults = {
      partition  = "aws"
      dns_suffix = "amazonaws.com"
    }
  }

  mock_data "aws_region" {
    defaults = {
      name = "us-west-2"
    }
  }
}

mock_provider "aws" {
  alias = "replica"
}

run "aws_plan_uses_static_resource_counts" {
  command = plan

  variables {
    environment                 = "dev"
    alarm_notification_endpoint = "alerts@fsamp.invalid"
    cognito_callback_urls       = ["https://dev.fsamp.invalid/callback"]
    cognito_logout_urls         = ["https://dev.fsamp.invalid"]
    gateway_image_digest        = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    processor_image_digest      = "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  }

  assert {
    condition     = local.deploy_edge
    error_message = "The AWS plan must include the edge stack."
  }
}
