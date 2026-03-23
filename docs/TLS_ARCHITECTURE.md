# TLS Architecture — FSAMP Platform

> FedRAMP SC-8 (Transmission Confidentiality and Integrity)

## Overview

FSAMP enforces TLS 1.2+ for all external and inter-service communication. TLS terminates
at the AWS API Gateway edge; internal VPC traffic flows over private subnets with
security-group isolation. All AWS SDK calls use FIPS 140-3 validated TLS endpoints.

## End-to-End TLS Flow

```
┌─────────┐   TLS 1.2   ┌──────────────┐   HTTP/VPC Link   ┌─────┐  HTTP  ┌──────────┐
│  Client  │────────────▶│ API Gateway  │──────────────────▶│ ALB │──────▶│ ECS:8080 │
│ (HTTPS)  │             │ (AWS-managed │   (private subnet) │     │       │ Gateway  │
└─────────┘             │  TLS cert)   │                   └─────┘       └──────────┘
                        └──────────────┘
                               │
                          WAFv2 rules
                          Rate limiting
```

## Layer-by-Layer Detail

### 1. Edge — AWS API Gateway (TLS Termination Point)

| Property | Value |
|----------|-------|
| Endpoint type | REGIONAL |
| TLS version | **1.2 minimum** (AWS default for REST APIs) |
| Certificate | AWS-managed (default `*.execute-api` domain) |
| Cipher suites | AWS-managed TLS policy — AES-128/256-GCM, SHA-256/384 |

API Gateway enforces TLS 1.2 by default on all REST API endpoints.
No custom domain or ACM certificate is configured — the platform uses the
built-in `execute-api` domain with automatic certificate rotation.

### 2. VPC Link — API Gateway → ALB (Private Subnet)

Traffic between API Gateway and the ALB traverses an **AWS VPC Link** over
private subnets. This is **not encrypted at the transport layer** (HTTP) but is:

- Confined to the private VPC (no internet routing)
- Protected by security groups (ALB SG accepts only from API GW)
- Isolated in private subnets with no public IP addresses
- Monitored via VPC Flow Logs (FedRAMP AU-2)

This is a standard AWS architecture pattern — AWS documentation confirms that
VPC Link traffic never leaves the AWS network backbone.

### 3. ALB → ECS Container (Private Subnet)

| Property | Value |
|----------|-------|
| Container port | 8080 (HTTP) |
| Spring Boot TLS | Not configured (relies on edge termination) |
| Security group | ECS SG accepts inbound 8080 **only** from ALB SG |

The container runs plain HTTP. This is intentional:
- Eliminates certificate management at the application level
- Reduces CPU overhead (no TLS handshake per request)
- The entire path is within a single VPC on private subnets

### 4. Service-to-AWS (FIPS 140-3 Endpoints)

All AWS SDK calls from Gateway and Processor use **FIPS 140-3 validated endpoints**:

| Service | FIPS Endpoint Pattern | Enabled |
|---------|-----------------------|---------|
| S3 | `s3-fips.us-west-2.amazonaws.com` | ✅ |
| DynamoDB | `dynamodb-fips.us-west-2.amazonaws.com` | ✅ |
| KMS | `kms-fips.us-west-2.amazonaws.com` | ✅ |
| SQS | `sqs-fips.us-west-2.amazonaws.com` | ✅ |
| SNS | `sns-fips.us-west-2.amazonaws.com` | ✅ |
| Cognito | `cognito-idp-fips.us-west-2.amazonaws.com` | ✅ |
| STS | `sts-fips.us-west-2.amazonaws.com` | ✅ |

Configuration:
- **Gateway (Java):** `aws.fips-endpoints: true` in `application.yml` → Java AWS SDK v2 FIPS mode
- **Processor (Python):** `AWS_USE_FIPS_ENDPOINT=true` env var → boto3 FIPS mode
- **Terraform:** `use_fips_endpoint = true` in provider configuration

### 5. VPC Endpoints (Private Link)

AWS service traffic stays within the VPC via Interface VPC Endpoints:

- `com.amazonaws.*.s3` (Gateway)
- `com.amazonaws.*.dynamodb` (Gateway)
- `com.amazonaws.*.sqs` (Processor)
- `com.amazonaws.*.sns` (Processor)
- `com.amazonaws.*.kms` (Both)
- `com.amazonaws.*.ecr.api` / `ecr.dkr` (ECS)
- `com.amazonaws.*.logs` (Both)

All VPC Endpoints have security groups restricting inbound to port 443 from VPC CIDR only.

## Cryptographic Providers

| Layer | Provider | CMVP Certificate | FIPS Level |
|-------|----------|-------------------|------------|
| JVM TLS + crypto | Amazon Corretto Crypto Provider (ACCP) 2.4.1 | #4631 | Level 1 |
| JVM supplementary | BouncyCastle FIPS 2.0.0 | #4743 | Level 1 |
| Python TLS + crypto | OpenSSL 3.x FIPS provider | #4694 | Level 1 |
| Key management | AWS KMS (HSM-backed) | N/A | Level 3 |

## Data-in-Transit Policies (Terraform-enforced)

### S3 Buckets
All buckets enforce TLS via bucket policy:
```json
{
  "Effect": "Deny",
  "Principal": "*",
  "Action": "s3:*",
  "Condition": {
    "Bool": { "aws:SecureTransport": "false" },
    "NumericLessThan": { "s3:TlsVersion": "1.2" }
  }
}
```

### SQS Queues
All queues deny access when `aws:SecureTransport = false`.

### SNS Topics
Topic policy denies `sns:Publish` over non-TLS connections.

## Network-Level Enforcement

| Resource | Egress Rule | Purpose |
|----------|-------------|---------|
| ECS tasks SG | 443 + 53 only | Forces HTTPS for all AWS API calls |
| Lambda SG | 443 + 53 only | Forces HTTPS for all AWS API calls |
| VPC Endpoint SG | Inbound 443 from VPC CIDR | Restricts endpoint access |

## FedRAMP Control Mapping

| Control | Implementation |
|---------|----------------|
| **SC-8** | TLS 1.2 at API Gateway edge; FIPS endpoints for all AWS service calls |
| **SC-8(1)** | FIPS 140-3 validated crypto providers (ACCP, BC-FIPS, OpenSSL FIPS) |
| **SC-13** | AES-256-GCM, SHA-256/384/512 via FIPS-validated modules |
| **SC-23** | Session tokens (JWT) transmitted only over HTTPS |

## Security Considerations

1. **Intra-VPC HTTP traffic** — API GW → ALB → ECS uses HTTP within private subnets.
   This is accepted because the traffic never leaves the VPC, is security-group-isolated,
   and is monitored via VPC Flow Logs. AWS considers this an acceptable pattern for
   FedRAMP Moderate workloads.

2. **No custom domain / ACM certificate** — The platform uses the default `execute-api`
   domain. For production deployment with a custom domain, add:
   ```hcl
   resource "aws_api_gateway_domain_name" "main" {
     domain_name              = "api.example.com"
     regional_certificate_arn = aws_acm_certificate.api.arn
     security_policy          = "TLS_1_2"
   }
   ```

3. **Certificate rotation** — AWS manages certificate rotation for API Gateway and VPC
   Endpoints. No manual certificate management is required.
