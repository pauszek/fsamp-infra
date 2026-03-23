# Security Policy

## Compliance Framework

The FSAMP platform is designed to meet **FIPS 140-3** and **FedRAMP Moderate** baseline requirements. All cryptographic operations use NIST-validated modules, and infrastructure follows NIST SP 800-53 Rev. 5 control families.

| Standard | Status | Scope |
|----------|--------|-------|
| FIPS 140-3 | Implemented | ACCP (CMVP #4631), BC-FIPS (CMVP #4743), AWS KMS (Level 3), OpenSSL FIPS provider |
| FedRAMP Moderate | Aligned | AC, AU, CM, IA, SC, SI control families implemented; see ADR-004 |
| NIST SP 800-53 Rev. 5 | Referenced | Technical controls mapped in Terraform modules |

## Supported Versions

| Component | Version | Supported |
|-----------|---------|-----------|
| fsamp-gateway | >= 0.0.3 | ✅ |
| fsamp-processor | >= 0.0.5 | ✅ |
| fsamp-infra | >= 0.0.2 | ✅ |
| fsamp-event-schema | >= 0.0.8 | ✅ |

Older versions are not maintained. Always deploy the latest release.

## Reporting a Vulnerability

**Do NOT open a public GitHub Issue for security vulnerabilities.**

### Responsible Disclosure

1. **Email**: Send a detailed report to `security@fsamp.example.com`
2. **Include**:
   - Description of the vulnerability
   - Steps to reproduce
   - Affected component(s) and version(s)
   - Potential impact assessment (CVSS score if known)
   - Any suggested remediation
3. **Response timeline**:
   - **Acknowledgement**: Within 48 hours
   - **Initial assessment**: Within 5 business days
   - **Fix or mitigation**: Within 30 days for CRITICAL/HIGH, 90 days for MEDIUM/LOW
4. **Disclosure**: We follow a 90-day coordinated disclosure window

### Alternatively

If the repository has GitHub Advanced Security enabled, you can use the **Security Advisory** feature to privately report a vulnerability.

## Security Architecture

### Cryptographic Controls

| Layer | Technology | FIPS Module |
|-------|-----------|-------------|
| JVM TLS + crypto | Amazon Corretto Crypto Provider (ACCP) 2.4.1 | CMVP #4631 (Level 1) |
| JVM supplementary | BouncyCastle FIPS 2.0.0 | CMVP #4743 |
| Python TLS + crypto | OpenSSL 3.x FIPS provider (AL2023) | CMVP #4694 |
| Key management | AWS KMS (HSM-backed) | FIPS 140-3 Level 3 |
| Encryption at rest | AES-256-GCM via KMS CMK | NIST SP 800-38D |

### Network Security

- VPC with public/private/database subnet tiers
- Security groups restricted to HTTPS (443) + DNS (53) egress only (FedRAMP SC-7)
- VPC Endpoints for S3, DynamoDB, ECR, CloudWatch, SQS, SNS, KMS
- NACLs on all subnet tiers
- WAF with OWASP Core Rule Set, SQL injection protection, IP rate limiting

### Access Control

- Cognito User Pool with OAuth2/OIDC (JWT RS256)
- MFA enforced in production (TOTP)
- RBAC: `ROLE_ADMINS`, `ROLE_USERS` with scope-based authorization (`files.read`, `files.write`)
- 30-minute access token lifetime in production (FedRAMP AC-12)
- Swagger UI restricted to `ROLE_ADMINS` in staging/prod (FedRAMP AC-3)

### Audit & Monitoring

- CloudTrail (multi-region, log file integrity validation)
- GuardDuty threat detection
- AWS Config (5 compliance rules)
- VPC Flow Logs
- S3 server access logging
- 9 CloudWatch alarms + composite critical alarm
- Structured JSON logging with correlation IDs

### Transport Security

- TLS 1.2+ enforced on all S3 bucket policies
- SQS/SNS deny unencrypted transport policies
- FIPS endpoints for all AWS SDK clients in US regions
- HTTPS-only API Gateway

## Known Limitations

| Limitation | Impact | Mitigation |
|-----------|--------|------------|
| Single-region deployment | No geographic redundancy | DynamoDB PITR, S3 versioning, Terraform rebuild strategy |
| FIPS endpoints US-only | FIPS disabled in non-US regions | Region guard in AwsConfig (`region.startsWith("us-")`) |
| ACCP requires Corretto JVM | Vendor lock to Amazon Corretto | BC-FIPS as fallback provider at position 2 |
| Lambda container cold-start | ~1-2s additional latency | Provisioned concurrency (configurable per environment) |

## Dependency Management

- **Java**: OWASP Dependency-Check in CI pipeline (fail on CVSS ≥ 7.0)
- **Python**: `pip-audit` in CI pipeline
- **Containers**: Trivy scan-on-push (CRITICAL/HIGH fail), ECR scan-on-push
- **Terraform**: Checkov IaC security scanning
- **Automated updates**: Dependabot configured for Maven, pip, Terraform, Docker, GitHub Actions

## Incident Response

1. **Detection**: GuardDuty findings → SNS → CloudWatch alarm
2. **Triage**: Review CloudTrail logs, VPC Flow Logs, application logs
3. **Containment**: Security group lockdown, Cognito user disable, KMS key disable
4. **Recovery**: Terraform redeploy, DynamoDB PITR restore, S3 version restore
5. **Post-mortem**: Document in ADR format, update runbooks

## References

- [NIST SP 800-53 Rev. 5](https://csrc.nist.gov/publications/detail/sp/800-53/rev-5/final)
- [FIPS 140-3](https://csrc.nist.gov/publications/detail/fips/140/3/final)
- [FedRAMP Security Controls](https://www.fedramp.gov/)
- [ADR-004: FIPS 140-3 Encryption & FedRAMP Compliance](docs/adr/004-fips-140-3-encryption.md)
- [SLO/SLI Definitions](docs/SLO_SLI.md)
