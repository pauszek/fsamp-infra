# FSAMP Infrastructure

Infrastructure as Code (IaC) for the FSAMP (File Secure Architecture Microservices Platform).

**Master's Thesis Project**: *Bezpieczna platforma mikroserwisowa w chmurze AWS z wykorzystaniem architektury sterowanej zdarzeniami i infrastruktury jako kod (IaC)*

## 🏗️ Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         FSAMP Platform Architecture                          │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌─────────────┐     ┌─────────────┐     ┌─────────────────────────────────┐│
│  │   Client    │────▶│ API Gateway │────▶│    Application Load Balancer   ││
│  │  (Browser)  │     │  + WAF      │     │                                 ││
│  └─────────────┘     └──────┬──────┘     └───────────────┬─────────────────┘│
│                             │                             │                  │
│                      ┌──────┴──────┐                      │                  │
│                      │   Cognito   │                      │                  │
│                      │  User Pool  │                      │                  │
│                      └─────────────┘                      │                  │
│                                                           ▼                  │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │                        ECS Fargate Cluster                              │ │
│  │  ┌────────────────────────┐     ┌─────────────────────────────────┐   │ │
│  │  │   Spring Gateway       │     │   (Future: Python Processor)    │   │ │
│  │  │   - REST API           │     │   - Async processing            │   │ │
│  │  │   - FIPS 140-3 crypto  │     │   - File analysis               │   │ │
│  │  └───────────┬────────────┘     └─────────────────────────────────┘   │ │
│  └──────────────┼────────────────────────────────────────────────────────┘ │
│                 │                                                           │
│  ┌──────────────┼───────────────────────────────────────────────────────┐  │
│  │              │         Event-Driven Architecture                      │  │
│  │              ▼                                                        │  │
│  │  ┌───────────────────┐     ┌───────────────────┐                     │  │
│  │  │   SNS Topics      │────▶│   SQS Queues      │                     │  │
│  │  │   - file-events   │     │   - processing    │                     │  │
│  │  │   - proc-events   │     │   - analysis      │──────┐              │  │
│  │  │   - dlq-alerts    │     │   - dlq           │      │              │  │
│  │  └───────────────────┘     └───────────────────┘      │              │  │
│  │                                                        ▼              │  │
│  │  ┌────────────────────────────────────────┐    ┌─────────────────┐   │  │
│  │  │           Lambda Processor             │    │   CloudWatch    │   │  │
│  │  │   - Python 3.12                        │    │   - Logs        │   │  │
│  │  │   - Event processing                   │    │   - Alarms      │   │  │
│  │  │   - Idempotency (DynamoDB)             │    │   - Dashboard   │   │  │
│  │  └────────────────────────────────────────┘    └─────────────────┘   │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
│                                                                             │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │                            Storage Layer                              │  │
│  │  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐       │  │
│  │  │  S3: files      │  │  S3: processed  │  │  S3: quarantine │       │  │
│  │  │  (SSE-KMS)      │  │  (SSE-KMS)      │  │  (SSE-KMS)      │       │  │
│  │  └─────────────────┘  └─────────────────┘  └─────────────────┘       │  │
│  │  ┌─────────────────────────────┐  ┌───────────────────────────────┐  │  │
│  │  │  DynamoDB: file-metadata   │  │  DynamoDB: events             │  │  │
│  │  │  (KMS encrypted, PITR)     │  │  (KMS encrypted, PITR)        │  │  │
│  │  └─────────────────────────────┘  └───────────────────────────────┘  │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
│                                                                             │
│  ════════════════════════ Security Layer ═══════════════════════════════   │
│  KMS (FIPS 140-3) │ IAM │ VPC │ Security Groups │ NACLs │ VPC Flow Logs    │
└─────────────────────────────────────────────────────────────────────────────┘
```

## 🌍 Environments

| Environment | Target | Modules Deployed | State Backend |
|-------------|--------|------------------|---------------|
| `local` | LocalStack Pro | security, storage, messaging, observability | Local file |
| `dev` | AWS Free Tier | All modules (ECR, Cognito, API GW, etc.) | S3 + DynamoDB |
| `prod` | AWS | All modules + WAF enabled | S3 + DynamoDB |

## 📦 Terraform Modules

| Module | Resources | Local | AWS |
|--------|-----------|-------|-----|
| `security` | KMS, IAM Roles & Policies | ✅ | ✅ |
| `storage` | S3 Buckets, DynamoDB Tables | ✅ | ✅ |
| `messaging` | SNS Topics, SQS Queues, DLQ | ✅ | ✅ |
| `observability` | CloudWatch Logs, Dashboard, Alarms | ✅ | ✅ |
| `networking` | VPC, Subnets, Security Groups, VPC Endpoints | ❌ | ✅ |
| `compute` | ECS Cluster, Task Definitions, Lambda | ❌ | ✅ |
| `ecr` | Container Registry | ❌ | ✅ |
| `auth` | Cognito User Pool, App Clients | ❌ | ✅ |
| `api-gateway` | REST API, WAF | ❌ | ✅ |

## 🚀 Quick Start

### Prerequisites

- Docker & Docker Compose
- Terraform >= 1.7.0
- AWS CLI v2
- LocalStack Pro token (`LOCALSTACK_AUTH_TOKEN`)

### Local Development (LocalStack)

```bash
# 1. Setup
cp .env.example .env
# Edit .env - add LOCALSTACK_AUTH_TOKEN

# 2. Start LocalStack
docker-compose up -d

# 3. Deploy infrastructure
cd terraform/environments/local
terraform init
terraform apply

# 4. Verify
./scripts/localstack-test.sh
```

### AWS Deployment

```bash
# 1. Bootstrap remote state (one-time)
./scripts/bootstrap-terraform-state.sh

# 2. Uncomment backend in terraform/environments/dev/main.tf

# 3. Deploy
cd terraform/environments/dev
terraform init
terraform apply
```

## 📁 Project Structure

```
fsamp-infra/
├── docker-compose.yml              # LocalStack Pro
├── localstack/
│   └── init-aws.sh                 # Auto-creates resources on startup
├── scripts/
│   ├── localstack-test.sh          # Verify LocalStack resources
│   ├── cloud-pods.sh               # Save/load LocalStack state
│   └── bootstrap-terraform-state.sh # Setup S3 backend for AWS
├── docs/
│   └── adr/                        # Architecture Decision Records
├── e2e/                            # E2E tests (when apps exist)
├── terraform/
│   ├── main.tf                     # Root module
│   ├── environments/
│   │   ├── local/                  # LocalStack config
│   │   ├── dev/                    # AWS dev config
│   │   └── prod/                   # AWS prod config
│   └── modules/
│       ├── security/               # KMS, IAM
│       ├── storage/                # S3, DynamoDB
│       ├── messaging/              # SNS, SQS
│       ├── networking/             # VPC, Subnets
│       ├── compute/                # ECS, Lambda
│       ├── ecr/                    # Container Registry
│       ├── auth/                   # Cognito
│       ├── api-gateway/            # REST API + WAF
│       └── observability/          # CloudWatch
└── README.md
```

## 💰 AWS Free Tier Optimization

| Service | Free Tier | Configuration |
|---------|-----------|---------------|
| S3 | 5GB | ✅ Lifecycle → Glacier |
| DynamoDB | 25GB | ✅ PAY_PER_REQUEST |
| SQS | 1M requests | ✅ |
| SNS | 1M publishes | ✅ |
| Lambda | 1M requests | ✅ 512MB, 5min timeout |
| KMS | 20k requests | ✅ 1 CMK + Bucket Keys |
| ECR | 500MB | ✅ Lifecycle policies |
| Cognito | 50k MAU | ✅ |
| API Gateway | 1M calls | ✅ |
| CloudWatch | 5GB logs | ✅ 30-day retention |
| **NAT Gateway** | ❌ NOT FREE | ⚠️ **Disabled** - using VPC Endpoints |

**Estimated monthly cost**: ~$10-15 (ECS Fargate only)

## 🔐 Security Features (FIPS 140-3)

| Layer | Implementation |
|-------|----------------|
| **Encryption at Rest** | KMS (AES-256-GCM) for S3, DynamoDB, SQS, SNS, CloudWatch |
| **Encryption in Transit** | TLS 1.2+, VPC Endpoints, HTTPS-only |
| **Authentication** | Cognito User Pool with MFA |
| **Authorization** | IAM Roles (least privilege), Cognito groups |
| **Network Security** | VPC, private subnets, Security Groups, NACLs |
| **API Protection** | WAF (SQL injection, rate limiting), API throttling |
| **Monitoring** | VPC Flow Logs, CloudTrail, CloudWatch Alarms |

## 📚 Documentation

- [Architecture Decision Records](docs/adr/README.md)
- [ADR-001: LocalStack for Local Development](docs/adr/001-use-localstack-for-local-development.md)
- [ADR-002: Event-Driven Architecture](docs/adr/002-event-driven-architecture.md)
- [ADR-003: ECS Fargate over EKS](docs/adr/003-ecs-fargate-over-eks.md)
- [ADR-004: FIPS 140-3 Encryption](docs/adr/004-fips-140-3-encryption.md)
- [ADR-005: VPC Endpoints over NAT](docs/adr/005-vpc-endpoints-over-nat.md)

## 🔗 Related Repositories

| Repository | Description | Status |
|------------|-------------|--------|
| `fsamp-infra` | Infrastructure (this repo) | ✅ Complete |
| `fsamp-gateway` | Spring Boot REST API | 📋 To create |
| `fsamp-processor` | Python Lambda processor | 📋 To create |

## 📝 License

MIT
