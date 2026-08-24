# Disaster Recovery Plan

> **Classification:** Internal | **Owner:** Platform Engineering  
> **FedRAMP Controls:** CP-2, CP-6, CP-7, CP-9, CP-10  
> **Last Review:** 2026-05-24 | **Next Review:** 2026-11-24

## 1. Overview

This document defines the Disaster Recovery (DR) strategy for the FSAMP platform — a
secure, event-driven microservice system running on AWS. The plan ensures business
continuity and data integrity in the event of infrastructure failures, regional outages,
or security incidents.

### Scope

| Component         | Type            | AWS Service                |
|-------------------|-----------------|----------------------------|
| Gateway           | Microservice    | ECS Fargate                |
| Processor         | Event handler   | Lambda (container image)   |
| Object Storage    | Data            | S3 (SSE-KMS, versioning)   |
| Metadata Store    | Data            | DynamoDB                   |
| Event Bus         | Messaging       | SQS + SNS                  |
| Secrets & Keys    | Security        | KMS, Secrets Manager       |
| Infrastructure    | IaC             | Terraform (S3 backend)     |

## 2. Recovery Objectives

### Platform-Level SLOs

| Metric | Target | Justification |
|--------|--------|---------------|
| **RPO** (Recovery Point Objective) | ≤ 1 hour | DynamoDB PITR (continuous), S3 versioning |
| **RTO** (Recovery Time Objective) | ≤ 4 hours | Terraform re-deploy from clean state |
| **MTTR** (Mean Time To Repair) | ≤ 2 hours | Automated deploy pipeline + health checks |

### Per-Service Recovery Breakdown

| Service | RPO | RTO | Strategy | Notes |
|---------|-----|-----|----------|-------|
| Gateway (ECS) | N/A (stateless) | 15 min | Redeploy from GHCR image | Auto-scaling handles transient failures |
| Processor (Lambda) | N/A (stateless) | 10 min | Redeploy from ECR image | SQS retries absorb cold-start window |
| S3 Buckets | ≤ 1 hour for logical recovery | 30 min | Versioning; optional CRR exercise | MFA Delete reviewed as an AWS-account operational control |
| DynamoDB | ≤ 1 hour (continuous) | 30 min | PITR + On-demand restore | 35-day continuous backup window |
| SQS Queues | Message retention: 4 days | 5 min | Recreate via Terraform | Messages in-flight may be lost |
| KMS Keys | N/A (AWS-managed) | Immediate | Multi-AZ by design | Key material never leaves HSM |
| Terraform State | ≤ 1 hour | 15 min | S3 versioning + DynamoDB lock | State bucket has versioning enabled |

## 3. DR Strategy: Pilot Light

FSAMP uses a **single-region baseline with Pilot Light recovery**. The active AWS
deployment is pinned to `us-west-2`; optional cross-region replication can be
enabled explicitly for a higher-assurance DR exercise, but it is disabled by
default for the thesis/free-tier baseline.

### Active (always running)

- S3 buckets with versioning and optional cross-region replication when
  `enable_cross_region_replication=true`
- DynamoDB tables with PITR enabled
- Customer-managed regional KMS keys
- Terraform state backend (versioned S3 + DynamoDB)
- CloudTrail + GuardDuty (continuous monitoring)

### On-demand (activated during DR)

- ECS Fargate tasks (Gateway)
- Lambda functions (Processor)
- API Gateway + WAF
- VPC / networking stack
- Cognito user pool (federated, region-specific)

## 4. Recovery Procedures

### 4.1 Single Service Failure (ECS / Lambda)

**Trigger:** Health check failure, OOM, crash loop  
**RTO:** < 15 minutes  
**Action:** Automatic

```text
1. ECS auto-replaces unhealthy tasks (health check grace period: 60s)
2. Lambda: SQS retry policy re-invokes on failure (maxRetries: 3)
3. DLQ captures permanently failed messages for manual review
4. CloudWatch alarm -> SNS -> on-call notification
```

### 4.2 Data Corruption / Accidental Deletion

**Trigger:** Operator error, application bug  
**RTO:** < 1 hour

```text
1. S3: Restore from version history
   aws s3api list-object-versions --bucket fsamp-<env>-storage
   aws s3api get-object --bucket fsamp-<env>-storage --key <key> --version-id <id> restored.bin

2. DynamoDB: Restore from PITR
   aws dynamodb restore-table-to-point-in-time \
     --source-table-name fsamp-<env>-metadata \
     --target-table-name fsamp-<env>-metadata-restored \
     --restore-date-time <ISO-8601>

3. Validate restored data integrity
4. Swap table references via Terraform variable or alias
```

### 4.3 Full Environment Rebuild

**Trigger:** Region outage, catastrophic failure, security incident  
**RTO:** ≤ 4 hours

```text
Step 1: Verify prerequisites (30 min)
  - Confirm Terraform state accessible from the versioned `us-west-2` backend
  - Confirm signed ECR image digests are available for the selected image tag
  - Confirm KMS key policy and Terraform state can recreate required keys

Step 2: Deploy infrastructure (60 min)
  cd fsamp-infra/terraform
  terraform init -backend-config=backends/<env>.hcl
  terraform plan -var-file=envs/<env>.tfvars
  terraform apply -var-file=envs/<env>.tfvars

Step 3: Verify services (30 min)
  - ECS tasks running: aws ecs describe-services --cluster fsamp-<env>
  - Lambda active: aws lambda get-function --function-name fsamp-<env>-processor
  - API Gateway responding: curl -f https://api.<env>.fsamp.example.com/health

Step 4: Restore data (60 min)
  - DynamoDB: PITR restore to new tables
  - S3: Restore from version history; verify CRR replica only when the optional DR flag was enabled
  - Re-process DLQ messages if applicable

Step 5: Validation (60 min)
  - Run E2E test suite against restored environment
  - Verify FIPS crypto provider loaded (check /actuator/info)
  - Confirm CloudTrail + GuardDuty active
  - Notify stakeholders of recovery completion
```

### 4.4 Security Incident (Compromised Credentials)

**Trigger:** GuardDuty finding, unauthorized access detected  
**RTO:** < 2 hours

```text
1. IMMEDIATE: Rotate affected IAM credentials / KMS keys
   aws iam update-access-key --status Inactive --access-key-id <key>

2. Revoke Cognito tokens (force re-authentication)
   aws cognito-idp admin-global-sign-out --user-pool-id <pool> --username <user>

3. Review CloudTrail logs for blast radius
   aws cloudtrail lookup-events --lookup-attributes AttributeKey=EventSource

4. Redeploy with rotated secrets via Terraform
   terraform apply -var-file=envs/<env>.tfvars -replace=module.security

5. Post-incident review (within 48h)
```

## 5. Backup Configuration

| Resource | Backup Method | Frequency | Retention | Encryption |
|----------|--------------|-----------|-----------|------------|
| S3 objects | Versioning; optional CRR | Continuous | 90 days (lifecycle) | SSE-KMS (FIPS-oriented) |
| DynamoDB | PITR | Continuous | 35 days | AWS-managed KMS |
| Terraform state | S3 versioning | On every apply | 365 days | SSE-KMS |
| Container images | GHCR + ECR | On every CI build | 90 days (lifecycle) | At rest |
| CloudTrail logs | S3 export | Continuous | 365 days | SSE-KMS |
| Secrets | AWS Secrets Manager | On rotation | N/A (version history) | KMS |

## 6. DR Testing Schedule

### Quarterly DR Drill Procedure

| Quarter | Test Type | Scope | Success Criteria |
|---------|-----------|-------|------------------|
| Q1 | Tabletop exercise | Full platform | Team completes runbook in < 4h |
| Q2 | Service failover | ECS + Lambda | Services recover within RTO |
| Q3 | Data restoration | DynamoDB PITR + S3 | Data integrity verified |
| Q4 | Full rebuild | Terraform from scratch | Environment operational in < 4h |

### Test Execution Checklist

```text
□ Schedule drill with all stakeholders (1 week notice)
□ Snapshot current environment state
□ Execute recovery procedure per Section 4
□ Measure actual RTO and RPO
□ Document any deviations from plan
□ Update this document with lessons learned
□ File DR test report in docs/dr-reports/YYYY-QN.md
```

## 7. Communication Plan

| Event | Notification | Channel | Timeframe |
|-------|-------------|---------|-----------|
| Service degradation | CloudWatch Alarm -> SNS | PagerDuty / Slack | Immediate |
| DR activation | Incident Commander | Slack #incidents | Within 15 min |
| Recovery progress | IC updates | Slack #incidents | Every 30 min |
| Recovery complete | IC -> stakeholders | Email + Slack | On completion |
| Post-mortem | Engineering lead | Confluence / docs | Within 48h |

## 8. Dependencies & Contacts

| Role | Responsibility |
|------|---------------|
| Incident Commander | Coordinates recovery, communicates status |
| Platform Engineer | Executes Terraform, verifies infrastructure |
| Application Engineer | Validates service health, data integrity |
| Security Engineer | Credential rotation, forensics |

## 9. Compliance Mapping

| FedRAMP Control | Description | Implementation |
|-----------------|-------------|----------------|
| CP-2 | Contingency Plan | This document |
| CP-6 | Alternate Storage Site | Optional S3 CRR exercise; signed ECR images rebuildable from CI |
| CP-7 | Alternate Processing Site | Multi-AZ ECS, Lambda |
| CP-9 | Information System Backup | PITR, S3 versioning, Terraform state |
| CP-10 | System Recovery & Reconstitution | Terraform apply from clean state |
| IR-4 | Incident Handling | Section 4.4, GuardDuty integration |
| SC-28 | Protection of Information at Rest | SSE-KMS with customer-managed KMS keys |

---

*This document is reviewed quarterly and updated after every DR drill or actual incident.*
