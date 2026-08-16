#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(dirname "$SCRIPT_DIR")"
WORKSPACE_DIR="$(dirname "$INFRA_DIR")"
cd "$SCRIPT_DIR"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

MODE="default"
CLEANUP="true"
BUILD_IMAGES="false"

export AWS_DEFAULT_REGION="us-west-2"
export AWS_REGION="us-west-2"

while [[ $# -gt 0 ]]; do
    case $1 in
        --build)
            BUILD_IMAGES="true"
            shift
            ;;
        --local)
            MODE="local"
            BUILD_IMAGES="true"
            shift
            ;;
        --ci)
            MODE="ci"
            shift
            ;;
        --cleanup)
            CLEANUP="true"
            shift
            ;;
        --no-cleanup)
            CLEANUP="false"
            shift
            ;;
        --help)
            head -30 "$0" | tail -25
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            exit 1
            ;;
    esac
done

if [[ -z "${LOCALSTACK_AUTH_TOKEN:-}" ]]; then
    echo -e "${RED}Error: LOCALSTACK_AUTH_TOKEN not set${NC}"
    echo "Export your LocalStack Pro token: export LOCALSTACK_AUTH_TOKEN=your-token"
    exit 1
fi

log() {
    echo -e "${BLUE}[E2E]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[E2E]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[E2E]${NC} $1"
}

log_error() {
    echo -e "${RED}[E2E]${NC} $1"
}

# Invoked indirectly by the EXIT trap below.
# shellcheck disable=SC2329
cleanup() {
    if [[ "$CLEANUP" == "true" ]]; then
        log "Cleaning up..."
        docker-compose down -v --remove-orphans 2>/dev/null || true
    else
        log_warning "Skipping cleanup (--no-cleanup specified)"
        log "To cleanup manually: docker-compose down -v"
    fi
}

trap cleanup EXIT

build_local_images() {
    log "Building local images..."

    GATEWAY_REPO="${WORKSPACE_DIR}/fsamp-gateway"
    if [[ -d "$GATEWAY_REPO" ]]; then
        log "Building Gateway..."
        pushd "$GATEWAY_REPO" > /dev/null
        if [[ -f "build.sh" ]]; then
            ./build.sh
        else
            docker build -t fsamp-gateway:latest .
        fi
        popd > /dev/null
        log_success "Gateway built: fsamp-gateway:latest"
    else
        log_warning "Gateway repo not found at $GATEWAY_REPO"
    fi

    PROCESSOR_REPO="${WORKSPACE_DIR}/fsamp-processor"
    if [[ -d "$PROCESSOR_REPO" ]]; then
        log "Building Processor..."
        pushd "$PROCESSOR_REPO" > /dev/null
        if [[ -f "build.sh" ]]; then
            ./build.sh
        else
            docker build -f Dockerfile.lambda -t fsamp-processor:latest .
        fi
        popd > /dev/null
        log_success "Processor Lambda/FIPS image built: fsamp-processor:latest"
    else
        log_warning "Processor repo not found at $PROCESSOR_REPO"
    fi
}

main() {
    log "Starting E2E tests (mode: $MODE)"

    if [[ "$BUILD_IMAGES" == "true" ]]; then
        build_local_images
    fi

    case $MODE in
        local)
            log "Using locally built images..."
            export GATEWAY_IMAGE="fsamp-gateway:latest"
            export PROCESSOR_IMAGE="fsamp-processor:latest"
            ;;
        ci)
            log "CI mode: fail fast, no TTY..."
            export COMPOSE_INTERACTIVE_NO_CLI=1
            ;;
    esac

    log "Cleaning up previous runs..."
    docker-compose down -v --remove-orphans 2>/dev/null || true

    log "Starting LocalStack..."
    docker-compose up -d localstack

    log "Waiting for LocalStack to be ready..."
    local retries=30
    while [[ $retries -gt 0 ]]; do
        if docker-compose exec -T localstack curl -sf http://localhost:4566/_localstack/health > /dev/null 2>&1; then
            log_success "LocalStack is ready!"
            break
        fi
        retries=$((retries - 1))
        sleep 2
    done

    if [[ $retries -eq 0 ]]; then
        log_error "LocalStack failed to start"
        docker-compose logs localstack
        exit 1
    fi

    log "Waiting for LocalStack initialization..."
    retries=30
    while [[ $retries -gt 0 ]]; do
        if docker-compose exec -T localstack test -f /tmp/localstack-config/fsamp-config.env 2>/dev/null; then
            log_success "LocalStack initialized!"
            break
        fi
        retries=$((retries - 1))
        sleep 2
    done

    if [[ $retries -eq 0 ]]; then
        log_error "LocalStack initialization failed"
        docker-compose logs localstack
        exit 1
    fi

    log "Starting gateway and processor..."
    docker-compose up -d gateway processor

    log "Waiting for gateway to be ready..."
    retries=30
    while [[ $retries -gt 0 ]]; do
        if docker-compose exec -T gateway curl -sf http://localhost:8080/actuator/health > /dev/null 2>&1; then
            log_success "Gateway is ready!"
            break
        fi
        retries=$((retries - 1))
        sleep 2
    done

    if [[ $retries -eq 0 ]]; then
        log_error "Gateway failed to start"
        docker-compose logs gateway
        exit 1
    fi

    log "Running E2E tests..."
    if docker-compose --profile test up --abort-on-container-exit e2e-tests; then
        log_success "E2E tests passed!"
        exit 0
    else
        log_error "E2E tests failed!"

        log "Gateway logs:"
        docker-compose logs --tail=50 gateway
        log "Processor logs:"
        docker-compose logs --tail=50 processor

        exit 1
    fi
}

main
