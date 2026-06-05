# NIST SP 800-53 Rev. 5 — Control Implementation Matrix

## FSAMP — FedRAMP-aligned Secure AWS Microservices Platform

> FedRAMP Moderate Baseline — Selected Controls

Note: This matrix reflects alignment to the FedRAMP Moderate baseline and does not
represent FedRAMP authorization or an ATO.

| Legend | Meaning |
|--------|---------|
| Aligned | Control fully aligned and tested |
| Partially aligned | Core requirements met; enhancements planned |
| Inherited | AWS responsibility under shared responsibility model |
| ➖ N/A | Not applicable to this system |

---

## AC — Access Control

| Control | Title | Status | Implementation | Evidence |
|---------|-------|--------|----------------|----------|
| **AC-2** | Account Management | Aligned | Cognito User Pool with groups (`ROLE_ADMINS`, `ROLE_USERS`). Self-registration disabled. Admin-provisioned accounts only. | `terraform/modules/auth/main.tf` — `aws_cognito_user_pool`, `aws_cognito_user_group` |
| **AC-2(1)** | Automated Account Management | Aligned | Cognito handles account lifecycle. Token expiration enforced (30 min prod, 60 min dev). | `terraform/modules/auth/main.tf` — `access_token_validity` |
| **AC-3** | Access Enforcement | Aligned | OAuth2 scope-based authorization (`files.read`, `files.write`). Spring Security `@PreAuthorize` on controllers. Swagger UI restricted to `ROLE_ADMINS` in prod. | `SecurityConfig.java`, `FileUploadRestAdapter.java` — `@PreAuthorize("hasAuthority('SCOPE_files.write')")` |
| **AC-4** | Information Flow Enforcement | Aligned | Profile-aware CORS policies (restrictive in prod, permissive in local). Content-Security-Policy, X-Frame-Options, X-Content-Type-Options headers. WAF rules. | `CorsConfig.java`, `SecurityConfig.java` — security headers, `api-gateway/main.tf` — WAF |
| **AC-6** | Least Privilege | Aligned | IAM roles scoped per service (ECS, Lambda). Resource ARN restrictions on KMS, S3, DynamoDB, SQS, SNS. Lambda role more restrictive than ECS role (no S3 Delete, no SQS Send). | `terraform/modules/security/main.tf` — lines 142-306 |
| **AC-6(1)** | Authorize Access to Security Functions | Aligned | KMS key policy restricts key operations to designated service principals with `CallerAccount` condition. | `terraform/modules/security/main.tf` — KMS key policy |
| **AC-12** | Session Termination | Aligned | Cognito access token lifetime: 30 min (prod), 60 min (dev/staging). Refresh token: 24 hours. No server-side sessions (stateless JWT). | `terraform/modules/auth/main.tf` — `access_token_validity`, `id_token_validity` |
| **AC-17** | Remote Access | Aligned | All API access over HTTPS (TLS 1.2+). HSTS header enforced. No direct SSH/RDP access to infrastructure (Fargate serverless). | `SecurityConfig.java` — HSTS, API Gateway TLS |

---

## AU — Audit and Accountability

| Control | Title | Status | Implementation | Evidence |
|---------|-------|--------|----------------|----------|
| **AU-2** | Event Logging | Aligned | CloudTrail (multi-region, management + data events). Application-level structured JSON logging. All API calls logged with correlation ID. | `terraform/modules/audit/main.tf` — `aws_cloudtrail`, `application.yml` — structlog |
| **AU-3** | Content of Audit Records | Aligned | Audit records include: timestamp (ISO 8601), source IP, user identity, action, resource, outcome, correlation ID, request ID. | `CorrelationIdFilter.java`, `DynamoDbFileRepositoryAdapter.java` — `@FedRAMP AU-3` annotations |
| **AU-3(1)** | Additional Audit Information | Aligned | File checksum (SHA-256), encryption algorithm, KMS key ID, content type, file size logged on every upload. | `FileUploadDomainService.java` — structured log fields |
| **AU-4** | Audit Log Storage | Aligned | CloudTrail logs -> S3 with lifecycle (90d -> IA, 365d -> Glacier, 7yr expiry in prod). CloudWatch Logs with configurable retention. | `terraform/modules/audit/main.tf` — lifecycle rules |
| **AU-6** | Audit Record Review | Aligned | CloudWatch Insights queries available. GuardDuty automated threat review. 9 CloudWatch alarms for anomaly detection. | `terraform/modules/observability/main.tf` — alarms, dashboards |
| **AU-9** | Protection of Audit Information | Aligned | CloudTrail S3 bucket: SSE-KMS encryption, versioning, public access blocked, `DenyUnencryptedTransport` policy. Log file validation enabled. | `terraform/modules/audit/main.tf` — bucket policy, `enable_log_file_validation = true` |
| **AU-12** | Audit Record Generation | Aligned | System-wide: CloudTrail (API), VPC Flow Logs (network), S3 access logs (data), application logs (business). | Multiple modules |

---

## CM — Configuration Management

| Control | Title | Status | Implementation | Evidence |
|---------|-------|--------|----------------|----------|
| **CM-2** | Baseline Configuration | Aligned | All infrastructure defined in Terraform (10 modules). State file in S3 with DynamoDB locking. AWS Config tracks configuration changes. | `terraform/` — all modules, `terraform/modules/audit/main.tf` — Config |
| **CM-3** | Configuration Change Control | Aligned | All changes via Git PRs with required reviews. CI pipeline validates: build, test, SAST, SCA, IaC scan. Auto-versioning with `release.version`. Daily Terraform drift detection (`drift-detection.yml`) opens a labelled GitHub Issue when live state diverges from code; the issue is auto-closed once drift is reconciled. | `.github/workflows/` — build pipelines, `bump-release-version` action, `drift-detection.yml` |
| **CM-6** | Configuration Settings | Aligned | Security hardening: Spring Boot prod profile disables error details (`server.error.include-message: never`), non-essential actuator endpoints filtered. Terraform Checkov scanning. | `application.yml` — prod profile, `.checkov.yml` |
| **CM-7** | Least Functionality | Aligned | Docker images: multi-stage builds, non-root users (UID 1001/1000), minimal base images (Corretto 21 headless, Python slim-bookworm). No SSH, no unnecessary packages. | `Dockerfile` (gateway), `Dockerfile` (processor) |
| **CM-8** | System Component Inventory | Aligned | SBOM generated for every build (CycloneDX). Terraform tracks all AWS resources. Dependabot monitors all ecosystems. | `pom.xml` — CycloneDX Maven plugin, `build-python.yml` — cyclonedx-bom |

---

## CP — Contingency Planning

| Control | Title | Status | Implementation | Evidence |
|---------|-------|--------|----------------|----------|
| **CP-9** | System Backup | Aligned | DynamoDB Point-in-Time Recovery enabled. S3 versioning on all buckets. Terraform state backed up in S3 with versioning. Cross-region replication module (`terraform/modules/replication`) replicates `files`, `processed`, and CloudTrail buckets to a secondary region with a region-local KMS key (feature-flagged via `enable_cross_region_replication`, default on for prod and staging). | `terraform/modules/storage/main.tf` — PITR, versioning, `terraform/modules/replication/main.tf` |
| **CP-10** | System Recovery | Aligned | Pilot Light DR strategy with replicated buckets in the secondary region (RTC 15 min). Full Terraform rebuild possible in any US region. RTO: 4 hours, RPO: 15 minutes (replicated buckets) / 24 hours (DynamoDB PITR). | `docs/DISASTER_RECOVERY.md`, `terraform/modules/replication/main.tf` |

---

## IA — Identification and Authentication

| Control | Title | Status | Implementation | Evidence |
|---------|-------|--------|----------------|----------|
| **IA-2** | User Identification and Authentication | Aligned | Cognito User Pool with unique user IDs. OAuth2/OIDC with RS256 JWT. Account lockout after failed attempts. | `terraform/modules/auth/main.tf` — `aws_cognito_user_pool` |
| **IA-2(1)** | Multi-factor Authentication — Privileged | Aligned | MFA (TOTP) enforced for all users in production (`mfa_configuration = "ON"`). | `terraform/modules/auth/main.tf` — `mfa_configuration` |
| **IA-5** | Authenticator Management | Aligned | Password policy: min 12 chars (prod), uppercase, lowercase, numbers, symbols required. Temporary password validity: 1 day. | `terraform/modules/auth/main.tf` — `password_policy` |
| **IA-5(1)** | Password-Based Authentication | Aligned | Cognito enforces password complexity. No plaintext password storage. Secrets (API tokens) managed via GitHub Secrets / AWS Secrets Manager. | `terraform/modules/auth/main.tf`, CI secrets configuration |
| **IA-7** | Cryptographic Module Authentication | Aligned | Crypto paths are configured for FIPS-capable providers (ACCP, BC-FIPS, OpenSSL FIPS) where the runtime supports them. | `FipsCryptoConfig.java`, `crypto_provider.py` |

---

## IR — Incident Response

| Control | Title | Status | Implementation | Evidence |
|---------|-------|--------|----------------|----------|
| **IR-4** | Incident Handling | Aligned | GuardDuty automated threat detection -> SNS notifications. Documented response procedures: containment (SG lockdown, Cognito disable, KMS disable), recovery (Terraform redeploy). | `SECURITY.md` — Incident Response section, `docs/DISASTER_RECOVERY.md` |
| **IR-5** | Incident Monitoring | Aligned | GuardDuty findings with 15-min publishing (prod). CloudWatch composite alarm for critical incidents. | `terraform/modules/audit/main.tf` — GuardDuty, `observability/main.tf` |
| **IR-6** | Incident Reporting | Aligned | GuardDuty findings exportable. CloudTrail provides audit trail for forensics. ADR format for post-mortems. | Process documented in `SECURITY.md` |

---

## MP — Media Protection

| Control | Title | Status | Implementation | Evidence |
|---------|-------|--------|----------------|----------|
| **MP-5** | Media Transport | Aligned | All data in transit encrypted with TLS 1.2+. `DenyUnencryptedTransport` bucket policies on S3. SQS/SNS deny non-TLS access. FIPS endpoints for all AWS API calls. | `terraform/modules/storage/main.tf`, `messaging/main.tf` — deny policies |

---

## PE — Physical and Environmental Protection

| Control | Title | Status | Implementation | Evidence |
|---------|-------|--------|----------------|----------|
| **PE-**** | All PE controls | Inherited | AWS manages physical security for all data center facilities under the shared responsibility model. | AWS shared responsibility model |

---

## PL — Planning

| Control | Title | Status | Implementation | Evidence |
|---------|-------|--------|----------------|----------|
| **PL-8** | Security Architecture | Aligned | Architecture documented: hex arch, 5-layer security model, data flow diagrams, TLS termination model. ADR process for design decisions. | `ARCHITECTURE.md`, `docs/TLS_ARCHITECTURE.md`, 7 ADRs |

---

## RA — Risk Assessment

| Control | Title | Status | Implementation | Evidence |
|---------|-------|--------|----------------|----------|
| **RA-5** | Vulnerability Scanning | Aligned | **Java**: OWASP Dependency-Check (CVSS ≥ 7 gate). **Python**: pip-audit, bandit, safety. **Containers**: Trivy (CRITICAL+HIGH). **IaC**: Checkov. All in CI pipeline. | `build-java.yml`, `build-python.yml`, `security-scan/action.yml` |

---

## SA — System and Services Acquisition

| Control | Title | Status | Implementation | Evidence |
|---------|-------|--------|----------------|----------|
| **SA-11** | Developer Testing and Evaluation | Aligned | 686 automated tests (362 gateway + 324 processor unit) plus contract and integration tests with LocalStack. E2E tests with real Cognito auth. Architecture tests (ArchUnit). FIPS crypto tests. Load tests (k6). | Test suites in all repos |

---

## SC — System and Communications Protection

| Control | Title | Status | Implementation | Evidence |
|---------|-------|--------|----------------|----------|
| **SC-7** | Boundary Protection | Aligned | WAFv2 with AWS managed rules (Core Rule Set, SQL injection, known bad inputs). IP rate limiting (2000 req/5min). Security groups restrict egress to 443+53. VPC Endpoints eliminate internet routing. | `terraform/modules/api-gateway/main.tf` — WAF, `networking/main.tf` — SGs |
| **SC-8** | Transmission Confidentiality | Aligned | TLS 1.2+ at API Gateway edge. FIPS endpoints for all AWS SDK calls. `DenyUnencryptedTransport` and `DenyOutdatedTLS` policies on S3. HSTS header. | `docs/TLS_ARCHITECTURE.md` |
| **SC-8(1)** | Cryptographic Protection | Aligned | FIPS-capable crypto providers for TLS paths (ACCP, BC-FIPS, OpenSSL FIPS) where the runtime supports them. | `FipsCryptoConfig.java`, `crypto_provider.py` |
| **SC-12** | Cryptographic Key Establishment | Aligned | AWS KMS CMK with automatic annual rotation. Key policy restricts to designated service principals. Symmetric AES-256 (SYMMETRIC_DEFAULT). | `terraform/modules/security/main.tf` — KMS key, rotation, policy |
| **SC-13** | Cryptographic Protection | Aligned | AES-256-GCM for data at rest. SHA-256/384/512 for integrity. Runtime config restricts application crypto to approved algorithms where provider support is available. | `FipsCryptoConfig.java`, KMS configuration |
| **SC-28** | Protection of Information at Rest | Aligned | S3: SSE-KMS (AES-256-GCM) on all buckets. DynamoDB: SSE-KMS on all 4 tables. CloudTrail logs: SSE-KMS. SNS/SQS: SSE-KMS. | `terraform/modules/storage/main.tf`, `messaging/main.tf` |
| **SC-28(1)** | Cryptographic Protection (at rest) | Aligned | Customer-managed KMS key. Key tagged `Compliance = FIPS-140-3-Oriented`. Deletion window: 7 days minimum. Replicated buckets in the secondary region are encrypted with a dedicated regional KMS key (replication module sets `kms_key_id` per destination). | `terraform/modules/security/main.tf` — `aws_kms_key`, `terraform/modules/replication/main.tf` |

---

## SR — Supply Chain Risk Management

| Control | Title | Status | Implementation | Evidence |
|---------|-------|--------|----------------|----------|
| **SR-3** | Supply Chain Controls and Processes | Aligned | Container images are signed with cosign keyless (Sigstore/Fulcio OIDC). CycloneDX SBOM is generated by syft and attached as an in-toto attestation via `cosign attest`. ECR enables `ENHANCED` continuous vulnerability scanning (Inspector). Reusable workflows are version-pinned per consumer repository; custom actions inside this repository are referenced via relative paths to keep the workflow file self-contained. | `.github/actions/docker-build/action.yml` — cosign + syft + attest, `terraform/modules/ecr/main.tf` — `aws_ecr_registry_scanning_configuration` |
| **SR-4** | Provenance | Aligned | Cosign attestations preserve OIDC certificate identity (workflow + repository), enabling a downstream verifier to confirm the image was built by a known workflow on a known commit. CI pipeline runs `cosign verify-attestation` against the published image before promotion. | `.github/actions/docker-build/action.yml` — `cosign verify-attestation`, `--certificate-identity-regexp` |

---

## SI — System and Information Integrity

| Control | Title | Status | Implementation | Evidence |
|---------|-------|--------|----------------|----------|
| **SI-2** | Flaw Remediation | Aligned | Dependabot weekly PRs (Maven, pip, Docker, GH Actions, Terraform). OWASP dep-check + pip-audit + safety in CI. Trivy image scanning. | `dependabot.yml` (all 5 repos), CI pipelines |
| **SI-4** | System Monitoring | Aligned | GuardDuty threat detection (S3 + CloudTrail + DNS). 9 CloudWatch alarms + composite critical alarm. VPC Flow Logs. | `terraform/modules/audit/main.tf` — GuardDuty, `observability/main.tf` |
| **SI-7** | Software and Information Integrity | Aligned | CloudTrail log file validation. Docker image provenance attestation (BuildKit). cosign keyless signing (Sigstore/Fulcio OIDC). SBOM attached to images. | `docker-build/action.yml` — provenance + SBOM + cosign |
| **SI-10** | Information Input Validation | Aligned | Spring Bean Validation on DTOs. Apache Tika content-type detection (prevents extension spoofing). File size limits (configurable per profile). WAF SQL injection protection. | `FileUploadRequestDto.java`, `TikaContentValidatorAdapter.java`, WAF rules |
| **SI-11** | Error Handling | Aligned | Prod profile: `server.error.include-message: never`, `include-binding-errors: never`, `include-stacktrace: never`. Custom error handlers return safe JSON responses. | `application.yml` — prod profile, `CognitoAuthenticationEntryPoint.java` |

---

## Summary

| Family | Total Controls | Aligned | Partial | Inherited | N/A |
|--------|---------------|-------------|---------|-----------|-----|
| AC | 8 | 8 | 0 | 0 | 0 |
| AU | 7 | 7 | 0 | 0 | 0 |
| CM | 5 | 5 | 0 | 0 | 0 |
| CP | 2 | 2 | 0 | 0 | 0 |
| IA | 5 | 5 | 0 | 0 | 0 |
| IR | 3 | 3 | 0 | 0 | 0 |
| MP | 1 | 1 | 0 | 0 | 0 |
| PE | 1 | 0 | 0 | 1 | 0 |
| PL | 1 | 1 | 0 | 0 | 0 |
| RA | 1 | 1 | 0 | 0 | 0 |
| SA | 1 | 1 | 0 | 0 | 0 |
| SC | 7 | 7 | 0 | 0 | 0 |
| SI | 5 | 5 | 0 | 0 | 0 |
| SR | 2 | 2 | 0 | 0 | 0 |
| **Total** | **49** | **48** | **0** | **1** | **0** |

**Alignment summary: 98.0%** (48 aligned + 1 inherited = 100% including inherited)
