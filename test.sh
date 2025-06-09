#!/usr/bin/env bash

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMIT_CREATOR_SCRIPT="$SCRIPT_DIR/commit-creator.sh"

TEST_DIR=""

cleanup() {
    if [[ -n "$TEST_DIR" && -d "$TEST_DIR" ]]; then
        echo -e "${YELLOW}Cleaning up test directory: $TEST_DIR${NC}"
        rm -rf "$TEST_DIR"
    fi
}

trap cleanup EXIT INT TERM

error() {
    echo -e "${RED}Error: $1${NC}" >&2
    exit 1
}

success() {
    echo -e "${GREEN}✓ $1${NC}"
}

info() {
    echo -e "${YELLOW}→ $1${NC}"
}

if [[ ! -f "$COMMIT_CREATOR_SCRIPT" ]]; then
    error "commit-creator.sh not found at $COMMIT_CREATOR_SCRIPT"
fi

check_dependencies() {
    local missing=()
    
    for cmd in git tree jq; do
        if ! command -v "$cmd" &> /dev/null; then
            missing+=("$cmd")
        fi
    done
    
    local claude_executable="${CLAUDE_EXECUTABLE:-$HOME/.claude/local/claude}"
    if [[ ! -x "$claude_executable" ]]; then
        missing+=("claude (expected at $claude_executable)")
    fi
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing required dependencies: ${missing[*]}"
    fi
    
    success "All required dependencies are installed"
}

create_test_repo() {
    TEST_DIR=$(mktemp -d /tmp/commit-creator-test.XXXXXX)
    info "Created test directory: $TEST_DIR"
    
    cd "$TEST_DIR"
    
    git init
    success "Initialized git repository"
    
    git config user.email "test@example.com"
    git config user.name "Test User"
    success "Configured git user"
}

create_initial_commit() {
    echo "Created on: $(date)" > test-file.txt
    success "Created test-file.txt with initial date"
    
    cat > package.json << 'EOF'
{
  "name": "test-project",
  "version": "1.0.0",
  "description": "Test project for commit-creator",
  "scripts": {}
}
EOF
    success "Created package.json"
    
    git add .
    git commit -m "Initial commit with test file"
    success "Created initial commit"
    
    echo
    info "Initial commit:"
    git log --oneline -1
}

test_commit_creator() {
    echo "Modified on: $(date)" >> test-file.txt
    success "Added modification date to test-file.txt"
    
    echo
    info "Changes to be committed:"
    git diff
    
    echo
    info "Running commit-creator.sh..."
    
    if "$COMMIT_CREATOR_SCRIPT"; then
        success "commit-creator.sh executed successfully"
    else
        error "commit-creator.sh failed with exit code $?"
    fi
    
    echo
    info "Commits after running commit-creator:"
    git log --oneline
    
    local commit_count=$(git rev-list --count HEAD)
    if [[ $commit_count -gt 1 ]]; then
        success "New commit was created (total commits: $commit_count)"
    else
        error "No new commit was created"
    fi
    
    echo
    info "Latest commit details:"
    git show --stat
}

main() {
    echo "=== Commit Creator Integration Test ==="
    echo
    
    check_dependencies
    echo
    
    create_test_repo
    echo
    
    create_initial_commit
    echo
    
    test_commit_creator
    echo
    
    success "All tests passed!"
    echo
    info "Test repository location: $TEST_DIR"
    info "Test completed. Temporary directory will be cleaned up."
}

main
