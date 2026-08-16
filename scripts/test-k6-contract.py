#!/usr/bin/env python3
"""Exercise the k6 smoke scenario against a strict local HTTP contract."""

from __future__ import annotations

import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import subprocess
import threading


PROJECT_ROOT = Path(__file__).resolve().parent.parent
SMOKE_TEST = PROJECT_ROOT / "load-tests" / "k6" / "smoke-test.js"
DEFAULT_K6_IMAGE = (
    "grafana/k6@sha256:e7eeddf1ce2361df6920d925297f487c0ba549c44be242c6a9c22f28d9b08efa"
)
TEST_TOKEN = "contract-test-token"


class ContractState:
    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.health_requests = 0
        self.multipart_uploads = 0
        self.invalid_uploads = 0
        self.not_found_requests = 0
        self.file_ids: dict[str, str] = {}


STATE = ContractState()


class ContractHandler(BaseHTTPRequestHandler):
    server_version = "FSAMPContractTest/1.0"

    def log_message(self, _format: str, *_args: object) -> None:
        return

    def send_json(self, status: int, payload: dict[str, str]) -> None:
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        if self.path == "/health":
            with STATE.lock:
                STATE.health_requests += 1
            self.send_json(200, {"status": "UP"})
            return

        with STATE.lock:
            STATE.not_found_requests += 1
        self.send_json(404, {"error": "not found"})

    def do_POST(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        content_length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(content_length)

        if self.path != "/files/upload":
            self.send_json(404, {"error": "not found"})
            return

        content_type = self.headers.get("Content-Type", "")
        if not content_type.startswith("multipart/form-data; boundary="):
            with STATE.lock:
                STATE.invalid_uploads += 1
            self.send_json(415, {"error": "multipart required"})
            return

        idempotency_key = self.headers.get("X-Idempotency-Key", "")
        valid_multipart = all(
            marker in body
            for marker in (
                b'name="file"',
                b'filename="smoke-test-',
                b"Content-Type: text/plain",
            )
        )
        if (
            self.headers.get("Authorization") != f"Bearer {TEST_TOKEN}"
            or not idempotency_key
            or not valid_multipart
        ):
            self.send_json(400, {"error": "invalid upload contract"})
            return

        with STATE.lock:
            STATE.multipart_uploads += 1
            file_id = STATE.file_ids.setdefault(
                idempotency_key, f"file-{idempotency_key}"
            )
        self.send_json(200, {"fileId": file_id})


def assert_smoke_test_is_testable() -> None:
    source = SMOKE_TEST.read_text()
    required_fragments = (
        "__ENV.SMOKE_DURATION",
        "__ENV.SMOKE_VUS",
        "http.expectedStatuses(404)",
        "http.expectedStatuses(400, 415)",
    )
    missing = [fragment for fragment in required_fragments if fragment not in source]
    if missing:
        raise AssertionError(f"Smoke test is missing test hooks: {', '.join(missing)}")


def run_contract_test() -> None:
    server = ThreadingHTTPServer(("0.0.0.0", 0), ContractHandler)
    server_thread = threading.Thread(target=server.serve_forever, daemon=True)
    server_thread.start()

    try:
        port = server.server_address[1]
        k6_image = os.environ.get("K6_IMAGE", DEFAULT_K6_IMAGE)
        command = [
            "docker",
            "run",
            "--rm",
            "--add-host=host.docker.internal:host-gateway",
            "-e",
            f"BASE_URL=http://host.docker.internal:{port}",
            "-e",
            f"AUTH_TOKEN={TEST_TOKEN}",
            "-e",
            "SMOKE_DURATION=1s",
            "-e",
            "SMOKE_VUS=1",
            "-v",
            f"{SMOKE_TEST.parent}:/scripts:ro",
            k6_image,
            "run",
            "--quiet",
            "/scripts/smoke-test.js",
        ]
        result = subprocess.run(
            command,
            check=False,
            capture_output=True,
            text=True,
            timeout=60,
        )
        if result.returncode != 0:
            raise AssertionError(
                "k6 smoke contract failed\n"
                f"stdout:\n{result.stdout}\n"
                f"stderr:\n{result.stderr}"
            )
    finally:
        server.shutdown()
        server.server_close()
        server_thread.join(timeout=5)

    with STATE.lock:
        assert STATE.health_requests >= 2, "health route was not exercised"
        assert STATE.multipart_uploads >= 2, "multipart upload and retry were not sent"
        assert STATE.invalid_uploads >= 1, "non-multipart rejection was not exercised"
        assert STATE.not_found_requests >= 1, "404 route was not exercised"
        assert len(STATE.file_ids) >= 1, "idempotency key was not supplied"


if __name__ == "__main__":
    assert_smoke_test_is_testable()
    run_contract_test()
