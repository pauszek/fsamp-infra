.PHONY: help init plan apply destroy fmt validate lint security clean

ENV ?= local
AWS_REGION ?= us-west-2
AWS_ACCOUNT_ID ?= $(shell aws sts get-caller-identity --query Account --output text 2>/dev/null)
STATE_BUCKET ?= fsamp-$(ENV)-$(AWS_ACCOUNT_ID)-$(AWS_REGION)-tfstate
LOCK_TABLE ?= fsamp-$(ENV)-terraform-locks
STATE_KEY ?= $(ENV)/terraform.tfstate

init-dev plan-dev apply-dev destroy-dev: ENV=dev
init-staging plan-staging apply-staging: ENV=staging
init-prod plan-prod apply-prod: ENV=prod

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

up:
	docker-compose up -d

down:
	docker-compose down

logs:
	docker-compose logs -f localstack

init-local:
	cd terraform && terraform init -backend=false

plan-local:
	cd terraform && terraform plan -var-file=envs/local.tfvars

apply-local:
	cd terraform && terraform apply -var-file=envs/local.tfvars

destroy-local:
	cd terraform && terraform destroy -var-file=envs/local.tfvars

init-dev:
	cd terraform && terraform init -reconfigure \
		-backend-config="bucket=$(STATE_BUCKET)" \
		-backend-config="key=$(STATE_KEY)" \
		-backend-config="region=$(AWS_REGION)" \
		-backend-config="dynamodb_table=$(LOCK_TABLE)" \
		-backend-config="encrypt=true"

plan-dev:
	cd terraform && terraform plan -var-file=envs/dev.tfvars

apply-dev:
	cd terraform && terraform apply -var-file=envs/dev.tfvars

destroy-dev:
	cd terraform && terraform destroy -var-file=envs/dev.tfvars

init-staging:
	cd terraform && terraform init -reconfigure \
		-backend-config="bucket=$(STATE_BUCKET)" \
		-backend-config="key=$(STATE_KEY)" \
		-backend-config="region=$(AWS_REGION)" \
		-backend-config="dynamodb_table=$(LOCK_TABLE)" \
		-backend-config="encrypt=true"

plan-staging:
	cd terraform && terraform plan -var-file=envs/staging.tfvars

apply-staging:
	cd terraform && terraform apply -var-file=envs/staging.tfvars

init-prod:
	cd terraform && terraform init -reconfigure \
		-backend-config="bucket=$(STATE_BUCKET)" \
		-backend-config="key=$(STATE_KEY)" \
		-backend-config="region=$(AWS_REGION)" \
		-backend-config="dynamodb_table=$(LOCK_TABLE)" \
		-backend-config="encrypt=true"

plan-prod:
	cd terraform && terraform plan -var-file=envs/prod.tfvars -out=prod.tfplan

apply-prod:
	@echo "PRODUCTION DEPLOYMENT - Are you sure? [y/N]" && read ans && [ $${ans:-N} = y ]
	cd terraform && terraform apply prod.tfplan

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

ci-validate: fmt validate lint security

ci-plan:
	cd terraform && terraform plan -var-file=envs/$(ENV).tfvars -no-color
