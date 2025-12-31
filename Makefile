# =============================================================================
# FSAMP Infrastructure - Makefile
# =============================================================================

.PHONY: help init-local init-dev init-prod plan-local plan-dev plan-prod apply-local apply-dev apply-prod destroy-local fmt validate

ENV ?= local

help:
	@echo "Usage: make <target> [ENV=local|dev|prod]"
	@echo ""
	@echo "Targets:"
	@echo "  init-local    Initialize for LocalStack"
	@echo "  init-dev      Initialize for AWS dev (requires bootstrap)"
	@echo "  init-prod     Initialize for AWS prod (requires bootstrap)"
	@echo ""
	@echo "  plan-local    Plan changes for LocalStack"
	@echo "  plan-dev      Plan changes for AWS dev"
	@echo "  plan-prod     Plan changes for AWS prod"
	@echo ""
	@echo "  apply-local   Apply changes to LocalStack"
	@echo "  apply-dev     Apply changes to AWS dev"
	@echo "  apply-prod    Apply changes to AWS prod"
	@echo ""
	@echo "  fmt           Format Terraform files"
	@echo "  validate      Validate configuration"

# Local (LocalStack) - uses local backend
init-local:
	cd terraform && terraform init

plan-local:
	cd terraform && terraform plan -var-file=envs/local.tfvars

apply-local:
	cd terraform && terraform apply -var-file=envs/local.tfvars

destroy-local:
	cd terraform && terraform destroy -var-file=envs/local.tfvars

# Dev (AWS) - uses S3 backend
init-dev:
	cd terraform && terraform init -backend-config=backends/dev.hcl -reconfigure

plan-dev:
	cd terraform && terraform plan -var-file=envs/dev.tfvars

apply-dev:
	cd terraform && terraform apply -var-file=envs/dev.tfvars

# Prod (AWS) - uses S3 backend
init-prod:
	cd terraform && terraform init -backend-config=backends/prod.hcl -reconfigure

plan-prod:
	cd terraform && terraform plan -var-file=envs/prod.tfvars

apply-prod:
	cd terraform && terraform apply -var-file=envs/prod.tfvars

# Utilities
fmt:
	cd terraform && terraform fmt -recursive

validate:
	cd terraform && terraform validate

