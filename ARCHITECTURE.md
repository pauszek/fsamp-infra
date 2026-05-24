# FSAMP Platform Architecture

FSAMP is a secure, event-driven AWS microservices platform built for a master's
thesis on cloud security, automation, and Infrastructure as Code. The platform is
FedRAMP Moderate-aligned and FIPS 140-3-oriented, but it is not FedRAMP authorized.

## System View

```text
Client
  -> API Gateway + WAF
  -> private ALB
  -> ECS Fargate: fsamp-gateway
  -> S3 + DynamoDB + transactional outbox
  -> SNS
  -> SQS
  -> Lambda: fsamp-processor
```

Supporting services:

- Cognito for OAuth2/JWT authentication
- KMS for customer-managed encryption keys
- CloudWatch, X-Ray, CloudTrail, GuardDuty, AWS Config, and VPC Flow Logs for
  observability and audit evidence
- ECR for immutable service images
- SSM Parameter Store for deployment state and rollback tags

## Components

| Component | Runtime | Role |
|---|---|---|
| `fsamp-gateway` | Java 21, Spring Boot 3.5, ECS Fargate | REST ingress, upload validation, storage, metadata, outbox writes |
| `fsamp-processor` | Python 3.14, Lambda container image | SQS event processing, file analysis, status updates |
| `outbox-publisher` | Python 3.14, Lambda container image | DynamoDB Streams to SNS publishing |
| `fsamp-event-schema` | JSON Schema Draft-07 | Canonical file event contract |
| `fsamp-code-ci` | GitHub Actions | Reusable build, scan, SBOM, signing, and Terraform workflows |

## Data Flow

1. Client authenticates with Cognito and uploads a file to the gateway.
2. Gateway validates metadata, MIME type, size, authorization, and idempotency.
3. Gateway stores the object in S3 with SSE-KMS and writes metadata to DynamoDB.
4. Gateway writes an outbox record in the same logical workflow as metadata persistence.
5. DynamoDB Streams invokes the outbox publisher Lambda.
6. The publisher emits the canonical event to SNS.
7. SQS receives the event and invokes the processor.
8. Processor downloads the object, analyzes it, updates metadata, and emits follow-up events.
9. Failed asynchronous events go to DLQ for investigation.

## Security Posture

| Area | Controls |
|---|---|
| Identity | Cognito, OAuth2 scopes, RBAC groups, MFA in production |
| Network | Private compute, VPC endpoints, security groups, WAF, TLS-only service policies |
| Data at rest | KMS encryption for S3, DynamoDB, SQS, SNS, CloudWatch Logs, and state storage |
| Data in transit | TLS 1.2+, FIPS endpoints where supported, private AWS service access |
| Runtime crypto | ACCP/BC-FIPS in gateway, OpenSSL FIPS provider in processor containers |
| Audit | CloudTrail log validation, GuardDuty, AWS Config, VPC Flow Logs, structured app logs |
| CI/CD | OIDC-based AWS access, SBOM, dependency scanning, IaC scanning, signed container images |

LocalStack is a local development target and is not treated as a compliance boundary.

## Environments

| Environment | Purpose | Deployment |
|---|---|---|
| `local` | Developer integration testing | LocalStack + local Terraform state |
| `dev` | Automatic integration deploy | GitHub Actions on merge/dispatch |
| `staging` | Pre-production validation | Manual approval through GitHub Environments |
| `prod` | Production target | Manual approval after successful staging |

Rollback is driven by immutable image tags. The deployment workflow records the
current and previous image tags in SSM Parameter Store for each AWS environment.

## Infrastructure

Terraform modules:

| Module | Responsibility |
|---|---|
| `api-gateway` | API Gateway, WAF, ingress configuration |
| `auth` | Cognito user pool, clients, groups, scopes |
| `compute` | ECS Fargate services, Lambda functions, event sources |
| `ecr` | Gateway and processor repositories |
| `messaging` | SNS, SQS, DLQs, transport policies |
| `networking` | VPC, subnets, endpoints, flow logs |
| `observability` | CloudWatch dashboards, alarms, X-Ray |
| `security` | KMS keys, IAM roles and policies |
| `storage` | S3 buckets, DynamoDB tables, encryption policies |

## Technology Stack

| Layer | Technology |
|---|---|
| Cloud | AWS |
| IaC | Terraform >= 1.7, AWS provider >= 6.44 |
| Gateway | Java 21, Spring Boot 3.5 |
| Processor | Python 3.14 |
| Compute | ECS Fargate, Lambda container images |
| Messaging | SNS, SQS, DynamoDB Streams |
| Storage | S3, DynamoDB |
| Security | KMS, Cognito, WAF, GuardDuty, AWS Config |
| Observability | CloudWatch, X-Ray, structured JSON logs |
| Local AWS emulation | LocalStack |

## Repository Structure

```text
fsamp-infra/
  terraform/
  docs/
  e2e/
  load-tests/
fsamp-gateway/
  src/
  Dockerfile
fsamp-processor/
  src/
  Dockerfile
  Dockerfile.lambda
fsamp-event-schema/
  event.schema.json
fsamp-code-ci/
  .github/workflows/
  .github/actions/
```

## Architecture Decisions

- [ADR-001: LocalStack for Local Development](docs/adr/001-use-localstack-for-local-development.md)
- [ADR-002: Event-Driven Architecture](docs/adr/002-event-driven-architecture.md)
- [ADR-003: ECS Fargate over EKS](docs/adr/003-ecs-fargate-over-eks.md)
- [ADR-004: FIPS 140-3 Encryption](docs/adr/004-fips-140-3-encryption.md)
- [ADR-005: VPC Endpoints over NAT Gateway](docs/adr/005-vpc-endpoints-over-nat.md)
- [ADR-006: Multi-Repository Architecture](docs/adr/006-multi-repository-architecture.md)
- [ADR-007: Transactional Outbox Pattern](docs/adr/007-transactional-outbox-pattern.md)
