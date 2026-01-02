#!/bin/bash
# =============================================================================
# Gateway Entrypoint - Discovers Cognito IDs from LocalStack
# =============================================================================

set -e

AWS_ENDPOINT="${AWS_ENDPOINT_URL:-http://localstack:4566}"
AWS_REGION="${AWS_REGION:-us-west-2}"

export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"

echo "🔍 Discovering Cognito configuration from LocalStack..."

# Wait for LocalStack Cognito to be ready
for i in {1..30}; do
    USER_POOL_ID=$(aws cognito-idp list-user-pools \
        --endpoint-url "$AWS_ENDPOINT" \
        --region "$AWS_REGION" \
        --max-results 1 \
        --query 'UserPools[0].Id' \
        --output text 2>/dev/null || echo "")
    
    if [ -n "$USER_POOL_ID" ] && [ "$USER_POOL_ID" != "None" ]; then
        break
    fi
    echo "  Waiting for Cognito... ($i/30)"
    sleep 2
done

if [ -z "$USER_POOL_ID" ] || [ "$USER_POOL_ID" == "None" ]; then
    echo "❌ Failed to discover Cognito User Pool"
    exit 1
fi

# Get Client ID
CLIENT_ID=$(aws cognito-idp list-user-pool-clients \
    --endpoint-url "$AWS_ENDPOINT" \
    --region "$AWS_REGION" \
    --user-pool-id "$USER_POOL_ID" \
    --max-results 1 \
    --query 'UserPoolClients[0].ClientId' \
    --output text 2>/dev/null || echo "")

if [ -z "$CLIENT_ID" ] || [ "$CLIENT_ID" == "None" ]; then
    echo "❌ Failed to discover Cognito Client ID"
    exit 1
fi

echo "✓ Cognito User Pool ID: $USER_POOL_ID"
echo "✓ Cognito Client ID: $CLIENT_ID"

# Export for Spring Boot
export COGNITO_USER_POOL_ID="$USER_POOL_ID"
export COGNITO_CLIENT_ID="$CLIENT_ID"
export COGNITO_JWKS_ENDPOINT="http://localstack:4566/$USER_POOL_ID/.well-known/jwks.json"
export COGNITO_ISSUER_URI="http://localstack:4566/$USER_POOL_ID"

echo "🚀 Starting Gateway..."
exec java -jar /app/app.jar "$@"
