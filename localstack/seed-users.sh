#!/bin/bash
set -euo pipefail

# Seeds e2e test users into the Terraform-managed Cognito user pool
# (LocalStack Pro, FSAMP_TF_MANAGED=1 flow). Groups are created by the
# auth module; group names are discovered case-insensitively so the script
# works with both the Terraform pool (users/admins) and the legacy
# init-aws.sh pool (USERS/ADMINS).
#
# Usage: ./localstack/seed-users.sh  (or: make seed-local)

ENDPOINT="${AWS_ENDPOINT_URL:-http://localhost:4566}"
REGION="${AWS_DEFAULT_REGION:-us-west-2}"

export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
export AWS_DEFAULT_REGION="$REGION"

aws_local() {
    aws --endpoint-url "$ENDPOINT" --region "$REGION" "$@"
}

USER_POOL_ID=$(aws_local cognito-idp list-user-pools --max-results 20 \
    --query "UserPools[?contains(Name, 'fsamp')].Id | [0]" --output text)

if [ -z "$USER_POOL_ID" ] || [ "$USER_POOL_ID" = "None" ]; then
    echo "ERROR: no FSAMP Cognito user pool found at $ENDPOINT (run terraform apply-local first)" >&2
    exit 1
fi
echo "Seeding users into pool: $USER_POOL_ID"

find_group() {
    aws_local cognito-idp list-groups --user-pool-id "$USER_POOL_ID" \
        --query "Groups[].GroupName" --output text | tr '\t' '\n' | grep -i "$1" | head -1 || true
}

USERS_GROUP=$(find_group "user")
ADMINS_GROUP=$(find_group "admin")

create_user() {
    local username="$1" email="$2" password="$3" group="$4"

    aws_local cognito-idp admin-create-user \
        --user-pool-id "$USER_POOL_ID" \
        --username "$username" \
        --temporary-password "TempPass123!" \
        --user-attributes Name=email,Value="$email" Name=email_verified,Value=true \
        --message-action SUPPRESS >/dev/null 2>&1 || true

    aws_local cognito-idp admin-set-user-password \
        --user-pool-id "$USER_POOL_ID" \
        --username "$username" \
        --password "$password" \
        --permanent

    if [ -n "$group" ] && [ "$group" != "None" ]; then
        aws_local cognito-idp admin-add-user-to-group \
            --user-pool-id "$USER_POOL_ID" \
            --username "$username" \
            --group-name "$group"
    fi

    echo "  OK $username (group: ${group:-none})"
}

# The Terraform pool uses username_attributes = ["email"], so the email is
# the sign-in identifier (the legacy init-aws.sh pool uses plain usernames).
create_user "e2e@test.local" "e2e@test.local" "E2eTestPass123!" "$USERS_GROUP"
create_user "admin@test.local" "admin@test.local" "E2eAdminPass123!" "$ADMINS_GROUP"

echo "Seed complete."
