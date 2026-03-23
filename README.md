# FSAMP Infrastructure

[![Terraform](https://img.shields.io/badge/Terraform-1.6+-623CE4?logo=terraform)](https://www.terraform.io/)
[![AWS](https://img.shields.io/badge/AWS-Cloud-FF9900?logo=amazonaws)](https://aws.amazon.com/)
[![LocalStack](https://img.shields.io/badge/LocalStack-Pro-4A154B?logo=docker)](https://localstack.cloud/)
[![FIPS 140-3](https://img.shields.io/badge/FIPS-140--3-green)](https://csrc.nist.gov/publications/detail/fips/140/3/final)

> Infrastructure as Code (IaC) for a secure, event-driven microservices platform on AWS.
> 
> **Master's Thesis Project**: *Bezpieczna platforma mikroserwisowa w chmurze AWS z wykorzystaniem architektury sterowanej zdarzeniami i infrastruktury jako kod (IaC)*

## 🏗️ Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        FSAMP Platform Architecture                           │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌──────────────┐    ┌─────────────┐    ┌─────────────────────────────────┐ │
│  │   Cognito    │    │ API Gateway │    │         CloudWatch              │ │
│  │   (Auth)     │───▶│   + WAF     │    │   Logs │ Metrics │ Alarms      │ │
│  └──────────────┘    └──────┬──────┘    └─────────────────────────────────┘ │
│                             │                                                │
│  ┌──────────────────────────┼──────────────────────────────────────────────┐│
│  │                     VPC (Private Subnets)                                ││
│  │                          │                                               ││
│  │    ┌─────────────────────▼─────────────────────┐                        ││
│  │    │              ECS Fargate                   │                        ││
│  │    │  ┌─────────────┐    ┌─────────────────┐   │                        ││
│  │    │  │   Gateway   │    │    Processor    │   │                        ││
│  │    │  │  (Spring)   │    │    (Python)     │   │                        ││
│  │    │  └──────┬──────┘    └────────▲────────┘   │                        ││
│  │    └─────────┼────────────────────┼────────────┘                        ││
│  │              │                    │                                      ││
│  │    ┌─────────▼─────────┐  ┌───────┴────────┐                            ││
│  │    │   SNS Topics      │  │   SQS Queues   │                            ││
│  │    │  (file-events)    │─▶│  (processing)  │                            ││
│  │    └───────────────────┘  │  (DLQ)         │                            ││
│  │                           └────────────────┘                            ││
│  │              │                    │                                      ││
│  │    ┌─────────▼─────────────────────▼────────┐                           ││
│  │    │               Storage                   │                           ││
│  │    │   S3 (files)  │  DynamoDB (metadata)   │                           ││
│  │    └───────────────┼────────────────────────┘                           ││
│  │                    │                                                     ││
│  │    ┌───────────────▼────────────────────────┐                           ││
│  │    │           KMS (FIPS 140-3)             │                           ││
│  │    │     Encryption at rest & in transit    │                           ││
│  │    └────────────────────────────────────────┘                           ││
│  └──────────────────────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────────────────────┘
```

## 🚀 Quick Start

### Prerequisites

- [Docker](https://www.docker.com/) & Docker Compose
- [Terraform](https://www.terraform.io/) >= 1.6
- [AWS CLI](https://aws.amazon.com/cli/) v2
- [LocalStack Pro](https://localstack.cloud/) license (for local development)

### Local Development (LocalStack)

```bash
# 1. Set LocalStack token
export LOCALSTACK_AUTH_TOKEN=your-token

# 2. Start LocalStack
make up

# 3. Initialize & apply Terraform
make init-local
make apply-local

# 4. Verify resources
aws --endpoint-url=http://localhost:4566 s3 ls
aws --endpoint-url=http://localhost:4566 sqs list-queues
```

### AWS Deployment

```bash
# 1. Configure AWS credentials
aws configure

# 2. Initialize for dev environment
make init-dev

# 3. Plan and review changes
make plan-dev

# 4. Apply infrastructure
make apply-dev
```

## 📁 Repository Structure

```
fsamp-infra/
├── terraform/
│   ├── main.tf              # Module composition
│   ├── variables.tf         # Input variables
│   ├── outputs.tf           # Output values
│   ├── locals.tf            # Computed values
│   ├── provider.tf          # AWS/LocalStack provider
│   ├── versions.tf          # Provider versions
│   ├── envs/                # Environment configurations
│   │   ├── local.tfvars     # LocalStack settings
│   │   ├── dev.tfvars       # AWS dev settings
│   │   ├── staging.tfvars   # AWS staging settings
│   │   └── prod.tfvars      # AWS prod settings
│   └── modules/             # Terraform modules
│       ├── api-gateway/     # REST API + WAF
│       ├── auth/            # Cognito User Pool
│       ├── compute/         # ECS Fargate + Lambda
│       ├── ecr/             # Container Registry
│       ├── messaging/       # SNS + SQS
│       ├── networking/      # VPC + Endpoints
│       ├── observability/   # CloudWatch + X-Ray
│       ├── security/        # KMS + IAM
│       └── storage/         # S3 + DynamoDB
├── docs/
│   └── adr/                 # Architecture Decision Records
├── e2e/                     # End-to-end tests
├── docker-compose.yml       # LocalStack configuration
├── Makefile                 # Task automation
└── README.md                # This file
```

## 🔐 Security Features

### FIPS 140-3 Compliance

- **KMS Encryption**: All data encrypted at rest using AWS KMS (FIPS 140-3 Level 3 validated)
- **Encryption in Transit**: TLS 1.2+ for all communications
- **FIPS Endpoints**: Enabled in supported regions (us-*)

### Multi-Layer Security

| Layer | Implementation |
|-------|----------------|
| **Identity** | Cognito User Pools with MFA |
| **Network** | VPC, Security Groups, VPC Endpoints |
| **Application** | WAF rules, API throttling |
| **Data** | KMS encryption, S3 bucket policies |
| **Monitoring** | CloudWatch, CloudTrail, GuardDuty |

## 📊 Environments

| Environment | Purpose | Infrastructure |
|-------------|---------|----------------|
| `local` | Development | LocalStack (Docker) |
| `dev` | Integration testing | AWS (minimal resources) |
| `staging` | Pre-production | AWS (production-like) |
| `prod` | Production | AWS (full redundancy) |

## 🛠️ Make Targets

```bash
make help           # Show all available targets

# Docker (LocalStack)
make up             # Start LocalStack
make down           # Stop LocalStack
make logs           # View LocalStack logs

# Terraform
make init-local     # Initialize for LocalStack
make plan-local     # Plan changes
make apply-local    # Apply changes
make destroy-local  # Destroy resources

# Same for dev/staging/prod:
make init-dev       # Initialize for AWS dev
make plan-dev       # Plan changes
make apply-dev      # Apply changes
```

## 📚 Architecture Decisions

Key architecture decisions are documented in [ADRs](docs/adr/):

- [ADR-001: LocalStack for Local Development](docs/adr/001-use-localstack-for-local-development.md)
- [ADR-002: Event-Driven Architecture](docs/adr/002-event-driven-architecture.md)
- [ADR-003: ECS Fargate over EKS](docs/adr/003-ecs-fargate-over-eks.md)
- [ADR-004: FIPS 140-3 Encryption](docs/adr/004-fips-140-3-encryption.md)
- [ADR-005: VPC Endpoints over NAT](docs/adr/005-vpc-endpoints-over-nat.md)
- [ADR-006: Multi-Repository Architecture](docs/adr/006-multi-repository-architecture.md)

## 🔗 Related Repositories

| Repository | Description | Tech Stack |
|------------|-------------|------------|
| [fsamp-gateway](https://github.com/your-org/fsamp-gateway) | API Gateway Service | Spring Boot, Java 21, ACCP |
| [fsamp-processor](https://github.com/your-org/fsamp-processor) | File Processing Service | Python 3.14, Lambda |

## 💰 Cost Optimization

This infrastructure is designed to operate within AWS Free Tier where possible:

- **ECS Fargate** instead of EKS (~$100/month savings)
- **VPC Endpoints** instead of NAT Gateway (~$30/month savings)
- **FARGATE_SPOT** for non-prod workloads (~70% savings)
- **S3 Bucket Keys** for KMS cost reduction (~90% reduction)

Estimated monthly cost: **~$15-25** (Free Tier + minimal usage)

## 📄 License

This project is developed as part of a Master's Thesis. All rights reserved.

## 🤝 Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for contribution guidelines.

