#!/usr/bin/env python3
"""Fail closed on changes beyond pinned LocalStack readback limitations."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import subprocess
from typing import Any


LAMBDA_KMS_GAPS = frozenset(
    {
        "module.compute[0].aws_lambda_function.outbox_publisher[0]",
        "module.compute[0].aws_lambda_function.outbox_retry[0]",
        "module.compute[0].aws_lambda_function.processor[0]",
    }
)
EXPECTED_GAPS = LAMBDA_KMS_GAPS


def _changed_fields(change: dict[str, Any]) -> set[str]:
    before = change.get("before") or {}
    after = change.get("after") or {}
    changed = {
        key
        for key in before.keys() | after.keys()
        if before.get(key) != after.get(key)
    }
    changed.update(
        key
        for key, unknown in (change.get("after_unknown") or {}).items()
        if unknown
    )
    return changed


def validate_plan(plan: dict[str, Any]) -> None:
    """Validate the exact three gaps of the pinned LocalStack Pro image."""
    managed_changes = {
        resource["address"]: resource["change"]
        for resource in plan.get("resource_changes", [])
        if resource.get("mode") == "managed"
        and resource.get("change", {}).get("actions") != ["no-op"]
    }

    actual_addresses = set(managed_changes)
    missing = EXPECTED_GAPS - actual_addresses
    unexpected = actual_addresses - EXPECTED_GAPS
    if missing:
        raise ValueError("missing expected readback gaps: " + ", ".join(sorted(missing)))
    if unexpected:
        raise ValueError("unexpected managed changes: " + ", ".join(sorted(unexpected)))

    for address, change in managed_changes.items():
        if change.get("actions") != ["update"]:
            raise ValueError(
                f"{address} must be an in-place update, got {change.get('actions')}"
            )

        expected_field = "kms_key_arn"
        changed_fields = _changed_fields(change)
        if changed_fields != {expected_field}:
            raise ValueError(
                f"{address} changed {sorted(changed_fields)}, expected only "
                f"{expected_field}"
            )

        before = (change.get("before") or {}).get(expected_field)
        after = (change.get("after") or {}).get(expected_field)
        expected_prefix = "arn:aws:kms:"
        if before not in (None, "") or not isinstance(after, str) or not after.startswith(
            expected_prefix
        ):
            raise ValueError(
                f"{address} does not match the pinned {expected_field} readback gap"
            )


def _load_binary_plan(plan_path: Path) -> dict[str, Any]:
    result = subprocess.run(
        ["terraform", "show", "-json", str(plan_path)],
        check=True,
        capture_output=True,
        text=True,
    )
    return json.loads(result.stdout)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Verify the exact readback gaps of the pinned LocalStack plan"
    )
    parser.add_argument("plan", type=Path, help="Terraform binary plan file")
    args = parser.parse_args()

    try:
        validate_plan(_load_binary_plan(args.plan))
    except (OSError, subprocess.CalledProcessError, json.JSONDecodeError, ValueError) as exc:
        parser.exit(1, f"LocalStack plan verification failed: {exc}\n")

    print("Verified exactly 3 pinned LocalStack readback gaps; no other changes.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
