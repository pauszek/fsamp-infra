# Deployment

The AWS deployment path is GitHub Actions first. A local bootstrap is required only once, because an empty AWS account cannot be assumed by GitHub OIDC until the IAM provider and role exist.

Active AWS deployments are pinned to `us-west-2`. LocalStack remains the local
development target; other AWS regions are rejected by Terraform and deploy
workflow guards.

## First-Time Bootstrap

Run from `fsamp-infra` with AWS CLI credentials that can create IAM resources:

```bash
GITHUB_OWNER=pauszek GITHUB_REPO=fsamp-infra ./scripts/bootstrap-github-oidc.sh
```

Set the printed `AWS_DEPLOY_ROLE_ARN` as a GitHub repository or organization variable named `AWS_DEPLOY_ROLE_ARN`.

The deploy workflow also needs:

| Name | Type | Purpose |
|---|---|---|
| `GABRBA_APPID` | GitHub variable | GitHub App ID for cross-repo checkout |
| `GABRBA_SECRET` | GitHub secret | GitHub App private key |
| `.github/params.yml` | Repository config | Set `deploy.auto-dev=true` after AWS and GitHub App setup |

## Deploy Flow

Deployment-related merges to `main` in this repository deploy `dev` automatically only when `.github/params.yml` has `deploy.auto-dev=true`. Service repositories dispatch the same dev deployment after their main-branch build and image scan pass when their own parameter is enabled. Manual promotions run the same image tag through `dev`, then `staging`, then `prod`.

For a first AWS deploy, keep:

| Input | Value |
|---|---|
| `action` | `deploy-dev` |
| `bootstrap_state` | `true` |
| `gateway_ref` | `main` or a release tag |
| `processor_ref` | `main` or a release tag |

For a promotion, choose `action=promote`. The workflow creates the Terraform state bucket and lock table if missing, initializes Terraform, creates the security and ECR resources first, builds both service images, pushes them to ECR, signs and verifies immutable image digests with cosign, applies the full infrastructure with `repo@sha256` references, and waits for ECS and Lambda readiness.

## Deployment Approvals

The workflow has two gates:

| Gate | Scope |
|---|---|
| `action=promote` | Manual decision to promote beyond dev |
| GitHub Environment protection | Approval before the `Apply` job starts |

Create GitHub Environments named `dev`, `staging`, and `prod`. The apply job references the selected environment, so GitHub pauses it when that environment has required reviewers configured.

Recommended environment rules:

| Environment | Required reviewers | Branch or tag rule |
|---|---|---|
| `dev` | none | `main` |
| `staging` | platform reviewer | `main` or `releases/*` |
| `prod` | platform reviewer | `main` or `releases/*` |

For `staging` and `prod`, enable required reviewers and prevent self-review where available. The `prod` job depends on successful `staging`, so production approval is not available until staging succeeds. A wait timer on `prod` is useful when you want a visible release pause before AWS resources change.

## Rollback

Use `action=rollback` in the `Deploy` workflow. By default `rollback_image_tag=previous`, which reads `/fsamp/<environment>/deployment/previous_image_tag` from SSM Parameter Store. You can also pass an explicit immutable image tag.

Rollback deploys the selected tag with Terraform and does not rebuild images. The selected tag must already exist in ECR and pass cosign signature verification. It still uses the target GitHub Environment, so rollback to `staging` or `prod` requires the same approval as a normal deployment.

## Local Terraform

LocalStack still uses local state:

```bash
make init-local
make plan-local
make apply-local
```

Manual AWS Terraform commands should use the same backend naming as the workflow:

```bash
make init-dev
make plan-dev
```
