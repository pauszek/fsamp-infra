#!/bin/bash
# =============================================================================
# Cloud Pods Management Script for LocalStack Pro
# =============================================================================
# Manages LocalStack Cloud Pods for consistent state across environments.
# Cloud Pods allow saving and restoring the complete LocalStack state.
#
# Prerequisites:
#   - LocalStack Pro license (LOCALSTACK_AUTH_TOKEN)
#   - LocalStack CLI: pip install localstack
#
# Usage:
#   ./cloud-pods.sh <command> [name]
#
# Commands:
#   save <name>   Save current state to Cloud Pod
#   load <name>   Load Cloud Pod into LocalStack
#   list          List all Cloud Pods
#   delete <name> Delete a Cloud Pod
#   inject <name> Inject Cloud Pod (merge with current state)
#
# Examples:
#   ./cloud-pods.sh save base              # Save as fsamp-base
#   ./cloud-pods.sh load base              # Load fsamp-base
#   ./cloud-pods.sh save integration-ready # Save as fsamp-integration-ready
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Configuration
POD_PREFIX="fsamp"
LOCALSTACK_ENDPOINT="${LOCALSTACK_ENDPOINT:-http://localhost:4566}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# -----------------------------------------------------------------------------
# Helper Functions
# -----------------------------------------------------------------------------

log() {
    echo -e "${BLUE}[CloudPods]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[CloudPods]${NC} ✅ $1"
}

log_warning() {
    echo -e "${YELLOW}[CloudPods]${NC} ⚠️  $1"
}

log_error() {
    echo -e "${RED}[CloudPods]${NC} ❌ $1"
}

log_info() {
    echo -e "${CYAN}[CloudPods]${NC} ℹ️  $1"
}

check_prerequisites() {
    # Check LocalStack CLI
    if ! command -v localstack &> /dev/null; then
        log_error "LocalStack CLI not found."
        log_info "Install with: pip install localstack"
        exit 1
    fi

    # Check auth token
    if [[ -z "${LOCALSTACK_AUTH_TOKEN:-}" ]]; then
        # Try to load from .env
        if [[ -f "$PROJECT_ROOT/.env" ]]; then
            source "$PROJECT_ROOT/.env" 2>/dev/null || true
        fi
    fi

    if [[ -z "${LOCALSTACK_AUTH_TOKEN:-}" ]]; then
        log_error "LOCALSTACK_AUTH_TOKEN not set."
        log_info "Set it in environment or in $PROJECT_ROOT/.env"
        exit 1
    fi
}

wait_for_localstack() {
    log "Waiting for LocalStack to be ready..."
    local max_attempts=30
    local attempt=1

    while [[ $attempt -le $max_attempts ]]; do
        if curl -sf "${LOCALSTACK_ENDPOINT}/_localstack/health" > /dev/null 2>&1; then
            log_success "LocalStack is ready"
            return 0
        fi
        printf "."
        sleep 2
        ((attempt++))
    done
    echo ""

    log_error "LocalStack failed to start after ${max_attempts} attempts"
    exit 1
}

get_pod_name() {
    local name="${1:-base}"
    echo "${POD_PREFIX}-${name}"
}

# -----------------------------------------------------------------------------
# Commands
# -----------------------------------------------------------------------------

cmd_save() {
    local name="${1:-}"
    if [[ -z "$name" ]]; then
        log_error "Pod name required. Usage: $0 save <name>"
        exit 1
    fi

    local pod_name=$(get_pod_name "$name")
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    log "Saving LocalStack state to Cloud Pod: $pod_name"
    wait_for_localstack

    if localstack pod save "$pod_name" --message "Saved on $timestamp"; then
        log_success "Cloud Pod saved: $pod_name"
        log_info "Load with: $0 load $name"
    else
        log_error "Failed to save Cloud Pod"
        exit 1
    fi
}

cmd_load() {
    local name="${1:-}"
    if [[ -z "$name" ]]; then
        log_error "Pod name required. Usage: $0 load <name>"
        exit 1
    fi

    local pod_name=$(get_pod_name "$name")

    log "Loading Cloud Pod: $pod_name"
    wait_for_localstack

    if localstack pod load "$pod_name"; then
        log_success "Cloud Pod loaded: $pod_name"
    else
        log_error "Failed to load Cloud Pod. Does it exist?"
        log_info "List available pods with: $0 list"
        exit 1
    fi
}

cmd_inject() {
    local name="${1:-}"
    if [[ -z "$name" ]]; then
        log_error "Pod name required. Usage: $0 inject <name>"
        exit 1
    fi

    local pod_name=$(get_pod_name "$name")

    log "Injecting Cloud Pod (merging): $pod_name"
    wait_for_localstack

    if localstack pod load "$pod_name" --merge; then
        log_success "Cloud Pod injected: $pod_name"
    else
        log_error "Failed to inject Cloud Pod"
        exit 1
    fi
}

cmd_list() {
    log "Listing Cloud Pods with prefix: $POD_PREFIX"
    echo ""

    local pods=$(localstack pod list 2>/dev/null || echo "")

    if [[ -n "$pods" ]]; then
        echo "$pods" | grep -E "$POD_PREFIX|NAME" || log_warning "No pods found with prefix: $POD_PREFIX"
    else
        log_warning "Could not retrieve pod list. Are you authenticated?"
    fi
}

cmd_delete() {
    local name="${1:-}"
    if [[ -z "$name" ]]; then
        log_error "Pod name required. Usage: $0 delete <name>"
        exit 1
    fi

    local pod_name=$(get_pod_name "$name")

    log_warning "Deleting Cloud Pod: $pod_name"
    read -p "Are you sure? (y/N): " confirm

    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        if localstack pod delete "$pod_name"; then
            log_success "Cloud Pod deleted: $pod_name"
        else
            log_error "Failed to delete Cloud Pod"
            exit 1
        fi
    else
        log "Cancelled"
    fi
}

cmd_help() {
    cat << EOF
${CYAN}Cloud Pods Management Script${NC}

${YELLOW}Usage:${NC}
  $0 <command> [name]

${YELLOW}Commands:${NC}
  save <name>     Save current LocalStack state to Cloud Pod
  load <name>     Load Cloud Pod into LocalStack (replaces current state)
  inject <name>   Inject Cloud Pod (merge with current state)
  list            List all Cloud Pods
  delete <name>   Delete a Cloud Pod
  help            Show this help message

${YELLOW}Examples:${NC}
  $0 save base                  # Save as ${POD_PREFIX}-base
  $0 load base                  # Load ${POD_PREFIX}-base
  $0 save integration-ready     # Save as ${POD_PREFIX}-integration-ready
  $0 list                       # List all ${POD_PREFIX}-* pods

${YELLOW}Recommended Pod Names:${NC}
  base              Initial infrastructure (after terraform apply)
  integration-ready Ready for integration tests (with test data)
  e2e-ready         Ready for E2E tests (with services configured)

${YELLOW}Environment:${NC}
  LOCALSTACK_AUTH_TOKEN   Required for Cloud Pods (Pro feature)
  LOCALSTACK_ENDPOINT     LocalStack URL (default: http://localhost:4566)

${YELLOW}CI/CD Usage:${NC}
  # In CI pipeline:
  docker-compose up -d
  ./scripts/cloud-pods.sh load base
  # Run tests...

EOF
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

check_prerequisites

case "${1:-help}" in
    save)
        cmd_save "${2:-}"
        ;;
    load)
        cmd_load "${2:-}"
        ;;
    inject)
        cmd_inject "${2:-}"
        ;;
    list)
        cmd_list
        ;;
    delete)
        cmd_delete "${2:-}"
        ;;
    help|--help|-h)
        cmd_help
        ;;
    *)
        log_error "Unknown command: $1"
        cmd_help
        exit 1
        ;;
esac
