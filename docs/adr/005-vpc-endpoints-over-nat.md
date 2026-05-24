# ADR-005: VPC Endpoints over NAT Gateway

## Status
Accepted

## Context
ECS tasks and Lambda functions in private subnets need to access AWS services (S3, SQS, SNS, ECR, etc.).
Two options exist:

1. **NAT Gateway**: Route traffic through NAT to public internet, then to AWS services
2. **VPC Endpoints**: Private connections directly to AWS services within VPC

### Cost Comparison (eu-central-1)

| Component | NAT Gateway | VPC Endpoints |
|-----------|-------------|---------------|
| Fixed cost | $32.40/month | $0 (Gateway), ~$7.30/month (Interface) |
| Data processing | $0.045/GB | $0.01/GB |
| **Monthly estimate** | **~$35-50** | **~$7-10** |

### Service Requirements

| Service | Endpoint Type | Cost |
|---------|---------------|------|
| S3 | Gateway | **Free** |
| DynamoDB | Gateway | **Free** |
| ECR (api) | Interface | ~$7.30/month |
| ECR (dkr) | Interface | ~$7.30/month |
| CloudWatch Logs | Interface | ~$7.30/month |
| SQS | Interface | ~$7.30/month |
| SNS | Interface | ~$7.30/month |
| KMS | Interface | ~$7.30/month |

## Decision
We will use **VPC Endpoints** instead of NAT Gateway.

### Implementation

```hcl
# Gateway Endpoints (FREE)
resource "aws_vpc_endpoint" "s3" {
  vpc_id       = aws_vpc.main.id
  service_name = "com.amazonaws.${region}.s3"
  # Attached to route tables - no hourly cost
}

resource "aws_vpc_endpoint" "dynamodb" {
  vpc_id       = aws_vpc.main.id
  service_name = "com.amazonaws.${region}.dynamodb"
}

# Interface Endpoints (only when NAT disabled)
resource "aws_vpc_endpoint" "ecr_api" {
  count = var.enable_nat_gateway ? 0 : 1  # Conditional creation
  
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${region}.ecr.api"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
}
```

### Conditional Logic

```
IF enable_nat_gateway = true:
  - NAT Gateway created
  - Interface endpoints NOT created (use NAT for AWS API calls)
  
IF enable_nat_gateway = false:
  - NAT Gateway NOT created
  - Interface endpoints created for ECR, Logs, SQS, SNS, KMS
  - Gateway endpoints always created (S3, DynamoDB)
```

## Consequences

### Positive
- **Cost savings**: ~$25-30/month saved vs NAT Gateway
- **Security**: Traffic stays within AWS network
- **Performance**: Lower latency (no internet hop)
- **Simplicity**: No NAT HA concerns

### Negative
- **More resources**: 6+ endpoints vs 1 NAT Gateway
- **DNS complexity**: Private DNS must be enabled
- **Internet access**: No general internet access from private subnets

### When to use NAT Gateway instead

Use NAT Gateway (`enable_nat_gateway = true`) when:
- Tasks need to access external APIs (not AWS)
- Pulling images from Docker Hub (not ECR)
- Accessing external webhooks

For FSAMP: All dependencies are AWS services, so VPC Endpoints are sufficient.

## Configuration

```hcl
# terraform/environments/dev/main.tf
module "fsamp" {
  # ...
  enable_nat_gateway = false  # Use VPC Endpoints (cost optimized)
}

# terraform/environments/prod/main.tf
module "fsamp" {
  # ...
  enable_nat_gateway = true   # Or false if no external dependencies
}
```

## References
- [VPC Endpoints Pricing](https://aws.amazon.com/privatelink/pricing/)
- [NAT Gateway Pricing](https://aws.amazon.com/vpc/pricing/)
- [VPC Endpoints vs NAT Gateway](https://docs.aws.amazon.com/vpc/latest/privatelink/vpc-endpoints.html)

