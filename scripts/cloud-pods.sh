#!/bin/bash
# Cloud Pods management script for LocalStack Pro
# Saves and loads infrastructure state for testing

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POD_NAME="${POD_NAME:-fsamp-dev-state}"

usage() {
    echo "Usage: $0 {save|load|list|delete}"
    echo ""
    echo "Commands:"
    echo "  save   - Save current LocalStack state to Cloud Pod"
    echo "  load   - Load Cloud Pod state into LocalStack"
    echo "  list   - List available Cloud Pods"
    echo "  delete - Delete Cloud Pod"
    echo ""
    echo "Environment:"
    echo "  POD_NAME - Name of the Cloud Pod (default: fsamp-dev-state)"
    exit 1
}

check_localstack() {
    if ! curl -sf http://localhost:4566/_localstack/health > /dev/null; then
        echo "❌ LocalStack is not running. Start it first with: docker-compose up -d"
        exit 1
    fi
}

save_pod() {
    check_localstack
    echo "💾 Saving LocalStack state to Cloud Pod: $POD_NAME"
    localstack pod save "$POD_NAME"
    echo "✅ State saved successfully!"
}

load_pod() {
    check_localstack
    echo "📥 Loading Cloud Pod: $POD_NAME"
    localstack pod load "$POD_NAME"
    echo "✅ State loaded successfully!"
}

list_pods() {
    echo "📋 Available Cloud Pods:"
    localstack pod list
}

delete_pod() {
    echo "🗑️ Deleting Cloud Pod: $POD_NAME"
    localstack pod delete "$POD_NAME"
    echo "✅ Pod deleted!"
}

case "${1:-}" in
    save)   save_pod ;;
    load)   load_pod ;;
    list)   list_pods ;;
    delete) delete_pod ;;
    *)      usage ;;
esac
