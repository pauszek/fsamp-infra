# Production environment backend
# Usage: terraform init -backend-config=backends/prod.hcl

bucket         = "fsamp-terraform-state"
key            = "prod/terraform.tfstate"
region         = "us-west-2"
encrypt        = true
dynamodb_table = "fsamp-terraform-locks"

