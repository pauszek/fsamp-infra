#!/bin/bash
# Test script for LocalStack deployment

set -euo pipefail

AWS_ENDPOINT="http://localhost:4566"
AWS_REGION="eu-central-1"

echo "🧪 Testing LocalStack deployment..."

# Helper function
awslocal() {
    aws --endpoint-url="$AWS_ENDPOINT" --region="$AWS_REGION" "$@"
}

echo ""
echo "📦 S3 Buckets:"
awslocal s3 ls

echo ""
echo "📊 DynamoDB Tables:"
awslocal dynamodb list-tables --output table

echo ""
echo "📨 SQS Queues:"
awslocal sqs list-queues --output table

echo ""
echo "📢 SNS Topics:"
awslocal sns list-topics --output table

echo ""
echo "🔐 KMS Keys:"
awslocal kms list-aliases --output table

echo ""
echo "✅ All resources verified!"
