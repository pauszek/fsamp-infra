# NIST SP 800-53 Rev. 5 — Control Implementation Matrix

## FSAMP — FedRAMP-compliant Secure AWS Microservices Platform

> FedRAMP Moderate Baseline — Selected Controls

| Legend | Meaning |
|--------|---------|
| ✅ Implemented | Control fully implemented and tested |
| ⚡ Partially Implemented | Core requirements met; enhancements planned |
| 🔄 Inherited | AWS responsibility under shared responsibility model |
| ➖ N/A | Not applicable to this system |

---

## AC — Access Control

| Control | Title | Status | Implementation | Evidence |
|---------|-------|--------|----------------|----------|
| **AC-2** | Account Management | ✅ Implemented | Cognito User Pool with groups (`ROLE_ADMINS`, `ROLE_USERS`). Self-registration disabled. Admin-provisioned accounts only. | `terraform/modules/auth/main.tf` — `aws_cognito_user_pool`, `aws_cognito_user_group` |
| **AC-2(1)** | Automated Account Management | ✅ Implemented | Cognito handles account lifecycle. Token expiration enforced (30 min prod, 60 min dev). | `terraform/modules/auth/main.tf` — `access_token_validity` |
| **AC-3** | Access Enforcement | ✅ Implemented | OAuth2 scope-based authorization (`files.read`, `files.write`). Spring Security `@PreAuthorize` on controllers. Swagger UI restricted to `ROLE_ADMINS` in prod. | `SecurityConfig.java`, `FileUploadRestAdapter.java` — `@PreAuthorize("hasAuthority('SCOPE_files.write')")` |
| **AC-4** | Information Flow Enforcement | ✅ Implemented | Profile-aware CORS policies (restrictive in prod, permissive in local). Content-Security-Policy, X-Frame-Options, X-Content-Type-Options headers. WAF rules. | `CorsConfig.java`, `SecurityConfig.java` — security headers, `api-gateway/main.tf` — WAF |
| **AC-6** | Least Privilege | ✅ Implemented | IAM roles scoped per service (ECS, Lambda). Resource ARN restrictions on KMS, S3, DynamoDB, SQS, SNS. Lambda role more restrictive than ECS role (no S3 Delete, no SQS Send). | `terraform/modules/security/main.tf` — lines 142-306 |
| **AC-6(1)** | Authorize Access to Security Functions | ✅ Implemented | KMS key policy restricts key operations to designated service principals with `CallerAccount` condition. | `terraform/modules/security/main.tf` — KMS key policy |
| **AC-12** | Session Termination | ✅ Implemented | Cognito access token lifetime: 30 min (prod), 60 min (dev/staging). Refresh token: 24 hours. No server-side sessions (stateless JWT). | `terraform/modules/auth/main.tf` — `access_token_validity`, `id_token_validity` |
| **AC-17** | Remote Access | ✅ Implemented | All API access over HTTPS (TLS 1.2+). HSTS header enforced. No direct SSH/RDP access to infrastructure (Fargate serverless). | `SecurityConfig.java` — HSTS, API Gateway TLS |

---

## AU — Audit and Accountability

| Control | Title | Status | Implementation | Evidence |
|---------|-------|--------|----------------|----------|
| **AU-2** | Event Logging | ✅ Implemented | CloudTrail (multi-region, management + data events). Application-level structured JSON logging. All API calls logged with correlation ID. | `terraform/modules/audit/main.tf` — `aws_cloudtrail`, `application.yml` — structlog |
| **AU-3** | Content of Audit Records | ✅ Implemented | Audit records include: timestamp (ISO 8601), source IP, user identity, action, resource, outcome, correlation ID, request ID. | `CorrelationIdFilter.java`, `DynamoDbFileRepositoryAdapter.java` — `@FedRAMP AU-3` annotations |
| **AU-3(1)** | Additional Audit Information | ✅ Implemented | File checksum (SHA-256), encryption algorithm, KMS key ID, content type, file size logged on every upload. | `FileUploadDomainService.java` — structured log fields |
| **AU-4** | Audit Log Storage | ✅ Implemented | CloudTrail logs → S3 with lifecycle (90d → IA, 365d → Glacier, 7yr expiry in prod). CloudWatch Logs with configurable retention. | `terraform/modules/audit/main.tf` — lifecycle rules |
| **AU-6** | Audit Record Review | ✅ Implemented | CloudWatch Insights queries available. GuardDuty automated threat review. 9 CloudWatch alarms for anomaly detection. | `terraform/modules/observability/main.tf` — alarms, dashboards |
| **AU-9** | Protection of Audit Information | ✅ Implemented | CloudTrail S3 bucket: SSE-KMS encryption, versioning, public access blocked, `DenyUnencryptedTransport` policy. Log file validation enabled. | `terraform/modules/audit/main.tf` — bucket policy, `enable_log_file_validation = true` |
| **AU-12** | Audit Record Generation | ✅ Implemented | System-wide: CloudTrail (API), VPC Flow Logs (network), S3 access logs (data), application logs (business). | Multiple modules |

---

## CM — Configuration Management

| Control | Title | Status | Implementation | Evidence |
|---------|-------|--------|----------------|----------|
| **CM-2** | Baseline Configuration | ✅ Implemented | All infrastructure defined in Terraform (10 modules). State file in S3 with DynamoDB locking. AWS Config tracks configuration changes. | `terraform/` — all modules, `terraform/modules/audit/main.tf` — Config |
| **CM-3** | Configuration Change Control | ✅ Implemented | All changes via Git PRs with required reviews. CI pipeline validates: build, test, SAST, SCA, IaC scan. Auto-versioning with `release.version`. | `.github/workflows/` — build pipelines, `bump-release-version` action |
| **CM-6** | Configuration Settings | ✅ Implemented | Security hardening: Spring Boot prod profile disables error details (`server.error.include-message: never`), non-essential actuator endpoints filtered. Terraform Checkov scanning. | `application.yml` — prod profile, `.checkov.yml` |
| **CM-7** | Least Functionality | ✅ Implemented | Docker images: multi-stage builds, non-root users (UID 1001/1000), minimal base images (Corretto 21 headless, Python slim-bookworm). No SSH, no unnecessary packages. | `Dockerfile` (gateway), `Dockerfile` (processor) |
| **CM-8** | System Component Inventory | ✅ Implemented | SBOM generated for every build (CycloneDX). Terraform tracks all AWS resources. Dependabot monitors all ecosystems. | `pom.xml` — CycloneDX Maven plugin, `build-python.yml` — cyclonedx-bom |

---

## CP — Contingency Planning

| Control | Title | Status | Implementation | Evidence |
|---------|-------|--------|----------------|----------|
| **CP-9** | System Backup | ⚡ Partial | DynamoDB Point-in-Time Recovery enabled. S3 versioning on all buckets. Terraform state backed up in S3 with versioning. No automated backup testing. | `terraform/modules/storage/main.tf` — PITR, versioning |
| **CP-10** | System Recovery | ⚡ Partial | Pilot Light DR strategy documented. Full Terraform rebuild possible in any US region. RTO: 4 hours, RPO: 24 hours. Multi-region not yet activated. | `docs/DISASTER_RECOVERY.md` |

---

## IA — Identification and Authentication

| Control | Title | Status | Implementation | Evidence |
|---------|-------|--------|----------------|----------|
| **IA-2** | User Identification and Authentication | ✅ Implemented | Cognito User Pool with unique user IDs. OAuth2/OIDC with RS256 JWT. Account lockout after failed attempts. | `terraform/modules/auth/main.tf` — `aws_cognito_user_pool` |
| **IA-2(1)** | Multi-factor Authentication — Privileged | ✅ Implemented | MFA (TOTP) enforced for all users in production (`mfa_configuration = "ON"`). | `terraform/modules/auth/main.tf` — `mfa_configuration` |
| **IA-5** | Authenticator Management | ✅ Implemented | Password policy: min 12 chars (prod), uppercase, lowercase, numbers, symbols required. Temporary password validity: 1 day. | `terraform/modules/auth/main.tf` — `password_policy` |
| **IA-5(1)** | Password-Based Authentication | ✅ Implemented | Cognito enforces password complexity. No plaintext password storage. Secrets (API tokens) managed via GitHub Secrets / AWS Secrets Manager. | `terraform/modules/auth/main.tf`, CI secrets configuration |
| **IA-7** | Cryptographic Module Authentication | ✅ Implemented | All crypto operations use FIPS 140-3 validated modules (ACCP, BC-FIPS, OpenSSL FIPS). | `FipsCryptoConfig.java`, `crypto_provider.py` |

---

## IR — Incident Response

| Control | Title | Status | Implementation | Evidence |
|---------|-------|--------|----------------|----------|
| **IR-4** | Incident Handling | ✅ Implemented | GuardDuty automated threat detection → SNS notifications. Documented response procedures: containment (SG lockdown, Cognito disable, KMS disable), recovery (Terraform redeploy). | `SECURITY.md` — Incident Response section, `docs/DISASTER_RECOVERY.md` |
| **IR-5** | Incident Monitoring | ✅ Implemented | GuardDuty findings with 15-min publishing (prod). CloudWatch composite alarm for critical incidents. | `terraform/modules/audit/main.tf` — GuardDuty, `observability/main.tf` |
| **IR-6** | Incident Reporting | ✅ Implemented | GuardDuty findings exportable. CloudTrail provides audit trail for forensics. ADR format for post-mortems. | Process documented in `SECURITY.md` |

---

## MP — Media Protection

| Control | Title | Status | Implementation | Evidence |
|---------|-------|--------|----------------|----------|
| **MP-5** | Media Transport | ✅ Implemented | All data in transit encrypted with TLS 1.2+. `DenyUnencryptedTransport` bucket policies on S3. SQS/SNS deny non-TLS access. FIPS endpoints for all AWS API calls. | `terraform/modules/storage/main.tf`, `messaging/main.tf` — deny policies |

---

## PE — Physical and Environmental Protection

| Control | Title | Status | Implementation | Evidence |
|---------|-------|--------|----------------|----------|
| **PE-**** | All PE controls | 🔄 Inherited | AWS manages physical security for all data center facilities. AWS data centers are FedRAMP-authorized. | AWS shared responsibility model |

---

## PL — Planning

| Control | Title | Status | Implementation | Evidence |
|---------|-------|--------|----------------|----------|
| **PL-8** | Security Architecture | ✅ Implemented | Architecture documented: hex arch, 5-layer security model, data flow diagrams, TLS termination model. ADR process for design decisions. | `ARCHITECTURE.md`, `docs/TLS_ARCHITECTURE.md`, 7 ADRs |

---

## RA — Risk Assessment

| Control | Title | Status | Implementation | Evidence |
|---------|-------|--------|----------------|----------|
| **RA-5** | Vulnerability Scanning | ✅ Implemented | **Java**: OWASP Dependency-Check (CVSS ≥ 7 gate). **Python**: pip-audit, bandit, safety. **Containers**: Trivy (CRITICAL+HIGH). **IaC**: Checkov. All in CI pipeline. | `build-java.yml`, `build-python.yml`, `security-scan/action.yml` |

---

## SA — System and Services Acquisition

| Control | Title | Status | Implementation | Evidence |
|---------|-------|--------|----------------|----------|
| **SA-11** | Developer Testing and Evaluation | ✅ Implemented | 652+ automated tests (356 gateway + 274 unit + 22 contract). Integration tests with LocalStack. E2E tests with real Cognito auth. Architecture tests (ArchUnit). FIPS crypto tests. Load tests (k6). | Test suites in all repos |

---

## SC — System and Communications Protection

| Control | Title | Status | Implementation | Evidence |
|---------|-------|--------|----------------|----------|
| **SC-7** | Boundary Protection | ✅ Implemented | WAFv2 with AWS managed rules (Core Rule Set, SQL injection, known bad inputs). IP rate limiting (2000 req/5min). Security groups restrict egress to 443+53. VPC Endpoints eliminate internet routing. | `terraform/modules/api-gateway/main.tf` — WAF, `networking/main.tf` — SGs |
| **SC-8** | Transmission Confidentiality | ✅ Implemented | TLS 1.2+ at API Gateway edge. FIPS endpoints for all AWS SDK calls. `DenyUnencryptedTransport` and `DenyOutdatedTLS` policies on S3. HSTS header. | `docs/TLS_ARCHITECTURE.md` |
| **SC-8(1)** | Cryptographic Protection | ✅ Implemented | FIPS 140-3 validated crypto providers for all TLS connections (ACCP, BC-FIPS, OpenSSL FIPS). | `FipsCryptoConfig.java`, `crypto_provider.py` |
| **SC-12** | Cryptographic Key Establishment | ✅ Implemented | AWS KMS CMK with automatic annual rotation. Key policy restricts to designated service principals. Symmetric AES-256 (SYMMETRIC_DEFAULT). | `terraform/modules/security/main.tf` — KMS key, rotation, policy |
| **SC-13** | Cryptographic Protection | ✅ Implemented | AES-256-GCM for data at rest. SHA-256/384/512 for integrity. All via FIPS 140-3 validated modules. `approved_only=true` restricts to FIPS-approved algorithms. | `FipsCryptoConfig.java`, KMS configuration |
| **SC-28** | Protection of Information at Rest | ✅ Implemented | S3: SSE-KMS (AES-256-GCM) on all buckets. DynamoDB: SSE-KMS on all 4 tables. CloudTrail logs: SSE-KMS. SNS/SQS: SSE-KMS. | `terraform/modules/storage/main.tf`, `messaging/main.tf` |
| **SC-28(1)** | Cryptographic Protection (at rest) | ✅ Implemented | KMS CMK (not AWS-managed key). Key tagged `Compliance = FIPS-140-3`. Deletion window: 7 days minimum. | `terraform/modules/security/main.tf` — `aws_kms_key` |

---

## SI — System and Information Integrity

| Control | Title | Status | Implementation | Evidence |
|---------|-------|--------|----------------|----------|
| **SI-2** | Flaw Remediation | ✅ Implemented | Dependabot weekly PRs (Maven, pip, Docker, GH Actions, Terraform). OWASP dep-check + pip-audit + safety in CI. Trivy image scanning. | `dependabot.yml` (all 5 repos), CI pipelines |
| **SI-4** | System Monitoring | ✅ Implemented | GuardDuty threat detection (S3 + CloudTrail + DNS). 9 CloudWatch alarms + composite critical alarm. VPC Flow Logs. | `terraform/modules/audit/main.tf` — GuardDuty, `observability/main.tf` |
| **SI-7** | Software and Information Integrity | ✅ Implemented | CloudTrail log file validation. Docker image provenance attestation (BuildKit). cosign keyless signing (Sigstore/Fulcio OIDC). SBOM attached to images. | `docker-build/action.yml` — provenance + SBOM + cosign |
| **SI-10** | Information Input Validation | ✅ Implemented | Spring Bean Validation on DTOs. Apache Tika content-type detection (prevents extension spoofing). File size limits (configurable per profile). WAF SQL injection protection. | `FileUploadRequestDto.java`, `TikaContentValidatorAdapter.java`, WAF rules |
| **SI-11** | Error Handling | ✅ Implemented | Prod profile: `server.error.include-message: never`, `include-binding-errors: never`, `include-stacktrace: never`. Custom error handlers return safe JSON responses. | `application.yml` — prod profile, `CognitoAuthenticationEntryPoint.java` |

---

## Summary

| Family | Total Controls | Implemented | Partial | Inherited | N/A |
|--------|---------------|-------------|---------|-----------|-----|
| AC | 8 | 8 | 0 | 0 | 0 |
| AU | 7 | 7 | 0 | 0 | 0 |
| CM | 5 | 5 | 0 | 0 | 0 |
| CP | 2 | 0 | 2 | 0 | 0 |
| IA | 5 | 5 | 0 | 0 | 0 |
| IR | 3 | 3 | 0 | 0 | 0 |
| MP | 1 | 1 | 0 | 0 | 0 |
| PE | 1 | 0 | 0 | 1 | 0 |
| PL | 1 | 1 | 0 | 0 | 0 |
| RA | 1 | 1 | 0 | 0 | 0 |
| SA | 1 | 1 | 0 | 0 | 0 |
| SC | 7 | 7 | 0 | 0 | 0 |
| SI | 5 | 5 | 0 | 0 | 0 |
| **Total** | **47** | **44** | **2** | **1** | **0** |

**Compliance rate: 93.6%** (44 implemented + 1 inherited = 95.7% including inherited)
