# Security Review Notes

## Scope

This review covers the seven FSAMP repositories: `fsamp-infra`, `fsamp-gateway`,
`fsamp-processor`, `fsamp-event-schema`, `fsamp-code-ci`, `fsamp-demo-flow`, and
the technical evidence in `fsamp-thesis`.

The document records FedRAMP Moderate alignment work and FIPS 140-3-oriented
security decisions. It is not a FedRAMP authorization package and does not
represent an ATO.

## Current Posture

| Area | Status | Notes |
|---|---|---|
| Identity and access | Aligned | Cognito, OAuth2/JWT validation, scoped IAM, environment approvals |
| Cryptography | Aligned | AWS KMS, FIPS-capable providers, FIPS endpoints outside local mode |
| Data protection | Aligned | S3, DynamoDB, SQS, SNS, CloudWatch Logs encrypted with KMS in the `us-west-2` baseline |
| Network security | Aligned | Private compute, VPC endpoints, security groups, WAF, TLS policies |
| Audit and monitoring | Implemented, activation pending | Terraform provisions CloudTrail, GuardDuty, AWS Config, CloudWatch alarms, and structured logs; no live AWS environment currently provides operational evidence |
| CI/CD integrity | Aligned | reusable workflows, SBOM, dependency scanning, image signing, Terraform scanning |
| Local development | Controlled exception | LocalStack uses local endpoints and disables FIPS-only runtime checks where needed |

## Evidence Map

| Control Area | Evidence |
|---|---|
| FIPS-oriented Java runtime | `fsamp-gateway` uses Corretto, ACCP/BC-FIPS providers, startup crypto checks, and FIPS-enabled AWS SDK clients |
| FIPS-oriented Python runtime | `fsamp-processor` enables OpenSSL FIPS provider in container images and uses boto3 FIPS endpoint configuration |
| KMS encryption | `terraform/modules/security`, `terraform/modules/storage`, `terraform/modules/messaging`, `terraform/modules/compute` |
| Transport protection | `docs/TLS_ARCHITECTURE.md`, S3/SQS/SNS policies, API Gateway/ALB TLS path |
| Audit trail | `terraform/modules/audit`, CloudTrail log validation, GuardDuty, AWS Config |
| Least privilege | `terraform/modules/security`, task and Lambda roles scoped to platform resources |
| Deployment controls | `fsamp-infra/.github/workflows/deploy.yml`, GitHub Environments for `staging` and `prod` approvals |
| Supply-chain checks | `fsamp-code-ci` reusable workflows and composite actions |

## Remediated Items

| Item | Resolution |
|---|---|
| Audit services were optional by default | CloudTrail, GuardDuty, and AWS Config default to enabled for non-local environments |
| Container images were unsigned | Docker build action signs pushed images with keyless cosign; deploy verifies signatures and passes immutable `repo@sha256` image references to Terraform |
| Processor S3 upload could fall back to SSE-S3 | Upload now requires a configured KMS key |
| TLS termination was implicit | TLS architecture is documented with the edge and private-network trust boundaries |
| Deployment was build-only | Infra workflow now supports dev auto-deploy, staging/prod approvals, and rollback |

## Accepted Risks

| Risk | Rationale | Follow-up |
|---|---|---|
| Cross-region replication is optional and disabled by default | Keeps active AWS resources in `us-west-2` for the academic/free-tier baseline | Activate via `enable_cross_region_replication=true` for a DR exercise or tenant requiring passive-region durability |
| Non-production token lifetime can be longer than prod | Developer ergonomics in dev/staging | Keep prod at shorter lifetime |
| LocalStack is not a compliance boundary | It is only a local integration test target | Keep production controls enforced in AWS profiles |

## Next Improvements

| Priority | Recommendation |
|---|---|
| Medium | Add scheduled restore/rollback exercise and record results |
| Medium | Add threat model notes for upload, event, and storage flows |
| Low | Add CloudWatch SLO burn-rate alarms after real traffic exists |

## Conclusion

FSAMP is a strong FedRAMP Moderate-aligned reference implementation with a
FIPS 140-3-oriented security posture. The current codebase avoids claiming formal
FedRAMP authorization or cryptographic module validation for the whole system,
which is the right wording for an academic project without external assessment.

The processor now installs hash-pinned `requirements.lock` and
`requirements-dev.lock` files in CI and container builds. LocalStack E2E uses
the same AL2023 Lambda/FIPS image as the production path; only AWS FIPS endpoint
selection is disabled because calls terminate at the local emulator.
