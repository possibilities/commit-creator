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

test_commit_creator() {
    # Create new files for the first commit
    echo "# Test Project" > README.md
    echo "This is a test project for commit-creator" >> README.md
    echo "Created on: $(date)" >> README.md
    success "Created README.md"
    
    cat > package.json << 'EOF'
{
  "name": "test-project",
  "version": "1.0.0",
  "description": "Test project for commit-creator first commit",
  "scripts": {}
}
EOF
    success "Created package.json"
    
    echo "console.log('Hello, World!');" > index.js
    success "Created index.js"
    
    # Verify this is a repo with no commits
    if git rev-list --count HEAD &> /dev/null; then
        error "Repository already has commits, but we're testing first commit creation"
    else
        success "Confirmed: Repository has no commits yet"
    fi
    
    echo
    info "Files to be committed:"
    git status --short
    
    echo
    info "Running commit-creator.sh for the first commit..."
    
    if "$COMMIT_CREATOR_SCRIPT"; then
        success "commit-creator.sh executed successfully"
    else
        error "commit-creator.sh failed with exit code $?"
    fi
    
    echo
    info "Commits after running commit-creator:"
    git log --oneline
    
    local commit_count=$(git rev-list --count HEAD)
    if [[ $commit_count -eq 1 ]]; then
        success "First commit was created successfully (total commits: $commit_count)"
    else
        error "Expected exactly 1 commit, but found $commit_count"
    fi
    
    echo
    info "First commit details:"
    git show --stat
}

main() {
    echo "=== Commit Creator First Commit Test ==="
    echo
    
    check_dependencies
    echo
    
    create_test_repo
    echo
    
    test_commit_creator
    echo
    
    success "All tests passed!"
    echo
    info "Test repository location: $TEST_DIR"
    info "Test completed. Temporary directory will be cleaned up."
}

main