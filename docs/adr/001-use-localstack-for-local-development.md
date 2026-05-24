# ADR-001: Use LocalStack for Local Development

## Status
Accepted

## Context
The FSAMP platform requires extensive integration with AWS services (S3, SQS, SNS, DynamoDB, KMS, etc.). 
Developers need a way to:
- Test infrastructure changes without incurring AWS costs
- Work offline without AWS access
- Have fast feedback loops during development
- Ensure parity between local and cloud environments

Options considered:
1. **LocalStack Pro** - Full AWS emulation with enterprise features
2. **AWS SAM Local** - Limited to Lambda and API Gateway
3. **Moto (Python)** - In-memory mocks, no real service emulation
4. **Direct AWS Development** - Real AWS resources for dev

## Decision
We will use **LocalStack Pro** for local development and testing.

Key reasons:
- **Full AWS API compatibility** - Supports all required services (S3, SQS, SNS, DynamoDB, KMS, Lambda, ECS, Cognito)
- **IAM enforcement** - Can test IAM policies locally (ENFORCE_IAM=1)
- **Cloud Pods** - Save/restore infrastructure state snapshots
- **Terraform support** - Same Terraform code works locally and in AWS
- **Docker-based** - Consistent across all developer machines
- **Cost savings** - No AWS charges during development

## Consequences

### Positive
- Zero AWS costs during development
- Fast iteration (seconds vs minutes for provisioning)
- Reproducible environments via Cloud Pods
- CI/CD can test infrastructure without AWS credentials
- Developers can work offline

### Negative
- LocalStack Pro requires license for full features
- Some edge cases may behave differently than real AWS
- ECS/Lambda execution requires Docker-in-Docker setup
- Initial learning curve for team

### Mitigations
- Maintain integration tests that run against real AWS periodically
- Document LocalStack limitations in wiki
- Use Cloud Pods to share consistent base states

## References
- [LocalStack Pro Documentation](https://docs.localstack.cloud/overview/)
- [LocalStack AWS Coverage](https://docs.localstack.cloud/user-guide/aws/feature-coverage/)
- [Terraform LocalStack Provider](https://registry.terraform.io/providers/hashicorp/aws/latest/docs)

