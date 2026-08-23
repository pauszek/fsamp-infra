#!/usr/bin/env python3
"""Verify Docker contracts required by the LocalStack parity environment."""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess


PROJECT_ROOT = Path(__file__).resolve().parent.parent


def load_compose_config(compose_file: Path | None = None) -> dict[str, object]:
    environment = os.environ.copy()
    environment.pop("LOCALSTACK_DNS_SERVER", None)
    command = ["docker", "compose"]
    if compose_file is not None:
        command.extend(["-f", str(compose_file)])
    command.extend(["config", "--format", "json"])
    result = subprocess.run(
        command,
        cwd=PROJECT_ROOT,
        env=environment,
        check=True,
        capture_output=True,
        text=True,
    )
    return json.loads(result.stdout)


def require_mapping(value: object, label: str) -> dict[str, object]:
    if not isinstance(value, dict):
        raise AssertionError(f"{label} must be a mapping")
    return value


def main() -> None:
    config = load_compose_config()
    services = require_mapping(config.get("services"), "services")
    localstack = require_mapping(services.get("localstack"), "localstack service")
    docker_proxy = require_mapping(services.get("docker-proxy"), "docker-proxy service")
    localstack_environment = require_mapping(
        localstack.get("environment"), "localstack environment"
    )

    if localstack_environment.get("DOCKER_HOST") != "tcp://docker-proxy:2375":
        raise AssertionError("LocalStack must use the restricted Docker socket proxy")
    if localstack_environment.get("DNS_SERVER") != "127.0.0.11":
        raise AssertionError(
            "LocalStack DNS must forward unknown service names to Docker's embedded resolver"
        )
    localstack_services = set(str(localstack_environment.get("SERVICES", "")).split(","))
    if "xray" not in localstack_services:
        raise AssertionError("LocalStack must enable X-Ray when Lambda tracing is active")

    dependencies = require_mapping(localstack.get("depends_on"), "localstack dependencies")
    if "docker-proxy" not in dependencies:
        raise AssertionError("LocalStack must wait for the Docker socket proxy")

    localstack_networks = set(
        require_mapping(localstack.get("networks"), "localstack networks")
    )
    proxy_networks = set(
        require_mapping(docker_proxy.get("networks"), "docker-proxy networks")
    )
    if not localstack_networks.intersection(proxy_networks):
        raise AssertionError("LocalStack and the Docker socket proxy must share a network")

    e2e_config = load_compose_config(PROJECT_ROOT / "e2e" / "docker-compose.yml")
    e2e_services = require_mapping(e2e_config.get("services"), "E2E services")
    e2e_localstack = require_mapping(
        e2e_services.get("localstack"), "E2E localstack service"
    )
    e2e_environment = require_mapping(
        e2e_localstack.get("environment"), "E2E localstack environment"
    )
    e2e_enabled_services = set(str(e2e_environment.get("SERVICES", "")).split(","))
    if "xray" not in e2e_enabled_services:
        raise AssertionError("Quick E2E must enable X-Ray for traced Lambdas")
    localstack_image = localstack.get("image")
    if localstack_image != e2e_localstack.get("image"):
        raise AssertionError("Parity and quick E2E must pin the same LocalStack image")
    if not isinstance(localstack_image, str) or "@sha256:" not in localstack_image:
        raise AssertionError("LocalStack images must be pinned by immutable digest")

    managed_seed = subprocess.run(
        ["bash", str(PROJECT_ROOT / "localstack" / "seed-users.sh")],
        cwd=PROJECT_ROOT,
        env={**os.environ, "FSAMP_TF_MANAGED": "1"},
        capture_output=True,
        text=True,
    )
    if managed_seed.returncode != 0:
        raise AssertionError(
            "The mounted seed script must be a no-op during Terraform-managed startup: "
            f"{managed_seed.stderr.strip()}"
        )

    print("LocalStack image, startup, Docker proxy and DNS contracts verified")


if __name__ == "__main__":
    main()
