# FSAMP Infrastructure

Infrastructure as Code (IaC) for the FSAMP (File Secure Architecture Microservices Platform) using Terraform and LocalStack Pro.

## 🚀 Quick Start

```bash
# 1. Start LocalStack
docker-compose up -d

# 2. Initialize & Deploy
make init-local
make apply-local

# 3. Verify
make plan-local
```

## 📁 Project Structure

```
terraform/
├── main.tf              # Module orchestration
├── variables.tf         # Input variables (with validation)
├── outputs.tf           # Output definitions
├── locals.tf            # Computed values
├── provider.tf          # AWS/LocalStack provider (dynamic)
├── versions.tf          # Version constraints
├── envs/                # Environment values ONLY
│   ├── local.tfvars     #   └── LocalStack
│   ├── dev.tfvars       #   └── AWS Dev
│   ├── staging.tfvars   #   └── AWS Staging
│   └── prod.tfvars      #   └── AWS Prod
└── modules/             # Reusable modules
    ├── security/        #   └── KMS, IAM
    ├── storage/         #   └── S3, DynamoDB
    ├── messaging/       #   └── SNS, SQS
    ├── networking/      #   └── VPC, Subnets, Endpoints
    ├── compute/         #   └── ECS Fargate, Lambda
    ├── auth/            #   └── Cognito
    ├── api-gateway/     #   └── API Gateway, WAF
    ├── ecr/             #   └── Container Registry
    └── observability/   #   └── CloudWatch
```

## 🔧 Usage

```bash
# Local (LocalStack)
make up              # Start LocalStack
make init-local      # Initialize
make plan-local      # Plan changes
make apply-local     # Apply changes

# AWS Environments
make init-dev && make plan-dev && make apply-dev
make init-staging && make plan-staging && make apply-staging
make init-prod && make plan-prod && make apply-prod

# Utilities
make fmt             # Format code
make validate        # Validate config
make lint            # Run tflint
make security        # Run checkov security scan
```

## 🏗️ Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         FSAMP Platform                                   │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐                 │
│  │ API Gateway │───▶│   Cognito   │    │     WAF     │                 │
│  │  (REST)     │    │   (Auth)    │    │  (Prod)     │                 │
│  └──────┬──────┘    └─────────────┘    └─────────────┘                 │
│         │                                                                │
│         ▼                                                                │
│  ┌─────────────┐         ┌─────────────┐         ┌─────────────┐       │
│  │ ECS Fargate │────────▶│  SNS/SQS    │────────▶│   Lambda    │       │
│  │  (Gateway)  │         │ (Events)    │         │ (Processor) │       │
│  └──────┬──────┘         └─────────────┘         └──────┬──────┘       │
│         │                                                │              │
│         ▼                                                ▼              │
│  ┌─────────────────────────────────────────────────────────────┐       │
│  │                        Storage Layer                         │       │
│  │  ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────────────┐ │       │
│  │  │   S3    │  │   S3    │  │   S3    │  │    DynamoDB     │ │       │
│  │  │ (files) │  │(process)│  │(quarant)│  │   (metadata)    │ │       │
│  │  └─────────┘  └─────────┘  └─────────┘  └─────────────────┘ │       │
│  └─────────────────────────────────────────────────────────────┘       │
│                                                                          │
│  ┌─────────────────────────────────────────────────────────────┐       │
│  │                    Security & Observability                   │       │
│  │  KMS (FIPS 140-3) │ IAM │ CloudWatch │ VPC │ VPC Endpoints  │       │
│  └─────────────────────────────────────────────────────────────┘       │
└─────────────────────────────────────────────────────────────────────────┘
```

## 🌍 Environments

| Environment | Provider | State | Use Case |
|-------------|----------|-------|----------|
| `local` | LocalStack | Local file | Development |
| `dev` | AWS | S3 | Integration testing |
| `staging` | AWS | S3 | Pre-production |
| `prod` | AWS | S3 (encrypted) | Production |

## 🔐 Security Features

| Feature | Implementation |
|---------|----------------|
| **FIPS 140-3** | AWS KMS with AES-256-GCM, FIPS endpoints |
| **Encryption at Rest** | S3 SSE-KMS, DynamoDB, SQS, SNS |
| **Encryption in Transit** | TLS 1.2+, VPC Endpoints |
| **IAM** | Least privilege roles (ECS, Lambda) |
| **Authentication** | Cognito with MFA (prod) |
| **WAF** | API Gateway protection (prod) |
| **Network** | Private subnets, no NAT (VPC Endpoints) |
| **Monitoring** | CloudWatch, DLQ alerts |

## 🧪 Testing

```bash
# Local testing with LocalStack
make up
make apply-local

# Security scan
make security

# E2E tests (when services ready)
cd e2e && ./run-e2e.sh
```

## 📚 Architecture Decision Records

| ADR | Decision |
|-----|----------|
| [001](docs/adr/001-use-localstack-for-local-development.md) | LocalStack for local dev |
| [002](docs/adr/002-event-driven-architecture.md) | Event-driven with SNS/SQS |
| [003](docs/adr/003-ecs-fargate-over-eks.md) | ECS Fargate over EKS (cost) |
| [004](docs/adr/004-fips-140-3-encryption.md) | FIPS 140-3 encryption |
| [005](docs/adr/005-vpc-endpoints-over-nat.md) | VPC Endpoints over NAT (cost) |
| [006](docs/adr/006-multi-repository-architecture.md) | Multi-repo architecture |

## 💰 Cost Optimization

| Decision | Savings |
|----------|---------|
| ECS Fargate vs EKS | ~$73/month (no control plane) |
| VPC Endpoints vs NAT | ~$30/month |
| FARGATE_SPOT | Up to 70% on non-critical |
| S3 Lifecycle policies | Auto-archive to Glacier |

## 🔗 Related Repositories

| Repository | Purpose |
|------------|---------|
| `fsamp-gateway` | Spring Boot API Gateway |
| `fsamp-processor` | Python Lambda Processor |

## 📖 Documentation

- [Contributing](CONTRIBUTING.md)
- [Security Policy](SECURITY.md)
- [Architecture Decisions](docs/adr/)

## 📝 License

MIT

