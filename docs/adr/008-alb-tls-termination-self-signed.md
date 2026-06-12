# ADR-008: FIPS TLS on the API Gateway -> ALB hop with a self-signed certificate

## Status

Accepted — 2026-06

## Context

The original architecture terminated TLS at the API Gateway edge and used plain
HTTP for the VPC Link integration to the internal gateway ALB. FedRAMP SC-8
(Transmission Confidentiality and Integrity) and the project's FIPS 140-3
posture call for encryption in transit with FIPS-validated cryptography on
every network hop that carries application data, including intra-VPC hops.

Constraints:

- No public domain is in scope for the platform, so a DNS-validated public ACM
  certificate cannot be issued for the internal ALB.
- AWS Private CA (~400 USD/month) is far outside the free-tier project budget.
- The local environment (LocalStack) does not instantiate the compute or
  api-gateway modules at all (`count = local.is_local ? 0 : 1`), so the change
  has no LocalStack impact.

## Decision

1. The internal gateway ALB listener terminates **HTTPS:443** with the AWS FIPS
   security policy **`ELBSecurityPolicy-TLS13-1-2-FIPS-2023-04`** (AWS-LC,
   FIPS 140-3 validated cipher suites only).
2. The certificate is a **Terraform-managed self-signed RSA-2048 certificate
   imported into ACM** (free). `early_renewal_hours = 720` regenerates the key
   pair on `terraform apply` within 30 days of expiry (SC-12 procedure).
3. The three API Gateway VPC Link integrations use `https://` URIs with
   `tls_config { insecure_skip_verification = true }` as a **documented
   compensating control**: transit is encrypted with FIPS-validated TLS, and
   endpoint authenticity is anchored by the VPC Link private ENIs plus the ALB
   security group (443 only from the VPC CIDR) instead of a public chain of
   trust (SC-23 exception).
4. **TLS terminates at the ALB.** The final ALB -> task HTTP:8080 hop stays
   unencrypted on private-subnet ENIs where the ECS security group accepts 8080
   exclusively from the ALB security group (SC-7 boundary protection).
   Spring-side TLS was evaluated and rejected as disproportionate (keystore
   distribution, BC-FIPS TLS stack configuration, health-check changes) for a
   single-VPC east-west hop.

## Alternatives Considered

- **Public ACM certificate + custom domain** — preferred end-state; removes
  the skip-verification exception. Implemented as the opt-in mode
  `alb_certificate_mode = "acm"` (DNS-validated ACM certificate with a
  Route53 zone and an alias record; integrations then enforce certificate
  verification). Under LocalStack Pro it works locally; in real AWS it
  activates once a delegated public domain is available. The default stays
  `self-signed` until then.
- **ACM Private CA** — full private chain of trust, but ~400 USD/month.
- **Keep HTTP and document as accepted risk** — weakest option; leaves SC-8
  unmet on an application-data hop and keeps three Checkov skips alive.

## Consequences

- Checkov skips `CKV_AWS_2`, `CKV_AWS_103` and `CKV2_AWS_20` were removed; the
  checks now pass on merit.
- The ALB security group needed an egress rule on 443 for the VPC Link ENIs
  (which share the security group); the previous rule set had no egress for
  the listener port at all.
- `alb_tls_enabled` (default `true`) exists in the compute and api-gateway
  modules as a rollback lever only and must be flipped in both together.
- The AWS Config rule `ELBV2_ACM_CERTIFICATE_REQUIRED` provides continuous
  evidence that the listener carries an ACM certificate.
