#!/usr/bin/env python3
"""Verify release-package and wire-contract version semantics."""

from __future__ import annotations

import ast
from pathlib import Path
import re


PROJECT_ROOT = Path(__file__).resolve().parent.parent
SEMVER_PATTERN = re.compile(r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")


def parse_semver(label: str, value: str) -> tuple[int, int, int]:
    match = SEMVER_PATTERN.fullmatch(value)
    if match is None:
        raise AssertionError(f"{label} must be a stable semantic version, got {value!r}")
    return tuple(int(part) for part in match.groups())


def read_current_versions() -> dict[str, str]:
    content = (PROJECT_ROOT / "compatibility.yml").read_text()
    current: dict[str, str] = {}
    in_current = False

    for line in content.splitlines():
        if line == "current:":
            in_current = True
            continue
        if in_current and line and not line.startswith((" ", "#")):
            break
        if not in_current:
            continue
        match = re.fullmatch(r'  ([a-z][a-z0-9-]*): "([^"]+)"', line)
        if match is not None:
            current[match.group(1)] = match.group(2)

    required = {"gateway", "processor", "event-schema", "event-contract", "infra", "code-ci"}
    missing = sorted(required - current.keys())
    if missing:
        raise AssertionError(f"compatibility.yml is missing current entries: {', '.join(missing)}")
    return current


def read_e2e_contract_version() -> str:
    source = (PROJECT_ROOT / "e2e" / "run-e2e-tests.py").read_text()
    module = ast.parse(source)

    for node in module.body:
        if not isinstance(node, ast.ClassDef) or node.name != "TestConfig":
            continue
        for statement in node.body:
            if not isinstance(statement, ast.Assign):
                continue
            if any(isinstance(target, ast.Name) and target.id == "EVENT_SCHEMA_VERSION" for target in statement.targets):
                value = ast.literal_eval(statement.value)
                if isinstance(value, str):
                    return value

    raise AssertionError("TestConfig.EVENT_SCHEMA_VERSION is missing from the E2E suite")


def is_patch_compatible(release: tuple[int, int, int], contract: tuple[int, int, int]) -> bool:
    return release[:2] == contract[:2] and release[2] >= contract[2]


def verify_schema_constraints(contract: tuple[int, int, int]) -> None:
    content = (PROJECT_ROOT / "compatibility.yml").read_text()
    constraints = re.findall(
        r'^    event-schema: ">=([0-9]+\.[0-9]+\.[0-9]+),<([0-9]+\.[0-9]+\.[0-9]+)"$',
        content,
        flags=re.MULTILINE,
    )
    expected_upper = (contract[0], contract[1] + 1, 0)
    if len(constraints) != 2:
        raise AssertionError("gateway and processor must each declare an event-schema constraint")
    for lower_text, upper_text in constraints:
        if parse_semver("event-schema lower bound", lower_text) != contract:
            raise AssertionError("event-schema lower bounds must equal the wire contract version")
        if parse_semver("event-schema upper bound", upper_text) != expected_upper:
            raise AssertionError("event-schema constraints must reject the next minor contract")


def main() -> None:
    current = read_current_versions()
    release = parse_semver("current.event-schema", current["event-schema"])
    contract = parse_semver("current.event-contract", current["event-contract"])
    e2e_contract = parse_semver("E2E event schema", read_e2e_contract_version())

    if contract != e2e_contract:
        raise AssertionError(
            "current.event-contract must match TestConfig.EVENT_SCHEMA_VERSION"
        )
    if not is_patch_compatible(release, contract):
        raise AssertionError(
            "current.event-schema must have the wire contract's major/minor and an equal or newer patch"
        )

    assert is_patch_compatible((1, 2, 0), (1, 2, 0))
    assert is_patch_compatible((1, 2, 1), (1, 2, 0))
    assert not is_patch_compatible((1, 1, 9), (1, 2, 0))
    assert not is_patch_compatible((1, 3, 0), (1, 2, 0))
    assert not is_patch_compatible((2, 0, 0), (1, 2, 0))
    verify_schema_constraints(contract)
    print(
        f"Compatibility verified: release {current['event-schema']} carries wire contract "
        f"{current['event-contract']}"
    )


if __name__ == "__main__":
    main()
