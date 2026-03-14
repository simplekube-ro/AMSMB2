#!/bin/bash
# Integration test runner for AMSMB2 (requires Docker)
# Usage: ./scripts/test-integration.sh [options]
#
# Options:
#   --filter PATTERN   Run tests matching pattern (swift test --filter)
#   --skip-docker      Skip Docker container start/stop (containers already running)
#   -v                 Verbose output
#   --help             Show this help

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
FIXTURES_DIR="$PROJECT_ROOT/test-fixtures"

cd "$PROJECT_ROOT"

# Defaults
SKIP_DOCKER=false
FILTER=""
VERBOSITY=0

# Show help
show_help() {
    head -8 "$0" | tail -6 | sed 's/^# //' | sed 's/^#//'
    exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --help|-h) show_help ;;
        --skip-docker) SKIP_DOCKER=true; shift ;;
        --filter) FILTER="$2"; shift 2 ;;
        -v) VERBOSITY=1; shift ;;
        *) shift ;;
    esac
done

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "AMSMB2 Integration Tests"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# 1. Verify Docker
if ! command -v docker &>/dev/null; then
    echo "✗ Docker not found. Install Docker Desktop."
    exit 1
fi

if ! docker info &>/dev/null; then
    echo "✗ Docker daemon not running. Start Docker Desktop."
    exit 1
fi

# 2. Start containers
if [[ "$SKIP_DOCKER" == false ]]; then
    echo "Starting Docker containers..."
    docker-compose -f "$FIXTURES_DIR/docker-compose.yml" up -d

    # 3. Wait for health checks
    echo "Waiting for SMB (port 445)..."
    for i in $(seq 1 30); do
        if nc -z 127.0.0.1 445 2>/dev/null; then
            echo "  SMB ready"
            break
        fi
        if [[ $i -eq 30 ]]; then
            echo "✗ SMB timeout"
            docker-compose -f "$FIXTURES_DIR/docker-compose.yml" down
            exit 1
        fi
        sleep 1
    done
fi

# 4. Run tests
echo "Running integration tests..."
TEST_CMD="swift test"
if [[ -n "$FILTER" ]]; then
    TEST_CMD="$TEST_CMD --filter $FILTER"
    echo "Filter: $FILTER"
fi

export SMB_SERVER="smb://127.0.0.1"
export SMB_SHARE="testshare"
export SMB_USER="testuser"
export SMB_PASSWORD="testpass"

TEST_EXIT_CODE=0
if [[ $VERBOSITY -eq 1 ]]; then
    $TEST_CMD 2>&1 || TEST_EXIT_CODE=$?
else
    OUTPUT=$($TEST_CMD 2>&1) || TEST_EXIT_CODE=$?
    # Parse results
    PASSED=$(echo "$OUTPUT" | grep -c "' passed " 2>/dev/null || true)
    FAILED=$(echo "$OUTPUT" | grep -c "' failed " 2>/dev/null || true)
    SKIPPED=$(echo "$OUTPUT" | grep -c "' skipped " 2>/dev/null || true)
fi

# 5. Always stop containers
if [[ "$SKIP_DOCKER" == false ]]; then
    echo "Stopping Docker containers..."
    docker-compose -f "$FIXTURES_DIR/docker-compose.yml" down -v
fi

# 6. Report and exit
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [[ $VERBOSITY -eq 0 ]]; then
    if [[ "$FAILED" -eq 0 && "$PASSED" -gt 0 ]]; then
        echo "✓ $PASSED passed, $SKIPPED skipped"
    elif [[ "$FAILED" -gt 0 ]]; then
        echo "✗ $PASSED passed, $FAILED failed, $SKIPPED skipped"
        echo ""
        echo "Failed tests:"
        echo "$OUTPUT" | grep "' failed " | sed "s/^[^']*'\([^']*\)'.*/  ✗ \1/" || true
    else
        echo "⚠ No test results found"
        echo "$OUTPUT" | tail -5
    fi
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
exit $TEST_EXIT_CODE
