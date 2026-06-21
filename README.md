# FSAMP Infrastructure

[![Terraform](https://img.shields.io/badge/Terraform-1.7+-623CE4?logo=terraform)](https://www.terraform.io/)
[![AWS](https://img.shields.io/badge/AWS-Cloud-FF9900?logo=amazonaws)](https://aws.amazon.com/)
[![LocalStack](https://img.shields.io/badge/LocalStack-Pro-4A154B?logo=docker)](https://localstack.cloud/)
[![FIPS 140-3](https://img.shields.io/badge/FIPS-140--3-green)](https://csrc.nist.gov/publications/detail/fips/140/3/final)

Infrastructure as Code for the FSAMP event-driven microservices platform on AWS.
The project is FedRAMP Moderate-aligned and FIPS 140-3-oriented, without claiming
formal FedRAMP authorization.
Active AWS deployments are pinned to `us-west-2`; LocalStack Pro is the primary
local target, and optional cross-region replication is disabled by default.

## What This Repo Owns

| Area | Contents |
|---|---|
| Terraform | AWS modules for networking, security, storage, messaging, compute, observability, auth, API Gateway, and ECR |
| Local development | LocalStack compose file, init scripts, local Terraform environment |
| Deployment | GitHub Actions deployment workflow for `dev`, `staging`, `prod`, and rollback |
| Operations docs | ADRs, deployment notes, disaster recovery, SLOs, compliance notes |
| Validation | E2E tests and k6 load tests |

## Architecture

```text
Client -> API Gateway + WAF -> private ALB -> ECS Gateway
Gateway -> S3 + DynamoDB outbox -> DynamoDB Streams -> Outbox Lambda
Outbox Lambda -> SNS -> SQS -> Processor Lambda
```

Core AWS services: Cognito, KMS, S3, DynamoDB, SNS, SQS, Lambda, ECS Fargate,
CloudWatch, CloudTrail, GuardDuty, AWS Config, WAF, ECR, and SSM Parameter Store.

See [ARCHITECTURE.md](ARCHITECTURE.md) for the detailed design.

## Quick Start

Prerequisites:

- Docker and Docker Compose
- Terraform >= 1.7
- AWS CLI v2
- LocalStack Pro token for full local emulation

LocalStack Pro is the primary runtime environment: the same Terraform modules
provision it, Terraform state lives in LocalStack S3 with lockfile locking,
and test users are seeded after apply (see ADR-001 revision).

```bash
export LOCALSTACK_AUTH_TOKEN=your-token
make local-parity    # Terraform + local ECR images + ECS/API Gateway/Lambda parity
```

`make local-core` remains available for lightweight Terraform work without the
edge stack. The imperative bootstrap (`localstack/init-aws.sh`) runs only when
`FSAMP_TF_MANAGED` is unset, which is now the fast compose/e2e fallback path.

AWS bootstrap:

```bash
GITHUB_OWNER=pauszek GITHUB_REPO=fsamp-infra ./scripts/bootstrap-github-oidc.sh
```

Set the printed `AWS_DEPLOY_ROLE_ARN` as a GitHub repository or organization
variable. The `Deploy` workflow can then deploy `dev`, promote
`dev -> staging -> prod`, or roll back a selected environment.

## Environments

| Environment | Purpose | Gate |
|---|---|---|
| `local` | Developer integration testing | local only |
| `dev` | Automatic integration deploy | merge or dispatch |
| `staging` | Pre-production validation | GitHub Environment approval |
| `prod` | Production target | GitHub Environment approval after staging succeeds |

## Repository Structure

```text
terraform/
  envs/
  modules/
docs/
  adr/
  compliance/
e2e/
load-tests/
localstack/
scripts/
.github/workflows/
```

## Main Commands

```bash
make help
make local-parity
make local-core
make up
make down
make init-local
make plan-local
make apply-local
make seed-local
make init-dev
make plan-dev
```

AWS applies should normally be done through GitHub Actions so approvals, signed
image digests, immutable Terraform image references, and rollback metadata stay
consistent.

## Security and Compliance Notes

- FedRAMP Moderate-aligned control mapping in [docs/compliance](docs/compliance)
- FIPS 140-3-oriented runtime and AWS endpoint strategy in
  [docs/adr/004-fips-140-3-encryption.md](docs/adr/004-fips-140-3-encryption.md)
- TLS boundary documentation in [docs/TLS_ARCHITECTURE.md](docs/TLS_ARCHITECTURE.md)
- Deployment and rollback notes in [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md)
- SLOs in [docs/SLO_SLI.md](docs/SLO_SLI.md)
- DR strategy in [docs/DISASTER_RECOVERY.md](docs/DISASTER_RECOVERY.md)

## Related Repositories

| Repository | Purpose |
|---|---|
| `fsamp-gateway` | Java/Spring Boot API service |
| `fsamp-processor` | Python processor and outbox publisher |
| `fsamp-event-schema` | Canonical event contract |
| `fsamp-code-ci` | Reusable CI/CD workflows and composite actions |

## Cost Notes

The default design chooses cost-aware AWS primitives where practical: ECS Fargate
instead of EKS, VPC endpoints instead of NAT for AWS service access, Fargate Spot
for non-production, and S3 Bucket Keys for lower KMS request volume. Actual cost
depends on traffic, logs, image storage, audit-service flags, and region.
