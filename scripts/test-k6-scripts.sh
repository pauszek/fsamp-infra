#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
K6_IMAGE="${K6_IMAGE:-grafana/k6@sha256:e7eeddf1ce2361df6920d925297f487c0ba549c44be242c6a9c22f28d9b08efa}"

for test_script in smoke-test.js load-test.js stress-test.js spike-test.js soak-test.js; do
    docker run --rm \
        -v "${PROJECT_ROOT}/load-tests/k6:/scripts:ro" \
        "${K6_IMAGE}" \
        inspect "/scripts/${test_script}" >/dev/null
done

K6_IMAGE="${K6_IMAGE}" python3 "${SCRIPT_DIR}/test-k6-contract.py"
