# =============================================================================
# FSAMP E2E Tests - Full Stack Integration
# =============================================================================
# This directory contains end-to-end tests for the complete FSAMP system.
# E2E tests validate the entire flow from gateway through processor.
#
# Prerequisites:
#   - All service images built and available (gateway, processor)
#   - LocalStack Pro token configured
#
# Usage:
#   ./run-e2e.sh [--local|--ci]
#
# Structure:
#   docker-compose.yml  - Full stack composition
#   tests/              - Test scenarios (created by fsamp-gateway or separate repo)
#   run-e2e.sh          - Test runner script
# =============================================================================

## When to use E2E tests

E2E tests are expensive (slow, complex setup). Use sparingly for:
- Critical business flows
- Cross-service integration validation
- Pre-release verification

For most testing, prefer:
- Unit tests (fast, isolated)
- Integration tests (per-service with LocalStack)

## Test Strategy

```
┌─────────────────────────────────────────────────────────────┐
│                     E2E Test Flow                            │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  ┌─────────┐    ┌───────────┐    ┌───────────┐              │
│  │ Gateway │───▶│ LocalStack│───▶│ Processor │              │
│  └─────────┘    │  (SNS/SQS)│    └───────────┘              │
│       │         └───────────┘          │                    │
│       │              │                 │                    │
│       ▼              ▼                 ▼                    │
│  ┌─────────┐    ┌───────────┐    ┌───────────┐              │
│  │   S3    │    │ DynamoDB  │    │    S3     │              │
│  │ (files) │    │ (metadata)│    │(processed)│              │
│  └─────────┘    └───────────┘    └───────────┘              │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

## Cloud Pods Integration

E2E tests can use Cloud Pods for consistent infrastructure state:

```bash
# Load base infrastructure state before E2E
../scripts/cloud-pods.sh load fsamp-e2e-base

# Run E2E tests
docker-compose up --abort-on-container-exit e2e-tests

# Optionally save state after test data creation
../scripts/cloud-pods.sh save fsamp-e2e-with-data
```
