# FSAMP E2E Tests

Enterprise-grade end-to-end tests for the complete FSAMP system with **full security enforcement**.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          E2E Test Architecture                               │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌─────────────┐     JWT Token      ┌─────────────┐                         │
│  │  E2E Tests  │◄──────────────────►│   Cognito   │                         │
│  │  (Python)   │                    │ (LocalStack)│                         │
│  └──────┬──────┘                    └─────────────┘                         │
│         │                                                                    │
│         │ Bearer Token                                                       │
│         ▼                                                                    │
│  ┌─────────────┐     S3 Upload      ┌─────────────┐                         │
│  │   Gateway   │───────────────────►│     S3      │                         │
│  │   (Java)    │                    │   Bucket    │                         │
│  └──────┬──────┘                    └─────────────┘                         │
│         │                                                                    │
│         │ SNS Publish                                                        │
│         ▼                                                                    │
│  ┌─────────────┐     Subscribe      ┌─────────────┐                         │
│  │     SNS     │───────────────────►│     SQS     │                         │
│  │    Topic    │                    │    Queue    │                         │
│  └─────────────┘                    └──────┬──────┘                         │
│                                            │                                 │
│                                            │ Poll                            │
│                                            ▼                                 │
│                                     ┌─────────────┐     Store       ┌──────┐│
│                                     │  Processor  │────────────────►│DynamoDB│
│                                     │  (Python)   │                 │      ││
│                                     └─────────────┘                 └──────┘│
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

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
   ```
   E2E Test → Cognito admin_initiate_auth → JWT Token → Gateway (validates JWT)
   ```

## Quick Start

```bash
# 1. Set LocalStack Pro token
export LOCALSTACK_AUTH_TOKEN="your-token"

# 2. Start infrastructure
docker-compose up -d localstack
# Wait for init-aws.sh to complete

# 3. Start services
docker-compose up -d gateway processor

# 4. Run tests
docker-compose --profile test up e2e-tests

# Or run tests locally
pip install boto3 requests tenacity
python run-e2e-tests.py --verbose

# 5. Cleanup
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
| `full_processing_flow` | Complete upload → store → process | Yes |

## Configuration

| Environment Variable | Default | Description |
|---------------------|---------|-------------|
| `LOCALSTACK_AUTH_TOKEN` | required | LocalStack Pro license |
| `GATEWAY_URL` | `http://localhost:8080` | Gateway endpoint |
| `AWS_ENDPOINT_URL` | `http://localhost:4566` | LocalStack endpoint |
| `AWS_REGION` | `us-west-2` | AWS region |
| `COGNITO_USER_POOL_ID` | `us-west-2_fsamp-local` | Cognito User Pool |
| `COGNITO_CLIENT_ID` | `fsamp-local-client` | Cognito App Client |

## LocalStack Resources

Created by `../localstack/init-aws.sh`:

- **Cognito**: User Pool + App Client + Groups + Test Users
- **S3**: `fsamp-local-files` bucket (encrypted, versioned)
- **SNS**: `fsamp-local-file-events` topic
- **SQS**: `fsamp-local-processing-queue` + DLQ
- **DynamoDB**: `fsamp-local-file-metadata` table
- **KMS**: `alias/fsamp-local-master-key`

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
```

## Security Notes

- E2E tests use **real JWT tokens** from LocalStack Cognito
- No `@Profile("test")` security bypass - same security as production
- Token validation includes issuer, audience, expiration checks
- Groups (USERS/ADMINS) properly mapped to Spring Security authorities
