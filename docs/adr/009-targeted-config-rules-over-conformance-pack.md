# ADR-009: Targeted AWS Config rules instead of the FedRAMP conformance pack

## Status

Accepted — 2026-06

## Context

AWS Config offers an "Operational Best Practices for FedRAMP" conformance pack
(~130+ managed rules) that could be attached to the account in one resource.
The platform needs continuous configuration monitoring evidence mapped to
NIST SP 800-53 controls (CM-6, CA-7).

## Decision

Maintain a hand-picked set of `aws_config_config_rule` resources (12 rules),
each tagged with the exact NIST control it evidences, instead of subscribing
to the conformance pack.

Rationale:

- **Explicit control mapping** — every rule carries a `Compliance = NIST-*`
  tag; the thesis can present a direct rule -> control table instead of an
  opaque pack reference.
- **Signal over noise** — the pack evaluates many rules irrelevant to this
  architecture (RDS, Redshift, EC2 fleets), producing noncompliant noise on a
  single-account demo platform.
- **Cost** — rule evaluations are billed per evaluation; 12 targeted rules at
  this resource count cost pennies, the pack would evaluate an order of
  magnitude more.

## Consequences

- New controls require a deliberate rule addition (reviewed in Terraform)
  rather than arriving silently with a pack update.
- The rule set must be revisited if the architecture grows new resource types.

## Related: GuardDuty S3 Malware Protection (evaluated, excluded on cost)

GuardDuty Malware Protection for S3 was evaluated for SI-3 coverage and
excluded: pricing is per-GB scanned (~0.60 USD/GB) with no meaningful free
tier, which violates the project budget for a feature that would be exercised
once in a demo. Compensating controls: GuardDuty S3 data-event monitoring
(enabled), strict MIME/content validation in the gateway (Tika), SHA-256
checksum verification in the processor, and Trivy/ECR-Inspector image
scanning in the supply chain.
