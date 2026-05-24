# ADR-003: ECS Fargate over EKS

## Status
Accepted

## Context
The FSAMP platform needs container orchestration for running microservices. Two main options in AWS:

1. **EKS (Elastic Kubernetes Service)** - Managed Kubernetes
2. **ECS Fargate** - AWS-native serverless containers

### Comparison

| Aspect | EKS | ECS Fargate |
|--------|-----|-------------|
| **Cost (minimum)** | ~$73/month (control plane) | Pay per task only |
| **Complexity** | High (K8s knowledge required) | Low (AWS-native) |
| **Scaling** | Powerful, complex | Simple, automatic |
| **Free Tier** | No | No (but cheaper) |
| **Learning curve** | Steep | Gentle |
| **Portability** | High (K8s standard) | AWS-locked |
| **Ecosystem** | Huge (Helm, operators) | AWS-native only |

### Project Requirements
- Academic project (master's thesis) with limited budget
- AWS Free Tier optimization required
- Team expertise: AWS-focused, limited K8s experience
- Scale: 2 microservices, not hyperscale

## Decision
We will use **ECS Fargate** instead of EKS.

Rationale:
1. **Cost** - No $73/month control plane fee; pay only for tasks
2. **Simplicity** - Faster to implement and operate
3. **Free Tier friendly** - FARGATE_SPOT reduces costs further
4. **Sufficient** - Platform needs don't justify K8s complexity
5. **AWS integration** - Native ALB, CloudWatch, IAM integration

### Cost Estimate (AWS Free Tier + minimal usage)

| Service | EKS | ECS Fargate |
|---------|-----|-------------|
| Control plane | $73/month | $0 |
| 2 tasks (256 CPU, 512 MB) | ~$15/month | ~$15/month |
| NAT Gateway | $32/month | $0 (VPC Endpoints) |
| **Total** | **~$120/month** | **~$15/month** |

## Consequences

### Positive
- 8x cost reduction vs EKS
- Simpler deployment and operations
- Native AWS observability
- Auto-scaling built-in
- Thesis focus on architecture, not K8s operations

### Negative
- AWS vendor lock-in
- No K8s ecosystem (Helm charts, operators)
- Less portable to other clouds
- Limited for complex orchestration scenarios

### Mitigations
- Application code remains containerized (portable)
- Infrastructure as Code enables future migration
- Document EKS migration path in thesis as future work

## References
- [AWS ECS vs EKS Comparison](https://aws.amazon.com/blogs/containers/)
- [ECS Fargate Pricing](https://aws.amazon.com/fargate/pricing/)
- [EKS Pricing](https://aws.amazon.com/eks/pricing/)

