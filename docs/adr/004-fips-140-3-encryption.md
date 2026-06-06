# ADR-004: FIPS 140-3 Encryption & FedRAMP Alignment Strategy

## Status

Accepted — revised 2026-05 for FIPS/FedRAMP-aligned wording

## Context

The FSAMP platform handles sensitive file data and requires strong encryption.
FIPS 140-3 (Federal Information Processing Standard) provides cryptographic module validation
that is recognized as a high security standard.

### Requirements

- Encryption at rest for all data (S3, DynamoDB, SQS, SNS)
- Encryption in transit (TLS 1.2+) with FIPS-capable TLS stacks
- Application-layer FIPS-capable crypto providers (JVM + Python)
- Key management with automatic rotation
- Audit trail for cryptographic operations (CloudTrail, GuardDuty, AWS Config)
- FedRAMP-aligned access controls (AC-3, AC-4, AC-12, SC-7, SC-8, AU-2)
- Compliance documentation for thesis

### AWS FIPS Alignment

AWS KMS and AWS FIPS endpoints provide the managed cryptographic boundary. The platform treats
FIPS as an end-to-end posture: FIPS-capable modules, FIPS endpoints where available, and clear evidence.

## Decision

We will implement **FIPS 140-3-oriented encryption controls and FedRAMP-aligned security controls** using:

### 1. AWS KMS — Master Key Management

- Single Customer Master Key (CMK) per environment
- Automatic annual key rotation enabled
- AES-256-GCM (FIPS-approved algorithm)

### 2. Encryption at Rest

- S3: SSE-KMS with bucket keys
- DynamoDB: KMS encryption
- SQS/SNS: KMS encryption
- CloudWatch Logs: KMS encryption
- ECS: KMS for execute command

### 3. Encryption in Transit — Transport Security Enforcement

- TLS 1.2+ for all API calls
- VPC Endpoints for internal AWS traffic
- HTTPS-only for API Gateway
- **S3 bucket policies**: deny `aws:SecureTransport=false` and `s3:TlsVersion < 1.2`
- **SQS queue policies**: `DenyUnencryptedTransport` on all queues (FedRAMP SC-8)
- **SNS topic policies**: `DenyUnencryptedTransport` on all topics (FedRAMP SC-8)
- **Network egress**: ECS/Lambda security groups restricted to 443/tcp + 53/tcp/udp only (FedRAMP SC-7)

### 4. Application Layer — FIPS Crypto Providers

#### Java (Gateway — Spring Boot / Corretto 21)

Dual-provider strategy for a FIPS 140-3-oriented runtime posture:

| Position | Provider | Use |
|----------|----------|-----|
| 1 | **Amazon Corretto Crypto Provider (ACCP)** | Primary JCE provider for approved algorithms |
| 2 | **BouncyCastle FIPS** | Supplementary approved-mode provider |

- **Base image**: `amazoncorretto:21-al2023` (replaces Eclipse Temurin)
- **Runtime flag**: `-Dcom.amazon.corretto.crypto.provider.extclasses=FIPS`
- **Self-test**: `AmazonCorrettoCryptoProvider.assertHealthy()` at startup
- **AWS SDK FIPS endpoints**: `.fipsEnabled(true)` on all production SDK clients (S3, SNS, KMS, STS, DynamoDB, SQS); auto-disabled for non-US regions

#### Python (Processor — Lambda Container Image)

- **Container image** based on `public.ecr.aws/lambda/python:3.14` (AL2023)
- **OpenSSL FIPS provider** installed and activated (`openssl fipsinstall`, `fips=yes`)
- **FIPS-capable TLS**: `ssl` / `cryptography` operations use the configured OpenSSL provider
- **boto3 FIPS endpoints** (`use_fips_endpoint=True`) for AWS API calls
- **ECR deployment**: image pushed to `${name_prefix}-processor` ECR repository, Lambda uses `package_type = "Image"`
- **Rationale**: container image provides full control over OpenSSL FIPS configuration (managed runtime does not allow custom `OPENSSL_CONF`)
- **ECS Dockerfile**: identical FIPS OpenSSL setup for standalone Fargate deployment option

### 5. Access Controls (FedRAMP Alignment)

- **Swagger UI secured in staging/prod** — requires `ROLE_ADMINS` (FedRAMP AC-3)
- **CORS origin restriction** — `localhost:*` only in local/dev; explicit origins in staging/prod (FedRAMP AC-4)
- **Cognito token lifetime** — 30 min access tokens in prod, 60 min in dev/local (FedRAMP AC-12)
- **MFA enforced** in prod (`mfa_configuration = "ON"`)

### 6. Audit Services (FedRAMP AU-2, SI-4, CM-2)

Feature-flagged services enabled in staging/prod:

| Service | FedRAMP Control | Purpose |
|---------|----------------|---------|
| **CloudTrail** (multi-region) | AU-2, AU-3, AU-6 | API audit logging with log file validation |
| **GuardDuty** | SI-4 | Threat detection and anomaly monitoring |
| **AWS Config** | CM-2, CM-6 | Configuration compliance (5 managed rules) |

All audit resources use KMS encryption and have `count`-based feature flags for cost control.

### Architecture

```text
┌──────────────────────────────────────────────────────────────────────┐
│                    Encryption & Security Architecture                │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  ╔══════════════════════════════════════════════════════════════╗    │
│  ║  Application-Layer FIPS Crypto Providers                     ║    │
│  ║                                                              ║    │
│  ║  Java (Gateway)              Python (Processor)              ║    │
│  ║  ┌─────────────────────┐     ┌────────────────────────┐     ║    │
│  ║  │ ACCP (pos 1)        │     │ Lambda Container Image │     ║    │
│  ║  │ approved algorithms │     │ AL2023 + OpenSSL FIPS  │     ║    │
│  ║  ├─────────────────────┤     ├────────────────────────┤     ║    │
│  ║  │ BC-FIPS (pos 2)     │     │ boto3 FIPS endpoints   │     ║    │
│  ║  │ approved mode       │     │ cryptography >= 46.0   │     ║    │
│  ║  └─────────────────────┘     └────────────────────────┘     ║    │
│  ╚══════════════════════════════════════════════════════════════╝    │
│                                                                      │
│  ┌──────────────────┐                                               │
│  │   AWS KMS        │  managed cryptographic boundary               │
│  │   Master Key     │  AES-256-GCM                                  │
│  └────────┬─────────┘                                               │
│           │                                                          │
│     ┌─────┼─────┬──────────┬──────────┬──────────┐                  │
│     ▼     ▼     ▼          ▼          ▼          ▼                  │
│  ┌─────┐ ┌─────┐ ┌────────┐ ┌───────┐ ┌───────┐ ┌──────────┐       │
│  │ S3  │ │DDB  │ │SQS/SNS │ │CloudW │ │Lambda │ │   ECS    │       │
│  │SSE- │ │ KMS │ │  KMS   │ │ Logs  │ │ env   │ │ execute  │       │
│  │ KMS │ │     │ │  +TLS  │ │  KMS  │ │  KMS  │ │  cmd     │       │
│  │+TLS │ │     │ │enforce │ │       │ │       │ │          │       │
│  └─────┘ └─────┘ └────────┘ └───────┘ └───────┘ └──────────┘       │
│                                                                      │
│  ═══════════════ Transport Security (SC-8) ═══════════════          │
│  TLS 1.2+ enforced │ VPC Endpoints │ HTTPS only │ FIPS endpoints    │
│  SG egress: 443+53 │ Bucket policy │ Queue policy│ Topic policy     │
│                                                                      │
│  ═══════════════ Audit Services (AU-2) ═══════════════              │
│  CloudTrail (multi-region) │ GuardDuty │ AWS Config (5 rules)       │
└──────────────────────────────────────────────────────────────────────┘
```

## Consequences

### Positive

- All data encrypted with FIPS 140-3-oriented cryptography
- **End-to-end FIPS-oriented posture**: JVM providers -> AWS SDK FIPS endpoints -> KMS
- Single key simplifies management (cost: ~$1/month)
- Automatic rotation reduces operational burden
- Transport security enforced at infrastructure level (bucket/queue/topic policies)
- CloudTrail audit for all KMS and API operations
- Feature-flagged audit services prevent cost overrun in dev/local
- Profile-aware security controls (Swagger, CORS, tokens) maintain dev ergonomics
- Strong thesis security chapter content with concrete NIST control family mappings

### Negative

- KMS adds ~3-5ms latency per operation
- Single key = single point of configuration
- FIPS endpoints only in supported US regions; other regions rely on the configured runtime providers
- Key policy complexity for least privilege
- ACCP restricts JVM to Amazon Corretto distribution
- Lambda container images have larger cold-start (~1-2s more than managed runtime)
- Audit services (CloudTrail, GuardDuty, Config) add cost in staging/prod

### Mitigations

- Use S3 Bucket Keys to reduce KMS calls (90% cost reduction)
- Implement key policy with service-specific conditions
- Feature flags for audit services (`enable_cloudtrail`, `enable_guardduty`, `enable_aws_config`)
- Document KMS limitations and FIPS endpoint regional availability in thesis
- ACCP `assertHealthy()` self-test catches misconfiguration at startup
- Lambda container images use SnapStart (when available) to mitigate cold-start overhead
- Same Dockerfile.lambda used for both processor and outbox-publisher Lambda functions (different CMD)

## References

- [AWS FIPS compliance documentation](https://aws.amazon.com/compliance/fips/)
- [FIPS 140-3 Standard](https://csrc.nist.gov/publications/detail/fips/140/3/final)
- [AWS KMS Key Rotation](https://docs.aws.amazon.com/kms/latest/developerguide/rotate-keys.html)
- [Amazon Corretto Crypto Provider](https://github.com/corretto/amazon-corretto-crypto-provider)
- [ACCP FIPS Mode Documentation](https://github.com/corretto/amazon-corretto-crypto-provider/blob/main/FIPS.md)
- [AWS Lambda Managed Runtimes](https://docs.aws.amazon.com/lambda/latest/dg/lambda-runtimes.html)
- [NIST SP 800-53 Rev. 5 — Security Controls](https://csrc.nist.gov/publications/detail/sp/800-53/rev-5/final)
- [FedRAMP Security Controls Baseline](https://www.fedramp.gov/)
