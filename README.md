# FSAMP Infrastructure

Infrastructure as Code (IaC) for the FSAMP (File Secure Architecture Microservices Platform) using Terraform and LocalStack Pro.

## 🚀 Quick Start

```bash
# 1. Start LocalStack
docker-compose up -d

# 2. Initialize Terraform
make init-local

# 3. Deploy infrastructure
make apply-local

# 4. Verify
make plan-local
```

## 📁 Project Structure

```
terraform/
├── main.tf          # Module orchestration
├── variables.tf     # Input variables
├── outputs.tf       # Output definitions
├── locals.tf        # Computed values
├── provider.tf      # AWS/LocalStack provider
├── versions.tf      # Version constraints
├── envs/            # Environment-specific values
│   ├── local.tfvars # LocalStack
│   ├── dev.tfvars   # AWS Dev
│   └── prod.tfvars  # AWS Prod
├── backends/        # State backend configs
│   ├── local.hcl
│   ├── dev.hcl
│   └── prod.hcl
└── modules/         # Reusable modules
    ├── security/    # KMS, IAM
    ├── storage/     # S3, DynamoDB
    ├── messaging/   # SNS, SQS
    ├── networking/  # VPC, subnets
    ├── compute/     # ECS, Lambda
    ├── auth/        # Cognito
    ├── api-gateway/ # API Gateway, WAF
    ├── ecr/         # Container registry
    └── observability/ # CloudWatch
```

## 🔧 Usage

```bash
# Local (LocalStack)
make init-local
make plan-local
make apply-local

# AWS Dev
make init-dev
make plan-dev
make apply-dev

# AWS Prod
make init-prod
make plan-prod
make apply-prod

# Or directly with terraform:
terraform plan -var-file=envs/dev.tfvars
terraform apply -var-file=envs/dev.tfvars
```

## 🏗️ Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    FSAMP Infrastructure                         │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  Security Module          Storage Module         Messaging      │
│  ├── KMS Key (FIPS)       ├── S3 Buckets         ├── SNS Topics │
│  ├── IAM Roles            │   ├── files          │   ├── file-events
│  │   ├── ECS Task         │   ├── processed      │   ├── processing
│  │   └── Lambda           │   └── quarantine     │   └── dlq-alerts
│  └── IAM Policies         └── DynamoDB           ├── SQS Queues │
│                               ├── file-metadata  │   ├── processing
│                               └── events         │   ├── analysis
│                                                  │   └── dlq    │
│  Observability Module                            └──────────────┘
│  ├── CloudWatch Log Groups                                      │
│  │   ├── /ecs/{prefix}                                          │
│  │   ├── /aws/lambda/{prefix}                                   │
│  │   └── /aws/apigateway/{prefix}                               │
│  ├── CloudWatch Dashboard                                       │
│  └── CloudWatch Alarms (DLQ)                                    │
└─────────────────────────────────────────────────────────────────┘
```

## 🌍 Environments

| Environment | Backend | Use Case |
|-------------|---------|----------|
| `local` | LocalStack Pro + local state | Development, testing |
| `dev` | AWS + S3 backend | Integration testing |
| `prod` | AWS + S3 backend (encrypted) | Production |

## 🧪 Testing Strategy

### Enterprise Testing Pyramid

```
┌─────────────────────────────────────────────────────────────────┐
│              E2E Tests (fsamp-infra/e2e/)                       │
│     Full stack: Gateway + Processor + LocalStack                │
│     When: Pre-release, critical path validation                 │
│     Frequency: Per release (rare, expensive)                    │
├─────────────────────────────────────────────────────────────────┤
│          Integration Tests (per-repo)                           │
│     fsamp-gateway/docker-compose.test.yml                       │
│     fsamp-processor/docker-compose.test.yml                     │
│     Each repo has OWN LocalStack (isolation!)                   │
│     Frequency: Every commit                                     │
├─────────────────────────────────────────────────────────────────┤
│              Unit Tests (per-repo)                              │
│     Mocks, no Docker, fast                                      │
│     Frequency: Every commit                                     │
└─────────────────────────────────────────────────────────────────┘
```

### Key Principles

1. **Isolation**: Each repo has its own LocalStack - no shared state between test runs
2. **Cloud Pods**: Save/restore LocalStack state for consistent baselines
3. **Fast Feedback**: Unit tests > Integration > E2E (pyramid approach)
4. **Single Source of Truth**: `fsamp-infra` = infrastructure definition

### Docker Compose Structure

```
fsamp-infra/
  docker-compose.yml           ← LocalStack for Terraform testing
  docker-compose.override.yml  ← Local dev overrides (gitignored)
  e2e/
    docker-compose.yml         ← Full stack E2E (used later)

fsamp-gateway/
  docker-compose.test.yml      ← Gateway + own LocalStack

fsamp-processor/
  docker-compose.test.yml      ← Processor + own LocalStack
```

## 🚀 Quick Start

### Prerequisites

- Docker & Docker Compose
- Terraform >= 1.7.0
- AWS CLI v2
- LocalStack Pro auth token

### Setup

```bash
# 1. Clone and enter directory
cd fsamp-infra

# 2. Configure environment
cp .env.example .env
# Edit .env and add your LOCALSTACK_AUTH_TOKEN

# 3. (Optional) Create local overrides
cp docker-compose.override.yml.example docker-compose.override.yml
```

### Local Development

```bash
# 1. Start LocalStack
docker-compose up -d

# 2. Wait for initialization
docker-compose logs -f localstack
# Wait for "LocalStack initialization complete!"

# 3. Deploy with Terraform
cd terraform/environments/local
terraform init
terraform apply

# 4. Verify resources
../../scripts/localstack-test.sh
```

### Cloud Pods (State Snapshots)

```bash
# Save infrastructure state (after terraform apply)
./scripts/cloud-pods.sh save fsamp-local-base

# Load state on new machine or in CI
./scripts/cloud-pods.sh load fsamp-local-base

# List available pods
./scripts/cloud-pods.sh list
```

### E2E Tests (when services exist)

```bash
cd e2e
./run-e2e.sh --local    # Use locally built images
./run-e2e.sh --ci       # CI mode (no TTY)
```

## 📁 Project Structure

```
fsamp-infra/
├── docker-compose.yml              # LocalStack Pro (single source of truth)
├── docker-compose.override.yml.example  # Local overrides template
├── localstack/
│   └── init-aws.sh                 # Bootstrap script
├── scripts/
│   ├── localstack-test.sh          # Resource verification
│   └── cloud-pods.sh               # Cloud Pods management
├── e2e/
│   ├── docker-compose.yml          # Full stack E2E composition
│   ├── run-e2e.sh                  # E2E test runner
│   └── README.md                   # E2E documentation
├── terraform/
│   ├── main.tf                     # Root module
│   ├── versions.tf                 # Provider versions
│   ├── environments/
│   │   ├── local/                  # LocalStack (local backend)
│   │   ├── dev/                    # AWS dev (S3 backend)
│   │   └── prod/                   # AWS prod (S3 backend)
│   └── modules/
│       ├── security/               # KMS, IAM
│       ├── storage/                # S3, DynamoDB
│       ├── messaging/              # SNS, SQS
│       └── observability/          # CloudWatch
├── .tflint.hcl
├── .gitignore
├── .env.example                    # Environment variables template
├── release.version
└── README.md
```

## 🔐 Security Features

| Feature | Implementation |
|---------|----------------|
| **FIPS 140-3 Encryption** | AWS KMS with AES-256-GCM, automatic key rotation |
| **Least Privilege IAM** | Separate roles for ECS/Lambda with scoped policies |
| **IAM Enforcement** | LocalStack Pro ENFORCE_IAM for realistic testing |
| **Encrypted Storage** | S3 SSE-KMS, DynamoDB encryption at rest |
| **Encrypted Messaging** | SQS/SNS with KMS encryption |
| **S3 Hardening** | Versioning, lifecycle policies, public access blocked |
| **DLQ Monitoring** | CloudWatch alarms on dead letter queue |

## 🔄 CI/CD

| Trigger | Actions |
|---------|---------|
| PR | `terraform fmt`, `terraform validate`, `tflint`, `checkov` |
| Push to main | Tag release, bump version PR |

## 📊 Resource Naming Convention

All resources follow: `{project}-{environment}-{resource}`

Example for `local`:
- S3: `fsamp-local-files`, `fsamp-local-processed`
- DynamoDB: `fsamp-local-file-metadata`, `fsamp-local-events`
- SQS: `fsamp-local-file-processing`, `fsamp-local-dlq`
- KMS: `alias/fsamp-local-master-key`

## 📝 License

MIT
