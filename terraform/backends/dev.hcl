# Dev environment backend
# Usage: terraform init -backend-config=backends/dev.hcl

bucket         = "fsamp-terraform-state"
key            = "dev/terraform.tfstate"
region         = "us-west-2"
encrypt        = true
dynamodb_table = "fsamp-terraform-locks"

