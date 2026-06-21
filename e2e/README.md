# FSAMP E2E Tests

Enterprise-grade end-to-end tests for the complete FSAMP system with **full security enforcement**.

## Architecture

```text
E2E tests
  -> Cognito admin auth
  -> Gateway upload with Bearer token, X-Correlation-ID, X-Request-ID,
     X-Idempotency-Key
  -> S3 PutObject with SSE-KMS
  -> DynamoDB metadata + idempotency + FILE_UPLOADED outbox record
  -> Outbox publish bridge
       quick compose: gateway direct-publish-after-outbox fallback
       parity/AWS:    DynamoDB Streams -> outbox-publisher Lambda
  -> SNS topic -> SQS processing queue -> Processor
       quick compose: long-running processor container
       parity/AWS:    processor Lambda event-source mapping
  -> DynamoDB processing metadata + result outbox record
  -> SQS DLQ, LocalStack health, CloudWatch Logs and container logs as evidence
```

## Fidelity Modes

The default compose stack is an API-level end-to-end trace. It is useful for fast demos because it exercises Cognito, S3, KMS, DynamoDB, SNS, SQS, DLQ and the real application containers without requiring local ECR image publishing.

It is not a strict runtime clone of AWS because two pieces are shortened:

| Step | Quick compose | AWS / LocalStack Pro parity |
|------|---------------|-----------------------------|
| Outbox publish | Gateway writes the outbox record, then may publish directly to SNS with `DIRECT_PUBLISH_AFTER_OUTBOX=true` | DynamoDB Streams invokes `outbox-publisher` Lambda, which publishes to SNS and updates the outbox status |
| Processing | `processor` runs as a Docker long-polling consumer | SQS event-source mapping invokes `processor` Lambda |
| Gateway edge | Compose exposes gateway on `localhost:8080` | API Gateway/VPC Link/ALB/ECS is created by Terraform when the local edge stack is enabled |

For stricter LocalStack Pro parity, use the Terraform-managed local environment.
It builds and pushes gateway/processor images to LocalStack ECR, enables
ECS/API Gateway and creates both Lambda event-source mappings:

```bash
cd ../fsamp-infra
make local-parity
```

This mirrors the AWS eventing contract: `DynamoDB Streams -> outbox-publisher Lambda -> SNS -> SQS -> processor Lambda`. LocalStack Pro can validate that integration behavior locally, but the final FedRAMP-aligned evidence still has to come from real `us-west-2` AWS service outputs.

## Security Model

**NO SECURITY IS BYPASSED** - E2E tests use real JWT authentication:

1. **Cognito User Pool** created in LocalStack with:
   - User groups: `USERS`, `ADMINS`
   - Resource scopes: `files.read`, `files.write`
   - Pre-created test users

2. **Test Users** (created by init-aws.sh):

   | User | Password | Group | Purpose |
   |------|----------|-------|---------|
   | `e2e-test-user` | `E2eTestPass123!` | USERS | Standard upload tests |
   | `e2e-admin-user` | `E2eAdminPass123!` | ADMINS | Admin operations |

3. **Authentication Flow**:

   ```text
   E2E Test -> Cognito admin_initiate_auth -> JWT Token -> Gateway (validates JWT)
   ```

## Quick Start

```bash
export LOCALSTACK_AUTH_TOKEN="your-token"
docker-compose up -d localstack
# Wait for init-aws.sh to complete
docker-compose up -d gateway processor
docker-compose --profile test up e2e-tests

# Or run tests locally
pip install boto3 requests tenacity
python run-e2e-tests.py --verbose
docker-compose down -v
```

## Test Cases

| Test | Description | Auth Required |
|------|-------------|---------------|
| `gateway_health` | Health check endpoint | No |
| `localstack_resources` | Verify S3, SQS, DynamoDB, Cognito | No |
| `api_docs` | OpenAPI/Swagger availability | No |
| `cognito_authentication` | JWT token acquisition | Yes |
| `unauthenticated_rejected` | 401 for missing auth | N/A |
| `authenticated_file_upload` | Upload with JWT | Yes |
| `full_processing_flow` | Complete upload -> store -> process | Yes |

## Configuration

| Environment Variable | Default | Description |
|---------------------|---------|-------------|
| `LOCALSTACK_AUTH_TOKEN` | required | LocalStack Pro license |
| `GATEWAY_URL` | `http://localhost:8080` | Gateway endpoint |
| `AWS_ENDPOINT_URL` | `http://localhost:4566` | LocalStack endpoint |
| `AWS_REGION` | `us-west-2` | AWS region |
| `COGNITO_USER_POOL_ID` | `us-west-2_fsamp-local` | Cognito User Pool |
| `COGNITO_CLIENT_ID` | `fsamp-local-client` | Cognito App Client |
| `DIRECT_PUBLISH_AFTER_OUTBOX` | `true` in compose, `false` in parity | Quick compose fallback that publishes to SNS after the transactional outbox write; parity disables it |
| `FSAMP_DEMO_RUNTIME` | `compose` or `terraform-local` | Demo label used by `fsamp-demo-flow` evidence |
| `ENABLE_AUDIT_SERVICES` | `0` | Enables LocalStack CloudTrail, GuardDuty and AWS Config bootstrap evidence |

## LocalStack Resources

Created by `../localstack/init-aws.sh`:

- **Cognito**: User Pool + App Client + Groups + Test Users
- **S3**: `fsamp-local-files` bucket (encrypted, versioned)
- **SNS**: `fsamp-local-file-events` topic
- **SQS**: `fsamp-local-file-processing` + DLQ
- **DynamoDB**: `fsamp-local-file-metadata`, `fsamp-local-outbox` with Streams, `fsamp-local-idempotency-keys`
- **KMS**: `alias/fsamp-local-master-key`
- **Lambda/ECR/Events**: API surface available for LocalStack Pro parity runs
- **CloudWatch/Logs**: API surface available for local observability checks
- **Optional audit**: `fsamp-local-trail`, GuardDuty detector and AWS Config recorder when `ENABLE_AUDIT_SERVICES=1`

## Demo Flow Evidence

The interactive demo console in `../fsamp-demo-flow` observes this stack and stores replayable runs under `.demo-runs`:

```bash
cd ../fsamp-demo-flow
cp .env.example .env.local
# Fill LOCALSTACK_AUTH_TOKEN
make demo
```

For each upload, the console shows:

- Cognito token path and gateway response identifiers
- `X-Correlation-ID`, `X-Request-ID` and `X-Idempotency-Key`
- S3 `HeadObject` SSE-KMS metadata and bucket encryption
- DynamoDB idempotency and outbox records
- Outbox publish bridge: DynamoDB Stream, outbox-publisher Lambda and mapping state
- File-events/processing-events topics, SQS subscription, redrive policy and DLQ depth
- Processor Lambda mapping, metadata, result outbox record and filtered CloudWatch/Docker logs
- LocalStack CloudWatch/Logs health, plus optional CloudTrail/GuardDuty/Config status

LocalStack is an API-level integration proof. For final FedRAMP-aligned evidence, repeat the same checklist in real `us-west-2` AWS using CloudWatch, CloudTrail, AWS Config, KMS, ECS/Lambda and DynamoDB outputs.

## Manual Testing

```bash
# Get JWT token
TOKEN=$(aws cognito-idp admin-initiate-auth \
  --endpoint-url http://localhost:4566 \
  --user-pool-id us-west-2_fsamp-local \
  --client-id fsamp-local-client \
  --auth-flow ADMIN_NO_SRP_AUTH \
  --auth-parameters USERNAME=e2e-test-user,PASSWORD=E2eTestPass123! \
  --query 'AuthenticationResult.AccessToken' --output text)

# Upload file with auth
curl -X POST http://localhost:8080/api/v1/files \
  -H "Authorization: Bearer $TOKEN" \
  -F "file=@test.pdf"

# Check S3
aws --endpoint-url=http://localhost:4566 s3 ls s3://fsamp-local-files/

# Check DynamoDB
aws --endpoint-url=http://localhost:4566 dynamodb scan \
  --table-name fsamp-local-file-metadata
```

## CI/CD Integration

```yaml
# GitHub Actions
e2e-tests:
  runs-on: ubuntu-latest
  steps:
    - uses: actions/checkout@v4

    - name: Start LocalStack
      uses: LocalStack/setup-localstack@main
      with:
        image-tag: 'latest'
        use-pro: 'true'
      env:
        LOCALSTACK_AUTH_TOKEN: ${{ secrets.LOCALSTACK_AUTH_TOKEN }}

    - name: Run E2E Tests
      run: |
        cd fsamp-infra/e2e
        ./run-e2e.sh --ci
```

## Troubleshooting

```bash
# Check LocalStack logs
docker-compose logs localstack | grep -E "ERROR|Cognito|init-aws"

# Check Cognito User Pool
aws --endpoint-url=http://localhost:4566 cognito-idp list-user-pools --max-results 10

# List users
aws --endpoint-url=http://localhost:4566 cognito-idp list-users \
  --user-pool-id us-west-2_fsamp-local

# Check JWKS endpoint
curl http://localhost:4566/us-west-2_fsamp-local/.well-known/jwks.json | jq

# Gateway logs
docker-compose logs gateway | tail -50

# Processor logs
docker-compose logs processor | tail -50

# Queue and DLQ state
aws --endpoint-url=http://localhost:4566 sqs get-queue-attributes \
  --queue-url http://localhost:4566/000000000000/fsamp-local-file-processing \
  --attribute-names All

aws --endpoint-url=http://localhost:4566 sqs get-queue-attributes \
  --queue-url http://localhost:4566/000000000000/fsamp-local-processing-dlq \
  --attribute-names All

# Outbox evidence
aws --endpoint-url=http://localhost:4566 dynamodb describe-table \
  --table-name fsamp-local-outbox

aws --endpoint-url=http://localhost:4566 dynamodb scan \
  --table-name fsamp-local-outbox
```

## Security Notes

- E2E tests use **real JWT tokens** from LocalStack Cognito
- No `@Profile("test")` security bypass - same security as production
- Token validation includes issuer, audience, expiration checks
- Groups (USERS/ADMINS) properly mapped to Spring Security authorities
