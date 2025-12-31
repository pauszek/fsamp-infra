# =============================================================================
# FSAMP Infrastructure - Makefile
# =============================================================================
# Usage: make <target>
# =============================================================================

.PHONY: help init plan apply destroy fmt validate lint security clean

# Default environment
ENV ?= local

help:
	@echo "FSAMP Infrastructure Management"
	@echo ""
	@echo "Usage: make <target> [ENV=local|dev|staging|prod]"
	@echo ""
	@echo "Initialization:"
	@echo "  init-local     Initialize for LocalStack"
	@echo "  init-dev       Initialize for AWS dev"
	@echo "  init-staging   Initialize for AWS staging"
	@echo "  init-prod      Initialize for AWS prod"
	@echo ""
	@echo "Planning:"
	@echo "  plan-local     Plan changes for LocalStack"
	@echo "  plan-dev       Plan changes for AWS dev"
	@echo "  plan-staging   Plan changes for AWS staging"
	@echo "  plan-prod      Plan changes for AWS prod"
	@echo ""
	@echo "Applying:"
	@echo "  apply-local    Apply to LocalStack"
	@echo "  apply-dev      Apply to AWS dev"
	@echo "  apply-staging  Apply to AWS staging"
	@echo "  apply-prod     Apply to AWS prod (requires approval)"
	@echo ""
	@echo "Utilities:"
	@echo "  fmt            Format Terraform files"
	@echo "  validate       Validate configuration"
	@echo "  lint           Run tflint"
	@echo "  security       Run security scan (checkov)"
	@echo "  clean          Remove .terraform directories"
	@echo ""
	@echo "Docker:"
	@echo "  up             Start LocalStack"
	@echo "  down           Stop LocalStack"
	@echo "  logs           View LocalStack logs"

# -----------------------------------------------------------------------------
# Docker (LocalStack)
# -----------------------------------------------------------------------------

up:
	docker-compose up -d

down:
	docker-compose down

logs:
	docker-compose logs -f localstack

# -----------------------------------------------------------------------------
# Terraform - Local (LocalStack)
# -----------------------------------------------------------------------------

init-local:
	cd terraform && terraform init

plan-local:
	cd terraform && terraform plan -var-file=envs/local.tfvars

apply-local:
	cd terraform && terraform apply -var-file=envs/local.tfvars

destroy-local:
	cd terraform && terraform destroy -var-file=envs/local.tfvars

# -----------------------------------------------------------------------------
# Terraform - Dev (AWS)
# -----------------------------------------------------------------------------

init-dev:
	cd terraform && terraform init -reconfigure

plan-dev:
	cd terraform && terraform plan -var-file=envs/dev.tfvars

apply-dev:
	cd terraform && terraform apply -var-file=envs/dev.tfvars

destroy-dev:
	cd terraform && terraform destroy -var-file=envs/dev.tfvars

# -----------------------------------------------------------------------------
# Terraform - Staging (AWS)
# -----------------------------------------------------------------------------

init-staging:
	cd terraform && terraform init -reconfigure

plan-staging:
	cd terraform && terraform plan -var-file=envs/staging.tfvars

apply-staging:
	cd terraform && terraform apply -var-file=envs/staging.tfvars

# -----------------------------------------------------------------------------
# Terraform - Prod (AWS) - Extra safety
# -----------------------------------------------------------------------------

init-prod:
	cd terraform && terraform init -reconfigure

plan-prod:
	cd terraform && terraform plan -var-file=envs/prod.tfvars -out=prod.tfplan

apply-prod:
	@echo "⚠️  PRODUCTION DEPLOYMENT - Are you sure? [y/N]" && read ans && [ $${ans:-N} = y ]
	cd terraform && terraform apply prod.tfplan

# -----------------------------------------------------------------------------
# Utilities
# -----------------------------------------------------------------------------

fmt:
	cd terraform && terraform fmt -recursive

validate:
	cd terraform && terraform validate

lint:
	cd terraform && tflint --recursive

security:
	checkov -d terraform/ --framework terraform

clean:
	find terraform -type d -name ".terraform" -exec rm -rf {} + 2>/dev/null || true
	find terraform -name "*.tfplan" -delete 2>/dev/null || true

# -----------------------------------------------------------------------------
# CI/CD Helpers
# -----------------------------------------------------------------------------

ci-validate: fmt validate lint security

ci-plan:
	cd terraform && terraform plan -var-file=envs/$(ENV).tfvars -no-color

