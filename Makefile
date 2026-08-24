.PHONY: help fmt fmt-check validate lint security clean ci-validate ci-plan up down logs init-local plan-local apply-local destroy-local seed-local local-core local-parity-up wait-localstack verify-localstack-docker-proxy local-parity-bootstrap local-parity-images local-parity-apply local-parity-plan-evidence local-demo-env local-parity-e2e local-parity-down local-parity-reset local-parity local-all init-dev plan-dev apply-dev destroy-dev init-staging plan-staging apply-staging init-prod plan-prod apply-prod

SHELL := /bin/bash

ENV ?= local
AWS_REGION ?= us-west-2
AWS_ACCOUNT_ID ?= $(shell aws sts get-caller-identity --query Account --output text 2>/dev/null)
STATE_BUCKET ?= fsamp-$(ENV)-$(AWS_ACCOUNT_ID)-$(AWS_REGION)-tfstate
LOCK_TABLE ?= fsamp-$(ENV)-terraform-locks
STATE_KEY ?= $(ENV)/terraform.tfstate
DOCKER_COMPOSE ?= docker compose
LOCALSTACK_ENDPOINT ?= http://localhost:4566
LOCAL_PARITY_IMAGE_TAG ?= local-parity
LOCAL_PARITY_E2E_IMAGE ?= fsamp-e2e-runner:local
GATEWAY_DIR ?= ../fsamp-gateway
PROCESSOR_DIR ?= ../fsamp-processor
DEMO_ENV_PATH ?= ../fsamp-demo-flow/.env.local
LOCAL_PARITY_VARS = -var-file=envs/local.tfvars -var="local_enable_edge_stack=true" -var="local_enable_lambdas=true" -var="gateway_image_tag=$(LOCAL_PARITY_IMAGE_TAG)" -var="processor_image_tag=$(LOCAL_PARITY_IMAGE_TAG)"

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
	@echo "  local-core     Apply the lightweight Terraform-managed LocalStack core"
	@echo "  local-parity   Build, apply and verify the complete LocalStack parity flow"
	@echo "  local-parity-plan-evidence"
	@echo "                 Fail on drift beyond pinned LocalStack readback gaps"
	@echo "  local-parity-e2e"
	@echo "                 Run authenticated end-to-end proof against the parity stack"
	@echo "  local-parity-down"
	@echo "                 Stop LocalStack parity containers and free the Docker network"
	@echo "  local-parity-reset"
	@echo "                 Stop LocalStack parity stack and remove its volume/network"
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
	$(DOCKER_COMPOSE) up -d

down:
	$(DOCKER_COMPOSE) down

logs:
	$(DOCKER_COMPOSE) logs -f localstack

init-local:
	AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test aws --endpoint-url $(LOCALSTACK_ENDPOINT) --region $(AWS_REGION) \
		s3api create-bucket --bucket fsamp-local-tf-state \
		--create-bucket-configuration LocationConstraint=$(AWS_REGION) 2>/dev/null || true
	cd terraform && terraform init -reconfigure -backend-config=envs/local.s3.tfbackend

# Low parallelism: LocalStack's CloudWatch emulation returns transient 500s
# under heavy concurrent DescribeAlarms load.
plan-local:
	cd terraform && terraform plan -var-file=envs/local.tfvars -parallelism=4

apply-local:
	cd terraform && terraform apply -var-file=envs/local.tfvars -parallelism=4

destroy-local:
	cd terraform && terraform destroy -var-file=envs/local.tfvars

# Seed e2e test users into the Terraform-managed Cognito pool (LocalStack).
seed-local:
	./localstack/seed-users.sh

# Lightweight LocalStack core for quick Terraform development. This creates
# the Terraform-managed core resources but intentionally skips ECS/API Gateway
# and Lambda container-image resources.
local-core:
	FSAMP_TF_MANAGED=1 $(DOCKER_COMPOSE) up -d localstack
	$(MAKE) wait-localstack
	$(MAKE) init-local
	$(MAKE) apply-local
	$(MAKE) seed-local

local-parity-up:
	FSAMP_TF_MANAGED=1 $(DOCKER_COMPOSE) up -d localstack

wait-localstack:
	@set -euo pipefail; \
	echo "Waiting for LocalStack at $(LOCALSTACK_ENDPOINT)..."; \
	for i in {1..90}; do \
		if curl -fsS "$(LOCALSTACK_ENDPOINT)/_localstack/health" >/dev/null; then \
			echo "LocalStack is ready"; \
			exit 0; \
		fi; \
		sleep 2; \
	done; \
	echo "LocalStack did not become healthy"; \
	exit 1

verify-localstack-docker-proxy:
	@$(DOCKER_COMPOSE) exec -T localstack curl -fsS http://docker-proxy:2375/_ping >/dev/null

local-parity-bootstrap:
	cd terraform && terraform apply -var-file=envs/local.tfvars \
		-target=module.security -target=module.ecr -auto-approve -parallelism=4

local-parity-images:
	GATEWAY_DIR="$(GATEWAY_DIR)" PROCESSOR_DIR="$(PROCESSOR_DIR)" \
		LOCALSTACK_ENDPOINT="$(LOCALSTACK_ENDPOINT)" AWS_REGION="$(AWS_REGION)" \
		LOCAL_PARITY_IMAGE_TAG="$(LOCAL_PARITY_IMAGE_TAG)" \
		./scripts/localstack-push-images.sh

local-parity-apply:
	cd terraform && terraform apply $(LOCAL_PARITY_VARS) -auto-approve -parallelism=4

local-parity-plan-evidence:
	@set +e; \
	cd terraform && terraform plan $(LOCAL_PARITY_VARS) -detailed-exitcode \
		-out=.terraform/local-parity-repeat.tfplan -no-color; \
	plan_exit=$$?; \
	set -e; \
	if [ "$$plan_exit" -eq 1 ]; then exit 1; fi; \
	python3 ../scripts/check-localstack-plan.py .terraform/local-parity-repeat.tfplan

local-demo-env:
	LOCALSTACK_ENDPOINT="$(LOCALSTACK_ENDPOINT)" AWS_REGION="$(AWS_REGION)" \
		./scripts/write-demo-env.sh "$(DEMO_ENV_PATH)"

local-parity-e2e: local-demo-env
	@set -euo pipefail; \
	api_host="$$(terraform -chdir=terraform output -raw api_gateway_id).execute-api.localhost.localstack.cloud"; \
	alb_host="$$(terraform -chdir=terraform output -raw gateway_alb_dns_name)"; \
	localstack_ip="$$(docker inspect --format '{{(index .NetworkSettings.Networks "fsamp-network").IPAddress}}' fsamp-localstack)"; \
	test -n "$$api_host"; \
	test -n "$$alb_host"; \
	test -n "$$localstack_ip"; \
	docker build -f e2e/Dockerfile.e2e -t "$(LOCAL_PARITY_E2E_IMAGE)" e2e; \
	docker run --rm --network fsamp-network \
		--add-host="$$api_host:$$localstack_ip" \
		--add-host="$$alb_host:$$localstack_ip" \
		--env-file "$(DEMO_ENV_PATH)" \
		-e AWS_ENDPOINT_URL=http://localstack:4566 \
		"$(LOCAL_PARITY_E2E_IMAGE)" --verbose

local-parity-down:
	@$(DOCKER_COMPOSE) down --remove-orphans || true
	@containers="$$(docker ps -aq --filter network=fsamp-network 2>/dev/null || true)"; \
	if [ -n "$$containers" ]; then \
		echo "Removing containers still attached to fsamp-network: $$containers"; \
		docker rm -f $$containers >/dev/null; \
	fi
	@$(DOCKER_COMPOSE) down --remove-orphans || true
	@docker network rm fsamp-network >/dev/null 2>&1 || true

local-parity-reset:
	@$(DOCKER_COMPOSE) down -v --remove-orphans || true
	@containers="$$(docker ps -aq --filter network=fsamp-network 2>/dev/null || true)"; \
	if [ -n "$$containers" ]; then \
		echo "Removing containers still attached to fsamp-network: $$containers"; \
		docker rm -f $$containers >/dev/null; \
	fi
	@docker network rm fsamp-network >/dev/null 2>&1 || true
	@docker volume rm fsamp-localstack-data >/dev/null 2>&1 || true

# Full LocalStack Pro parity stack: API Gateway -> ALB -> ECS gateway ->
# DynamoDB Streams -> outbox-publisher Lambda -> SNS -> SQS -> processor Lambda.
local-parity: local-parity-up wait-localstack verify-localstack-docker-proxy init-local local-parity-bootstrap local-parity-images local-parity-apply local-parity-plan-evidence seed-local local-demo-env local-parity-e2e

local-all: local-parity

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

fmt-check:
	cd terraform && terraform fmt -check -recursive

validate:
	cd terraform && terraform validate

lint:
	tflint --chdir=terraform --recursive --config "$(CURDIR)/.tflint.hcl"

security:
	checkov -d terraform/ --config-file .checkov.yml --quiet

clean:
	find terraform -type d -name ".terraform" -exec rm -rf {} + 2>/dev/null || true
	find terraform -name "*.tfplan" -delete 2>/dev/null || true

ci-validate: fmt-check validate lint security

ci-plan:
	cd terraform && terraform plan -var-file=envs/$(ENV).tfvars -no-color
