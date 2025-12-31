# Local backend for LocalStack development
# Usage: terraform init -backend-config=backends/local.hcl

# Note: For local, we actually want local backend, not S3
# This file is here for consistency. Use -backend=false or local backend.

# When using LocalStack S3 for state (optional):
# bucket         = "fsamp-terraform-state"
# key            = "local/terraform.tfstate"
# region         = "us-west-2"
# encrypt        = false
# endpoint       = "http://localhost:4566"
# skip_credentials_validation = true
# skip_metadata_api_check     = true
# force_path_style            = true

