"""Regression tests for the pinned LocalStack readback-gap verifier."""

from __future__ import annotations

import importlib.util
from pathlib import Path
import unittest


CHECKER_PATH = Path(__file__).with_name("check-localstack-plan.py")
SPEC = importlib.util.spec_from_file_location("localstack_plan_checker", CHECKER_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"Cannot load plan checker from {CHECKER_PATH}")
CHECKER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECKER)


def _change(address: str, field: str, before: str, after: str) -> dict[str, object]:
    return {
        "address": address,
        "mode": "managed",
        "change": {
            "actions": ["update"],
            "before": {field: before, "id": "stable"},
            "after": {field: after, "id": "stable"},
            "after_unknown": {},
        },
    }


def _valid_plan() -> dict[str, object]:
    changes = []
    for address in CHECKER.LAMBDA_KMS_GAPS:
        changes.append(
            _change(
                address,
                "kms_key_arn",
                "",
                "arn:aws:kms:us-west-2:000000000000:key/test",
            )
        )
    return {"resource_changes": changes}


class LocalStackPlanCheckTest(unittest.TestCase):
    def test_accepts_only_the_pinned_readback_gaps(self) -> None:
        CHECKER.validate_plan(_valid_plan())

    def test_rejects_missing_expected_gap(self) -> None:
        plan = _valid_plan()
        plan["resource_changes"].pop()  # type: ignore[union-attr]

        with self.assertRaisesRegex(ValueError, "missing expected"):
            CHECKER.validate_plan(plan)

    def test_rejects_unexpected_managed_change(self) -> None:
        plan = _valid_plan()
        plan["resource_changes"].append(  # type: ignore[union-attr]
            _change("aws_s3_bucket.unexpected", "tags", "old", "new")
        )

        with self.assertRaisesRegex(ValueError, "unexpected managed"):
            CHECKER.validate_plan(plan)

    def test_rejects_api_gateway_target_readback_drift(self) -> None:
        plan = _valid_plan()
        plan["resource_changes"].append(  # type: ignore[union-attr]
            _change(
                "module.api_gateway[0].aws_api_gateway_integration.file_get[0]",
                "integration_target",
                "",
                "arn:aws:elasticloadbalancing:us-west-2:000000000000:loadbalancer/app/fsamp/test",
            )
        )

        with self.assertRaisesRegex(ValueError, "unexpected managed"):
            CHECKER.validate_plan(plan)


if __name__ == "__main__":
    unittest.main()
