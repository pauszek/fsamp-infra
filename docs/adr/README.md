# Architecture Decision Records

This directory contains Architecture Decision Records (ADRs) for the FSAMP Infrastructure project.

## What is an ADR?

An ADR is a document that captures an important architectural decision made along with its context and consequences.

## ADR Index

| ID | Title | Status | Date |
|----|-------|--------|------|
| [001](001-use-localstack-for-local-development.md) | Use LocalStack for Local Development | Accepted | 2024-12 |
| [002](002-event-driven-architecture.md) | Event-Driven Architecture with SNS/SQS | Accepted | 2024-12 |
| [003](003-ecs-fargate-over-eks.md) | ECS Fargate over EKS | Accepted | 2024-12 |
| [004](004-fips-140-3-encryption.md) | FIPS 140-3 Encryption Strategy | Accepted | 2024-12 |
| [005](005-vpc-endpoints-over-nat.md) | VPC Endpoints over NAT Gateway | Accepted | 2024-12 |
| [006](006-multi-repository-architecture.md) | Multi-Repository Architecture | Accepted | 2024-12 |

## Template

Use the following template for new ADRs:

```markdown
# ADR-XXX: Title

## Status
Proposed | Accepted | Deprecated | Superseded

## Context
What is the issue that we're seeing that is motivating this decision or change?

## Decision
What is the change that we're proposing and/or doing?

## Consequences
What becomes easier or more difficult to do because of this change?

## References
- Links to relevant documentation, issues, etc.
```

