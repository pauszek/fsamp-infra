# ADR-007: Transactional Outbox Pattern

## Status

Accepted

## Date

2026-05

## Context

Gateway uploads a file, writes metadata, and emits a `FILE_UPLOADED` event. A direct S3/DynamoDB/SNS sequence creates a dual-write risk: metadata can be committed while the event publish fails.

The platform needs:

- at-least-once event delivery,
- retryable publishing,
- an audit trail for event state,
- no distributed transaction coordinator.

## Decision

Use a DynamoDB-backed transactional outbox.

Gateway writes file metadata and an outbox record in one DynamoDB transaction. A DynamoDB Stream triggers the outbox publisher Lambda, which publishes to SNS and updates the outbox record status.

## Consequences

Positive:

- no lost events after a successful metadata transaction,
- clear audit state: `PENDING`, `PUBLISHED`, `FAILED`,
- publisher can retry independently of the upload path,
- implementation stays within AWS managed services and LocalStack-friendly tests.

Tradeoffs:

- event publication is eventually consistent,
- consumers must be idempotent,
- stream and DLQ monitoring are required.

## Evidence

- `terraform/modules/storage/main.tf` provisions the outbox table and stream.
- `terraform/modules/compute/main.tf` wires the outbox publisher Lambda.
- `fsamp-gateway` writes outbox records during upload.
- `fsamp-processor` contains the outbox publisher handler and repository adapter.
