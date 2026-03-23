# FSAMP Platform Architecture

> **F**edRAMP-compliant **S**ecure **A**WS **M**icroservices **P**latform

A secure, enterprise-grade microservices platform for file processing on AWS using event-driven architecture and Infrastructure as Code.

## Table of Contents

- [High-Level Architecture](#high-level-architecture)
- [Component Overview](#component-overview)
- [Data Flow](#data-flow)
- [Security Architecture](#security-architecture)
- [Resilience Patterns](#resilience-patterns)
- [Infrastructure](#infrastructure)
- [Technology Stack](#technology-stack)

---

## High-Level Architecture

```
┌─────────────────────────────────────────────────────────────────────────────────────────────┐
│                                    AWS Cloud (eu-central-1)                                 │
│  ┌───────────────────────────────────────────────────────────────────────────────────────┐  │
│  │                                    VPC (10.0.0.0/16)                                   │  │
│  │  ┌─────────────────────────────────────────────────────────────────────────────────┐  │  │
│  │  │                              Public Subnets                                      │  │  │
│  │  │  ┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐              │  │  │
│  │  │  │  NAT Gateway    │    │  NAT Gateway    │    │  NAT Gateway    │              │  │  │
│  │  │  │    (AZ-a)       │    │    (AZ-b)       │    │    (AZ-c)       │              │  │  │
│  │  │  └─────────────────┘    └─────────────────┘    └─────────────────┘              │  │  │
│  │  └─────────────────────────────────────────────────────────────────────────────────┘  │  │
│  │                                                                                        │  │
│  │  ┌─────────────────────────────────────────────────────────────────────────────────┐  │  │
│  │  │                             Private Subnets                                      │  │  │
│  │  │                                                                                  │  │  │
│  │  │  ┌──────────────────────────────────────────────────────────────────────────┐   │  │  │
│  │  │  │                    ECS Fargate Cluster                                    │   │  │  │
│  │  │  │                                                                           │   │  │  │
│  │  │  │   ┌─────────────────────────────────────────────────────────────────┐    │   │  │  │
│  │  │  │   │              fsamp-gateway (Spring Boot 3.4)                    │    │   │  │  │
│  │  │  │   │   ┌─────────────┐  ┌─────────────┐  ┌──────────────────────┐   │    │   │  │  │
│  │  │  │   │   │   REST API  │  │   OAuth2    │  │   Resilience4j       │   │    │   │  │  │
│  │  │  │   │   │   /api/v1   │  │  Resource   │  │  (CB, Retry, Rate)   │   │    │   │  │  │
│  │  │  │   │   │             │  │   Server    │  │                      │   │    │   │  │  │
│  │  │  │   │   └──────┬──────┘  └──────┬──────┘  └──────────────────────┘   │    │   │  │  │
│  │  │  │   │          │                │                                     │    │   │  │  │
│  │  │  │   │          │  FIPS 140-3 Encryption (BouncyCastle)               │    │   │  │  │
│  │  │  │   └──────────┼────────────────┼─────────────────────────────────────┘    │   │  │  │
│  │  │  │              │                │                                          │   │  │  │
│  │  │  └──────────────┼────────────────┼──────────────────────────────────────────┘   │  │  │
│  │  │                 │                │                                              │  │  │
│  │  │                 ▼                ▼                                              │  │  │
│  │  │  ┌─────────────────────────────────────────────────────────────────────────┐   │  │  │
│  │  │  │                        VPC Endpoints                                     │   │  │  │
│  │  │  │  ┌──────┐ ┌──────┐ ┌──────┐ ┌──────┐ ┌──────┐ ┌──────┐ ┌───────────┐   │   │  │  │
│  │  │  │  │  S3  │ │ DDB  │ │ SNS  │ │ SQS  │ │ KMS  │ │ CW   │ │ Cognito   │   │   │  │  │
│  │  │  │  └──┬───┘ └──┬───┘ └──┬───┘ └──┬───┘ └──┬───┘ └──┬───┘ └────┬──────┘   │   │  │  │
│  │  │  └─────┼────────┼────────┼────────┼────────┼────────┼──────────┼───────────┘   │  │  │
│  │  │        │        │        │        │        │        │          │               │  │  │
│  │  └────────┼────────┼────────┼────────┼────────┼────────┼──────────┼───────────────┘  │  │
│  │           │        │        │        │        │        │          │                  │  │
│  └───────────┼────────┼────────┼────────┼────────┼────────┼──────────┼──────────────────┘  │
│              │        │        │        │        │        │          │                     │
│              ▼        ▼        │        ▼        │        │          │                     │
│  ┌────────────────────────┐   │   ┌────────────┼────────┼──────────┼──────────────────┐  │
│  │          S3            │   │   │            │        │          │                  │  │
│  │  ┌──────────────────┐  │   │   │  ┌─────────▼────────▼──────────▼───────────────┐ │  │
│  │  │ fsamp-files      │  │   │   │  │              AWS Managed Services           │ │  │
│  │  │                  │  │   │   │  │                                             │ │  │
│  │  │  ├── uploads/    │  │   │   │  │  ┌─────────────┐   ┌───────────────────┐   │ │  │
│  │  │  ├── processed/  │  │   │   │  │  │  Cognito    │   │    CloudWatch     │   │ │  │
│  │  │  └── archives/   │  │   │   │  │  │  User Pool  │   │  Dashboard/Alarms │   │ │  │
│  │  │                  │  │   │   │  │  │  + OAuth2   │   │  + X-Ray Tracing  │   │ │  │
│  │  │  KMS Encryption  │  │   │   │  │  └─────────────┘   └───────────────────┘   │ │  │
│  │  │  SSE-KMS         │  │   │   │  │                                             │ │  │
│  │  └──────────────────┘  │   │   │  │  ┌─────────────┐   ┌───────────────────┐   │ │  │
│  └────────────────────────┘   │   │  │  │    KMS      │   │      WAF          │   │ │  │
│                               │   │  │  │  CMK Keys   │   │  (API Gateway)    │   │ │  │
│  ┌────────────────────────┐   │   │  │  │  FIPS 140-3 │   │  OWASP + Rate     │   │ │  │
│  │       DynamoDB         │   │   │  │  └─────────────┘   └───────────────────┘   │ │  │
│  │  ┌──────────────────┐  │   │   │  │                                             │ │  │
│  │  │ fsamp-metadata   │  │   │   │  └─────────────────────────────────────────────┘ │  │
│  │  │ (File records)   │  │   │   │                                                  │  │
│  │  └──────────────────┘  │   │   └──────────────────────────────────────────────────┘  │
│  │  ┌──────────────────┐  │   │                                                         │
│  │  │ fsamp-outbox     │──┼───┼──────────────────┐                                     │
│  │  │ (Events)         │  │   │                  │                                     │
│  │  │ + DynamoDB Stream│  │   │                  ▼                                     │
│  │  └──────────────────┘  │   │   ┌─────────────────────────────────────────────────┐  │
│  │  ┌──────────────────┐  │   │   │                Lambda Functions                 │  │
│  │  │ fsamp-idempotency│  │   │   │                                                 │  │
│  │  │ (TTL: 24h)       │  │   │   │  ┌─────────────────┐  ┌─────────────────────┐  │  │
│  │  └──────────────────┘  │   │   │  │ outbox-publisher│  │  fsamp-processor    │  │  │
│  └────────────────────────┘   │   │  │ (Stream trigger)│  │  (SQS trigger)      │  │  │
│                               │   │  │                 │  │                     │  │  │
│                               │   │  │  Python 3.14    │  │  Python 3.14        │  │  │
│                               │   │  │  + Powertools   │  │  + Powertools       │  │  │
│                               │   │  └────────┬────────┘  └──────────┬──────────┘  │  │
│                               │   │           │                      │             │  │
│                               │   │           ▼                      │             │  │
│                               │   │   ┌───────────────┐              │             │  │
│                               │   │   │  SNS Topic    │              │             │  │
│                               └───┼──►│ file-events   │──────────────┘             │  │
│                                   │   └───────┬───────┘                            │  │
│                                   │           │                                    │  │
│                                   │           ▼                                    │  │
│                                   │   ┌───────────────┐                            │  │
│                                   │   │  SQS Queue    │                            │  │
│                                   │   │ processor-dlq │ ◄── Failed events         │  │
│                                   │   └───────────────┘                            │  │
│                                   └─────────────────────────────────────────────────┘  │
│                                                                                        │
└────────────────────────────────────────────────────────────────────────────────────────┘

External Access:
┌─────────────────────────────────────────────────────────────────────────────────────────────┐
│                                                                                             │
│   ┌──────────────┐        ┌─────────────────┐        ┌─────────────────────────────────┐   │
│   │   Client     │  HTTPS │   API Gateway   │  HTTPS │        Application              │   │
│   │  (Browser/   │───────►│  + WAF          │───────►│        Load Balancer            │   │
│   │   Mobile)    │        │  + Rate Limit   │        │        (internal)               │   │
│   └──────────────┘        └─────────────────┘        └─────────────────────────────────┘   │
│          │                         │                                                        │
│          │                         │ JWT Token Validation                                   │
│          │                         ▼                                                        │
│          │              ┌─────────────────────┐                                            │
│          └─────────────►│   AWS Cognito       │                                            │
│             OAuth2      │   (Identity)        │                                            │
│             Login       └─────────────────────┘                                            │
│                                                                                             │
└─────────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## Component Overview

### Gateway Service (fsamp-gateway)

| Aspect | Details |
|--------|---------|
| **Technology** | Spring Boot 3.4, Java 21 |
| **Deployment** | ECS Fargate (containerized) |
| **Purpose** | REST API for file upload/download |
| **Security** | OAuth2 Resource Server (Cognito JWT) |
| **Resilience** | Resilience4j (Circuit Breaker, Retry, Rate Limiter, Bulkhead) |
| **Encryption** | FIPS 140-3 compliant (BouncyCastle bc-fips) |
| **Patterns** | Hexagonal Architecture, CQRS-lite |

### Processor Service (fsamp-processor)

| Aspect | Details |
|--------|---------|
| **Technology** | Python 3.14, AWS Lambda |
| **Trigger** | SQS Queue (subscribed to SNS) |
| **Purpose** | Async file processing (validation, transformation) |
| **Observability** | AWS Lambda Powertools (structured logging, tracing, metrics) |
| **Patterns** | Event Sourcing, Idempotent Consumer |

### Outbox Publisher Lambda

| Aspect | Details |
|--------|---------|
| **Technology** | Python 3.14, AWS Lambda |
| **Trigger** | DynamoDB Streams |
| **Purpose** | Reliable event publishing (Transactional Outbox Pattern) |
| **Guarantees** | At-least-once delivery |

---

## Data Flow

### File Upload Flow

```
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                              FILE UPLOAD SEQUENCE                                       │
├─────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                         │
│  Client                Gateway                S3              DynamoDB        SNS/SQS  │
│    │                     │                    │                  │              │       │
│    │  1. POST /upload    │                    │                  │              │       │
│    │  + JWT + File       │                    │                  │              │       │
│    │────────────────────►│                    │                  │              │       │
│    │                     │                    │                  │              │       │
│    │                     │ 2. Validate JWT    │                  │              │       │
│    │                     │    (Cognito)       │                  │              │       │
│    │                     │                    │                  │              │       │
│    │                     │ 3. Validate file   │                  │              │       │
│    │                     │    (size, type)    │                  │              │       │
│    │                     │                    │                  │              │       │
│    │                     │ 4. Upload file     │                  │              │       │
│    │                     │────────────────────►                  │              │       │
│    │                     │    (KMS encrypted) │                  │              │       │
│    │                     │◄───────────────────│                  │              │       │
│    │                     │                    │                  │              │       │
│    │                     │ 5. TransactWrite   │                  │              │       │
│    │                     │    (atomic)        │                  │              │       │
│    │                     │────────────────────────────────────────►             │       │
│    │                     │    a) File metadata│                  │              │       │
│    │                     │    b) Outbox event │                  │              │       │
│    │                     │◄───────────────────────────────────────│             │       │
│    │                     │                    │                  │              │       │
│    │  6. 201 Created     │                    │                  │              │       │
│    │◄────────────────────│                    │                  │              │       │
│    │  { fileId, status } │                    │                  │              │       │
│    │                     │                    │                  │              │       │
│                                                                                         │
│  ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ASYNC (DynamoDB Stream) ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─  │
│                                                                                         │
│                                              DDB Stream    Outbox Lambda    Processor  │
│                                                  │              │              │       │
│                                                  │ 7. New event │              │       │
│                                                  │─────────────►│              │       │
│                                                  │              │              │       │
│                                                  │              │ 8. Publish   │       │
│                                                  │              │─────────────────────► │
│                                                  │              │    SNS→SQS   │       │
│                                                  │              │              │       │
│                                                  │              │              │ 9. Process │
│                                                  │              │              │   file    │
│                                                  │              │              │       │
│                                                  │              │              │ 10. Update│
│                                                  │              │              │   status  │
│                                                                                         │
└─────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## Security Architecture

```
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                              SECURITY LAYERS                                            │
├─────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                         │
│  Layer 1: Edge Security                                                                 │
│  ┌─────────────────────────────────────────────────────────────────────────────────┐   │
│  │  • AWS WAF (Web Application Firewall)                                           │   │
│  │    - OWASP Top 10 protection (SQLi, XSS)                                        │   │
│  │    - Rate limiting (2000 req/5min per IP)                                       │   │
│  │    - Bot control                                                                │   │
│  │  • AWS Shield (DDoS protection)                                                 │   │
│  │  • TLS 1.3 termination                                                          │   │
│  └─────────────────────────────────────────────────────────────────────────────────┘   │
│                                                                                         │
│  Layer 2: Authentication & Authorization                                                │
│  ┌─────────────────────────────────────────────────────────────────────────────────┐   │
│  │  • AWS Cognito User Pool                                                        │   │
│  │    - OAuth 2.0 / OpenID Connect                                                 │   │
│  │    - JWT tokens (RS256)                                                         │   │
│  │    - MFA support                                                                │   │
│  │  • Spring Security OAuth2 Resource Server                                       │   │
│  │    - JWT validation                                                             │   │
│  │    - Scope-based access control (files.read, files.write)                       │   │
│  │    - Role-based access (USERS, ADMINS)                                          │   │
│  └─────────────────────────────────────────────────────────────────────────────────┘   │
│                                                                                         │
│  Layer 3: Application Security                                                          │
│  ┌─────────────────────────────────────────────────────────────────────────────────┐   │
│  │  • Resilience4j Rate Limiter (per-user)                                         │   │
│  │  • Idempotency Key pattern (safe retries)                                       │   │
│  │  • Input validation (file type, size)                                           │   │
│  │  • Security headers (HSTS, CSP, X-XSS-Protection)                               │   │
│  │  • Structured logging (no sensitive data)                                       │   │
│  └─────────────────────────────────────────────────────────────────────────────────┘   │
│                                                                                         │
│  Layer 4: Data Security                                                                 │
│  ┌─────────────────────────────────────────────────────────────────────────────────┐   │
│  │  • FIPS 140-3 Encryption                                                        │   │
│  │    - AWS KMS (Customer Managed Keys)                                            │   │
│  │    - BouncyCastle FIPS Provider (Java)                                          │   │
│  │  • Encryption at Rest                                                           │   │
│  │    - S3: SSE-KMS                                                                │   │
│  │    - DynamoDB: AWS managed encryption                                           │   │
│  │  • Encryption in Transit                                                        │   │
│  │    - TLS 1.3 everywhere                                                         │   │
│  │    - VPC Endpoints (no public internet)                                         │   │
│  └─────────────────────────────────────────────────────────────────────────────────┘   │
│                                                                                         │
│  Layer 5: Network Security                                                              │
│  ┌─────────────────────────────────────────────────────────────────────────────────┐   │
│  │  • VPC isolation                                                                │   │
│  │  • Private subnets for compute                                                  │   │
│  │  • VPC Endpoints for AWS services (no NAT Gateway for AWS traffic)              │   │
│  │  • Security Groups (least privilege)                                            │   │
│  │  • Network ACLs                                                                 │   │
│  └─────────────────────────────────────────────────────────────────────────────────┘   │
│                                                                                         │
└─────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## Resilience Patterns

```
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                           RESILIENCE PATTERNS (Gateway)                                 │
├─────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                         │
│  ┌───────────────────────────────────────────────────────────────────────────────────┐ │
│  │                              REQUEST FLOW                                          │ │
│  │                                                                                    │ │
│  │    Request                                                                         │ │
│  │       │                                                                            │ │
│  │       ▼                                                                            │ │
│  │  ┌─────────────┐   ┌─────────────┐   ┌─────────────┐   ┌─────────────┐            │ │
│  │  │ Rate        │   │ Bulkhead    │   │ Circuit     │   │ Retry       │            │ │
│  │  │ Limiter     │──►│             │──►│ Breaker     │──►│             │──► Service │ │
│  │  │             │   │ (25 conc.)  │   │             │   │ (3 attempts)│            │ │
│  │  │ 10 req/s    │   │             │   │ 50% fail    │   │             │            │ │
│  │  │ (upload)    │   │             │   │ threshold   │   │ exp backoff │            │ │
│  │  └─────────────┘   └─────────────┘   └─────────────┘   └─────────────┘            │ │
│  │       │                   │                 │                 │                    │ │
│  │       ▼                   ▼                 ▼                 ▼                    │ │
│  │    429 Too            503 Service       503 Service       (transparent            │ │
│  │    Many Requests      Unavailable       Unavailable        to caller)             │ │
│  │    Retry-After: 1s    Retry-After: 5s   Retry-After: 30s                          │ │
│  │                                                                                    │ │
│  └───────────────────────────────────────────────────────────────────────────────────┘ │
│                                                                                         │
│  Pattern Configuration:                                                                 │
│  ┌───────────────────┬────────────────────────────────────────────────────────────┐    │
│  │ Pattern           │ Configuration                                              │    │
│  ├───────────────────┼────────────────────────────────────────────────────────────┤    │
│  │ Rate Limiter      │ upload: 10 req/s, download: 50 req/s                       │    │
│  │ Bulkhead          │ upload: 25 concurrent calls                                │    │
│  │ Circuit Breaker   │ 50% failure threshold, 30s wait, 10 call window            │    │
│  │ Retry             │ 3 attempts, exponential backoff (1s, 2s, 4s)               │    │
│  │ Time Limiter      │ S3: 30s, SNS: 10s                                          │    │
│  └───────────────────┴────────────────────────────────────────────────────────────┘    │
│                                                                                         │
└─────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## Infrastructure

### Terraform Modules

```
terraform/modules/
├── api-gateway/     # AWS API Gateway + WAF
├── auth/            # Cognito User Pool + App Client
├── compute/         # ECS Fargate + Lambda (incl. Outbox Publisher)
├── ecr/             # Container Registry
├── messaging/       # SNS Topics + SQS Queues
├── networking/      # VPC + Subnets + VPC Endpoints
├── observability/   # CloudWatch Dashboard + Alarms + X-Ray
├── security/        # KMS Keys + IAM Roles
└── storage/         # S3 Buckets + DynamoDB Tables (incl. Outbox, Idempotency)
```

### CloudWatch Dashboard

```
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                              FSAMP DASHBOARD                                            │
├─────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                         │
│  Gateway Health          │  Processor Health        │  Storage Health                  │
│  ┌───────────────────┐   │  ┌───────────────────┐   │  ┌───────────────────┐          │
│  │ ECS CPU: 45%      │   │  │ Invocations: 1.2k │   │  │ S3 Requests: 3.4k │          │
│  │ ECS Memory: 62%   │   │  │ Errors: 0.1%      │   │  │ DDB Read: 5.2k    │          │
│  │ ALB 5xx: 0.05%    │   │  │ Duration: 234ms   │   │  │ DDB Write: 1.1k   │          │
│  └───────────────────┘   │  └───────────────────┘   │  └───────────────────┘          │
│                          │                          │                                  │
│  Resilience Metrics      │  Event Pipeline          │  Security                        │
│  ┌───────────────────┐   │  ┌───────────────────┐   │  ┌───────────────────┐          │
│  │ CB Open: 0        │   │  │ Outbox Pending: 5 │   │  │ KMS Requests: 8.1k│          │
│  │ Rate Limited: 12  │   │  │ SNS Published: 1k │   │  │ WAF Blocked: 45   │          │
│  │ Retries: 34       │   │  │ SQS Processed: 1k │   │  │ Auth Failures: 3  │          │
│  └───────────────────┘   │  └───────────────────┘   │  └───────────────────┘          │
│                                                                                         │
└─────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## Technology Stack

| Layer | Technology | Version |
|-------|------------|---------|
| **Cloud** | AWS | - |
| **IaC** | Terraform | ~5.40 |
| **Container** | ECS Fargate | - |
| **Serverless** | AWS Lambda | Python 3.14 |
| **API Framework** | Spring Boot | 3.4.11 |
| **Language** | Java | 21 (LTS) |
| **Language** | Python | 3.14 |
| **Security** | BouncyCastle FIPS | 2.0.0 |
| **Resilience** | Resilience4j | 2.2.0 |
| **Auth** | AWS Cognito + OAuth2 | - |
| **Database** | DynamoDB | - |
| **Storage** | S3 | - |
| **Messaging** | SNS/SQS | - |
| **Encryption** | AWS KMS | FIPS 140-3 |
| **Observability** | CloudWatch + X-Ray | - |
| **Local Dev** | LocalStack | Latest |

---

## Architecture Decision Records

| ADR | Title | Status |
|-----|-------|--------|
| [001](docs/adr/001-use-localstack-for-local-development.md) | LocalStack for Local Development | Accepted |
| [002](docs/adr/002-event-driven-architecture.md) | Event-Driven Architecture | Accepted |
| [003](docs/adr/003-ecs-fargate-over-eks.md) | ECS Fargate over EKS | Accepted |
| [004](docs/adr/004-fips-140-3-encryption.md) | FIPS 140-3 Encryption | Accepted |
| [005](docs/adr/005-vpc-endpoints-over-nat.md) | VPC Endpoints over NAT Gateway | Accepted |
| [006](docs/adr/006-multi-repository-architecture.md) | Multi-Repository Architecture | Accepted |
| [007](docs/adr/007-transactional-outbox-pattern.md) | Transactional Outbox Pattern | Accepted |

---

## Repository Structure

```
github.com/fsamp/
├── fsamp-infra/        # This repository - Infrastructure
│   ├── terraform/      # AWS resources
│   ├── docs/adr/       # Architecture decisions
│   └── e2e/            # Infrastructure tests
│
├── fsamp-gateway/      # Spring Boot API service
│   ├── src/            # Java source code
│   └── Dockerfile      # Container build
│
├── fsamp-processor/    # Python Lambda service
│   ├── src/            # Python source code
│   └── template.yaml   # SAM template (optional)
│
└── fsamp-event-schema/ # Shared event schemas
    └── schemas/        # JSON Schema definitions
```

---

## Quick Start

```bash
# Start LocalStack
cd fsamp-infra
make up

# Deploy infrastructure
make deploy-local

# Start Gateway
cd ../fsamp-gateway
./mvnw spring-boot:run -Dspring-boot.run.profiles=local

# Test upload
curl -X POST http://localhost:8080/api/v1/files/upload \
  -H "Authorization: Bearer <token>" \
  -H "X-Idempotency-Key: $(uuidgen)" \
  -F "file=@test.pdf"
```

---

## License

MIT License - See [LICENSE](LICENSE) for details.
