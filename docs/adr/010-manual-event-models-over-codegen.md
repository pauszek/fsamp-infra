# ADR-010: Manual event models with contract-test gates over schema codegen

## Status

Accepted — 2026-06

## Context

`fsamp-event-schema` (JSON Schema, draft-07) is the single source of truth for
the event contract. The Java gateway and the Python processor both maintain
hand-written models (Java records / Pydantic models) that must stay in sync
with the schema. Code generation (e.g. `datamodel-code-generator` for Python,
`jsonschema2pojo` for Java) was considered to eliminate drift by construction.

## Decision

Keep the hand-written models and rely on **contract tests on both sides** as
the drift gate:

- Gateway: `EventSchemaContractTest` validates serialized events against the
  pinned schema version.
- Processor: `tests/contract/test_event_schema_contract.py` validates
  Pydantic-serialized events with `jsonschema.Draft7Validator`.
- CI (`build-java.yml` / `build-python.yml`) checks out the schema repo at the
  exact version pinned in each consumer's `schema.version` file and fails fast
  if `event.schema.json` does not land in the workspace, so the contract
  suites can never skip silently.

Rationale: at the current maturity of the platform, generated-code churn
(naming, optionality, validator placement) carries more risk than the manual
sync it would prevent, while the contract gates already detect every
divergence that matters — on the wire format.

## Consequences

- Schema changes require touching both consumers deliberately; the contract
  tests fail loudly when one is forgotten.
- If the event surface grows substantially, this decision should be revisited
  in favour of codegen with a frozen configuration.
