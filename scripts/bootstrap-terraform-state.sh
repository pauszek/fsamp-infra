#!/bin/bash
# =============================================================================
# Bootstrap script for Terraform remote state
# =============================================================================
# Run this ONCE before using dev/prod environments
# Creates S3 bucket and DynamoDB table for Terraform state locking
# =============================================================================

set -euo pipefail

# Configuration
AWS_REGION="${AWS_REGION:-eu-central-1}"
PROJECT_NAME="fsamp"
BUCKET_NAME="${PROJECT_NAME}-terraform-state"
DYNAMODB_TABLE="${PROJECT_NAME}-terraform-locks"

echo "============================================"
echo "  FSAMP Terraform State Bootstrap"
echo "============================================"
echo "Region: $AWS_REGION"
echo "Bucket: $BUCKET_NAME"
echo "Table:  $DYNAMODB_TABLE"
echo "============================================"

# Check if bucket exists
if aws s3api head-bucket --bucket "$BUCKET_NAME" 2>/dev/null; then
    echo "✅ S3 bucket already exists: $BUCKET_NAME"
else
    echo "📦 Creating S3 bucket: $BUCKET_NAME"

    # Create bucket (different command for us-east-1)
    if [ "$AWS_REGION" = "us-east-1" ]; then
        aws s3api create-bucket \
            --bucket "$BUCKET_NAME" \
            --region "$AWS_REGION"
    else
        aws s3api create-bucket \
            --bucket "$BUCKET_NAME" \
            --region "$AWS_REGION" \
            --create-bucket-configuration LocationConstraint="$AWS_REGION"
    fi

    # Enable versioning
    echo "📝 Enabling versioning..."
    aws s3api put-bucket-versioning \
        --bucket "$BUCKET_NAME" \
        --versioning-configuration Status=Enabled

    # Enable encryption
    echo "🔐 Enabling server-side encryption..."
    aws s3api put-bucket-encryption \
        --bucket "$BUCKET_NAME" \
        --server-side-encryption-configuration '{
            "Rules": [{
                "ApplyServerSideEncryptionByDefault": {
                    "SSEAlgorithm": "aws:kms"
                },
                "BucketKeyEnabled": true
            }]
        }'

    # Block public access
    echo "🚫 Blocking public access..."
    aws s3api put-public-access-block \
        --bucket "$BUCKET_NAME" \
        --public-access-block-configuration '{
            "BlockPublicAcls": true,
            "IgnorePublicAcls": true,
            "BlockPublicPolicy": true,
            "RestrictPublicBuckets": true
        }'

    echo "✅ S3 bucket created: $BUCKET_NAME"
fi

# Check if DynamoDB table exists
if aws dynamodb describe-table --table-name "$DYNAMODB_TABLE" --region "$AWS_REGION" 2>/dev/null; then
    echo "✅ DynamoDB table already exists: $DYNAMODB_TABLE"
else
    echo "📋 Creating DynamoDB table: $DYNAMODB_TABLE"

    aws dynamodb create-table \
        --table-name "$DYNAMODB_TABLE" \
        --attribute-definitions AttributeName=LockID,AttributeType=S \
        --key-schema AttributeName=LockID,KeyType=HASH \
        --billing-mode PAY_PER_REQUEST \
        --region "$AWS_REGION" \
        --tags Key=Project,Value="$PROJECT_NAME" Key=ManagedBy,Value=terraform

    echo "⏳ Waiting for table to be active..."
    aws dynamodb wait table-exists --table-name "$DYNAMODB_TABLE" --region "$AWS_REGION"

    echo "✅ DynamoDB table created: $DYNAMODB_TABLE"
fi

echo ""
echo "============================================"
echo "  ✅ Bootstrap complete!"
echo "============================================"
echo ""
echo "Next steps:"
echo "1. Uncomment the backend configuration in:"
echo "   - terraform/environments/dev/main.tf"
echo "   - terraform/environments/prod/main.tf"
echo ""
echo "2. Initialize Terraform:"
echo "   cd terraform/environments/dev"
echo "   terraform init"
echo ""
echo "3. Plan and apply:"
echo "   terraform plan"
echo "   terraform apply"
echo ""

