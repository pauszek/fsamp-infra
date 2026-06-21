# FedRAMP System Security Plan (SSP)

## FSAMP — FedRAMP-aligned Secure AWS Microservices Platform

| Field | Value |
|-------|-------|
| **System Name** | FSAMP (FedRAMP-aligned Secure AWS Microservices Platform) |
| **Version** | 1.0 |
| **Date** | May 2026 |
| **Author** | Paweł Pauszek |
| **Classification** | Unclassified |
| **FIPS 199 Category** | Moderate |

---

## 1. System Identification

### 1.1 System Description

FSAMP is a secure, event-driven microservices platform deployed on Amazon Web
Services (AWS). It provides file upload, validation, encryption, and asynchronous
processing capabilities with FIPS 140-3-oriented cryptographic controls and FedRAMP
Moderate baseline alignment.

The platform is designed as a reference architecture for master's thesis research:
**"Bezpieczna platforma mikroserwisowa w chmurze AWS z wykorzystaniem architektury
sterowanej zdarzeniami i infrastruktury jako kod (IaC)"** — demonstrating how to build
an aligned microservice platform using event-driven architecture and Infrastructure
as Code.

FedRAMP alignment note: This SSP documents alignment to the FedRAMP Moderate baseline
for a reference implementation. It does not imply FedRAMP authorization or an ATO.

### 1.2 System Components

| Component | Technology | Purpose |
|-----------|-----------|---------|
| **fsamp-gateway** | Java 21 (Corretto), Spring Boot 3.5 | REST API, file upload, validation, encryption, event publishing |
| **fsamp-processor** | Python 3.14, AWS Lambda / ECS Fargate | Event-driven file processing, outbox pattern, analysis |
| **fsamp-infra** | Terraform ≥ 1.7 (AWS Provider ≥6.44) | Infrastructure modules, deployment, alignment evidence |
| **fsamp-code-ci** | GitHub Actions | Reusable workflows and composite actions |
| **fsamp-event-schema** | JSON Schema Draft-07 | Event contract definition, versioned Maven artifact |

### 1.3 System Boundary

```text
┌─────────────────────────────────────────────────────────────────────────┐
│                         FSAMP Authorization Boundary                    │
│                                                                         │
│  ┌──────────────┐    ┌────────────────────────┐    ┌──────────────────────────┐  │
│  │ API Gateway   │    │ ECS Fargate            │    │ Lambda Functions         │  │
│  │ (+ WAF + CDN) │    │ (Gateway + Processor)  │    │ (Processor + Outbox Pub) │  │
│  └──────┬───────┘    └──────┬───────────────┘    └──────────┬───────────────┘  │
│         │                    │                       │                   │
│  ┌──────┴────────────────────┴───────────────────────┴───────────────┐  │
│  │                    Private VPC (3 AZ)                              │  │
│  │  ┌─────────┐  ┌──────────┐  ┌─────┐  ┌─────┐  ┌──────┐         │  │
│  │  │ S3      │  │ DynamoDB │  │ SQS │  │ SNS │  │ KMS  │         │  │
│  │  │ (Data)  │  │ (4 tables│  │(3Q) │  │(3T) │  │(CMK) │         │  │
│  │  └─────────┘  └──────────┘  └─────┘  └─────┘  └──────┘         │  │
│  │                                                                    │  │
│  │  VPC Endpoints (S3, DynamoDB, SQS, SNS, KMS, ECR, CW Logs)      │  │
│  └────────────────────────────────────────────────────────────────────┘  │
│                                                                         │
│  ┌─────────────────────────────────────────────────────────────────┐    │
│  │ Audit Services: CloudTrail │ GuardDuty │ AWS Config │ VPC Logs  │    │
│  └─────────────────────────────────────────────────────────────────┘    │
│                                                                         │
│  ┌──────────────────────────┐                                           │
│  │ Cognito (IdP/OAuth2/MFA) │                                           │
│  └──────────────────────────┘                                           │
└─────────────────────────────────────────────────────────────────────────┘

Note: Processor runs in both ECS Fargate and Lambda as production-capable modes; deployment can be chosen per workload.
                    ▲                              ▲
                    │ Inherited AWS Controls        │ CI/CD (GitHub Actions)
                    ▼                              ▼
         ┌──────────────────┐          ┌────────────────────┐
         │ AWS Shared       │          │ fsamp-code-ci      │
         │ Responsibility   │          │ (Pipeline + Scans) │
         └──────────────────┘          └────────────────────┘
```

### 1.4 Data Types and Classification

| Data Type | Classification | Storage | Encryption |
|-----------|---------------|---------|------------|
| Uploaded files | CUI (Controlled Unclassified) | S3 | SSE-KMS (AES-256-GCM) |
| File metadata | CUI | DynamoDB | SSE-KMS |
| Audit logs | Internal | S3 (CloudTrail bucket) | SSE-KMS |
| Event messages | Internal | SNS/SQS | SSE-KMS + TLS 1.2 |
| Authentication tokens | Sensitive | In-memory only | JWT RS256 over TLS |
| User credentials | Sensitive | Cognito (AWS-managed) | AWS KMS |

---

## 2. Security Categorization (FIPS 199)

### 2.1 Impact Assessment

| Security Objective | Impact Level | Justification |
|-------------------|--------------|---------------|
| **Confidentiality** | Moderate | Files may contain sensitive business data; protected by KMS encryption |
| **Integrity** | Moderate | File checksums (SHA-256) and CloudTrail log file validation ensure integrity |
| **Availability** | Low | Active AWS deployment pinned to `us-west-2`; Pilot Light recovery with 4-hour RTO |

Overall categorization: **MODERATE**

Formula: SC = {(confidentiality, MODERATE), (integrity, MODERATE), (availability, LOW)}

High-water mark: **MODERATE**

---

## 3. FIPS 140-3 Cryptographic Module Inventory

### 3.1 Validated Modules

| Module | CMVP Certificate | FIPS Level | Component | Usage |
|--------|------------------|------------|-----------|-------|
| Amazon Corretto Crypto Provider (ACCP) 2.4.1 | #4631 | Level 1 | Gateway (Java) | TLS, SHA-256/384/512, AES-GCM, RSA |
| BouncyCastle FIPS 2.0.0 | #4743 | Level 1 | Gateway (Java) | Supplementary crypto (position 2) |
| OpenSSL 3.x FIPS Provider | #4694 | Level 1 | Processor (Python) | TLS, SHA-256/384/512, AES-GCM |
| AWS KMS (HSM) | N/A (AWS-managed) | Level 3 | Both | CMK management, envelope encryption |

### 3.2 Cryptographic Algorithms (FIPS-Approved Only)

| Algorithm | Standard | Key Size | Usage |
|-----------|----------|----------|-------|
| AES-256-GCM | NIST SP 800-38D | 256-bit | Envelope encryption (data at rest) |
| SHA-256 | FIPS 180-4 | 256-bit | File checksums, content integrity |
| SHA-384/512 | FIPS 180-4 | 384/512-bit | Allowed but not primary |
| RSA-2048+ | FIPS 186-5 | 2048-bit+ | JWT signing (Cognito RS256) |
| ECDSA P-256 | FIPS 186-5 | 256-bit | TLS key exchange (ACCP) |

### 3.3 Dual-Provider Strategy (Gateway)

```text
JVM Security Providers:
  Position 1: ACCP 2.4.1          (CMVP #4631, primary)
  Position 2: BC-FIPS 2.0.0       (CMVP #4743, supplementary)
  Position 3: SUN                  (JDK default, restricted by approved_only=true)
```

Configuration: `security.fips.approved-only: true` in application.yml enforces
FIPS-approved algorithms only. Self-diagnostic tests run at startup to verify
provider availability and AES-GCM capability.

---

## 4. Architecture and Data Flow

### 4.1 File Upload Flow

```text
1. Client authenticates via Cognito (OAuth2 PKCE + MFA)
2. Client sends POST /api/v1/files with JWT Bearer token
3. API Gateway validates WAF rules + JWT authorizer
4. Gateway receives request (content-type, size validation)
5. Apache Tika inspects actual file content (MIME detection)
6. SHA-256 checksum computed (FIPS 140-3 provider)
7. File uploaded to S3 with SSE-KMS (AES-256-GCM)
8. Metadata saved to DynamoDB (SSE-KMS)
9. FileUploadedEvent published to SNS
10. SQS delivers event to Processor
11. Processor downloads file from S3, processes it
12. Results saved via TransactWriteItems (DynamoDB metadata + outbox entry)
13. DynamoDB Streams triggers Outbox Publisher Lambda
14. Lambda publishes FileProcessedEvent to SNS
```

### 4.2 Network Architecture

- **VPC**: 3 Availability Zones, /16 CIDR
- **Subnets**: Public (ALB), Private (ECS, Lambda), Isolated (databases)
- **VPC Endpoints**: 9 Interface endpoints (S3, DynamoDB, SQS, SNS, KMS, ECR API,
  ECR DKR, CloudWatch Logs, Secrets Manager) — traffic never crosses internet
- **Security Groups**: Least-privilege, egress restricted to 443 (HTTPS) + 53 (DNS)
- **NACLs**: Stateless firewall on all subnets
- **VPC Flow Logs**: Enabled for all subnets -> CloudWatch Logs

---

## 5. Control Implementation Summary

The full NIST SP 800-53 Rev. 5 control mapping is maintained in
[NIST_800_53_CONTROLS.md](NIST_800_53_CONTROLS.md). Below is a summary by
control family:

| Family | Description | Status | Key Controls |
|--------|-------------|--------|--------------|
| **AC** | Access Control | Aligned | AC-2, AC-3, AC-4, AC-6, AC-12, AC-17 |
| **AU** | Audit and Accountability | Aligned | AU-2, AU-3, AU-4, AU-6, AU-9, AU-12 |
| **CM** | Configuration Management | Aligned | CM-2, CM-3, CM-6, CM-7, CM-8 |
| **CP** | Contingency Planning | Partially Aligned | CP-9, CP-10 (single-region baseline; optional CRR exercise for passive-region evidence) |
| **IA** | Identification and Authentication | Aligned | IA-2, IA-5, IA-7 |
| **IR** | Incident Response | Aligned | IR-4, IR-5, IR-6 |
| **MP** | Media Protection | Aligned | MP-5 (encryption in transit) |
| **PE** | Physical and Environmental | Inherited | AWS responsibility under the shared responsibility model |
| **PL** | Planning | Aligned | PL-8 (security architecture documented) |
| **RA** | Risk Assessment | Aligned | RA-5 (vulnerability scanning in CI) |
| **SA** | System and Services Acquisition | Aligned | SA-11 (SAST/SCA in pipeline) |
| **SC** | System and Communications Protection | Aligned | SC-7, SC-8, SC-12, SC-13, SC-28 |
| **SI** | System and Information Integrity | Aligned | SI-2, SI-4, SI-7, SI-10, SI-11 |

---

## 6. Continuous Monitoring Strategy

### 6.1 Real-time Monitoring

| Service | Purpose | FedRAMP Control |
|---------|---------|-----------------|
| **CloudTrail** | API audit logging in the active `us-west-2` account/region | AU-2, AU-3, AU-12 |
| **GuardDuty** | Threat detection (S3, CloudTrail, DNS) | SI-4, IR-4 |
| **AWS Config** | Configuration compliance (5 rules) | CM-2, CM-6 |
| **VPC Flow Logs** | Network monitoring | AU-12, SC-7 |
| **CloudWatch Alarms** | 9 operational alarms + 1 composite | SI-4 |
| **S3 Access Logs** | Object-level audit trail | AU-3 |

### 6.2 Compliance Rules (AWS Config)

| Rule | NIST Control |
|------|-------------|
| S3 bucket encryption enabled | SC-28 |
| CloudTrail enabled | AU-2 |
| IAM root access key check | AC-6 |
| S3 public read prohibited | AC-3 |
| DynamoDB KMS encryption | SC-28 |

### 6.3 Automated Security Scanning (CI/CD)

| Tool | Scope | Frequency | Gate |
|------|-------|-----------|------|
| OWASP Dependency-Check | Java dependencies | Every build | Fail on CVSS ≥ 7 |
| pip-audit | Python dependencies | Every build | Fail on any vulnerability |
| bandit | Python SAST | Every build | Fail on HIGH |
| safety | Python CVE scan | Every build | Fail on any |
| Trivy | Docker images | Every build | Fail on CRITICAL/HIGH |
| Checkov | Terraform IaC | Every build | SARIF report |
| Dependabot | All ecosystems | Weekly | Auto-PR |
| SonarCloud | Code quality + SAST | Every build | Quality gate |

---

## 7. Interconnections

| External System | Direction | Protocol | Authentication | Data |
|----------------|-----------|----------|----------------|------|
| Client applications | Inbound | HTTPS (TLS 1.2) | OAuth2 JWT (Cognito) | File uploads, API requests |
| AWS S3 | Outbound | HTTPS (FIPS) | IAM role (SigV4) | File objects |
| AWS DynamoDB | Outbound | HTTPS (FIPS) | IAM role (SigV4) | Metadata |
| AWS KMS | Outbound | HTTPS (FIPS) | IAM role (SigV4) | Encryption keys |
| AWS SNS/SQS | Outbound | HTTPS (FIPS) | IAM role (SigV4) | Events |
| AWS Cognito | Outbound | HTTPS (FIPS) | OIDC | Authentication |
| GitHub (CI/CD) | Inbound | HTTPS | GitHub App token | Source code, artifacts |
| GitHub Container Registry | Outbound | HTTPS | GITHUB_TOKEN | Docker images |
| SonarCloud | Outbound | HTTPS | API token | Code analysis |

---

## 8. Roles and Responsibilities

| Role | Responsibilities | Access Level |
|------|-----------------|--------------|
| **Platform Administrator** | Infrastructure management, Terraform operations, incident response | Full AWS access, `ROLE_ADMINS` |
| **Developer** | Code changes, PR reviews, deployment approvals | GitHub write, `ROLE_USERS` |
| **API User** | File upload/download via REST API | OAuth2 token, `files.read` + `files.write` scopes |
| **Auditor** | Review logs, compliance assessment | Read-only AWS access, CloudTrail, GuardDuty |
| **CI/CD System** | Automated builds, tests, deployments | GitHub App token, ECR push, ECS deploy |

---

## 9. Contingency Plan Summary

| Aspect | Value |
|--------|-------|
| **RPO** (Recovery Point Objective) | 24 hours (DynamoDB PITR) |
| **RTO** (Recovery Time Objective) | 4 hours (Pilot Light strategy) |
| **Backup strategy** | DynamoDB Point-in-Time Recovery, S3 versioning, Terraform state in S3 |
| **DR strategy** | Pilot Light — infrastructure defined in Terraform and rebuilt in the pinned `us-west-2` baseline; optional CRR can be enabled for passive-region exercises |
| **Key recovery** | Customer-managed regional KMS keys recreated from Terraform and key policy |

For full DR procedures, see [DISASTER_RECOVERY.md](../DISASTER_RECOVERY.md).

---

## 10. Known Limitations and Planned Improvements

| Limitation | FedRAMP Impact | Mitigation | Timeline |
|-----------|---------------|------------|----------|
| Single-region active deployment | CP (limited geographic redundancy by default) | Terraform rebuild in `us-west-2`; DynamoDB PITR; optional CRR module for passive-region DR exercises | Accepted baseline |
| Self-signed internal ALB cert (default) | SC-8 (chain not verified on the VPC Link hop) | FIPS-TLS encrypted; VPC Link + SG isolation; `alb_certificate_mode=acm` removes it (ADR-008) | Available (acm mode) |
| Lambda cold start | Availability (~1-2s delay) | Provisioned concurrency configurable per env | Configured |
| FIPS endpoints us-west-2 only | SC-13 boundary clarity | Fail-closed region guard rejects any active AWS deployment region other than `us-west-2`; LocalStack/custom endpoints are explicitly non-compliance targets | By design |
| ACCP requires Corretto JVM | Vendor dependency | BC-FIPS as fallback provider | Accepted risk |

---

## 11. References

- [NIST SP 800-53 Rev. 5](https://csrc.nist.gov/publications/detail/sp/800-53/rev-5/final)
- [FIPS 140-3](https://csrc.nist.gov/publications/detail/fips/140/3/final)
- [FIPS 199](https://csrc.nist.gov/publications/detail/fips/199/final)
- [FedRAMP Security Assessment Framework](https://www.fedramp.gov/)
- [ADR-004: FIPS 140-3 Encryption & FedRAMP Alignment](../adr/004-fips-140-3-encryption.md)
- [NIST 800-53 Control Matrix](NIST_800_53_CONTROLS.md)
- [Security Review Notes](SECURITY_AUDIT_REPORT.md)
- [TLS Architecture](../TLS_ARCHITECTURE.md)
- [Disaster Recovery Plan](../DISASTER_RECOVERY.md)
- [SLO/SLI Definitions](../SLO_SLI.md)
