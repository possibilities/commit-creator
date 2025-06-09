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
    TEST_DIR=$(mktemp -d /tmp/commit-creator-security-test.XXXXXX)
    info "Created test directory: $TEST_DIR"
    
    cd "$TEST_DIR"
    
    git init
    success "Initialized git repository"
    
    git config user.email "test@example.com"
    git config user.name "Test User"
    success "Configured git user"
}

create_initial_commit() {
    echo "# Security Test Project" > README.md
    echo "This project tests security checks" >> README.md
    
    git add .
    git commit -m "Initial commit"
    success "Created initial commit"
    
    echo
    info "Initial commit:"
    git log --oneline -1
}

create_files_with_credentials() {
    info "Creating files with fake credentials..."
    
    # Create a config file with API keys
    cat > config.json << 'EOF'
{
  "api_key": "sk-1234567890abcdef1234567890abcdef",
  "secret_key": "AKIAIOSFODNN7EXAMPLE",
  "database_url": "postgres://user:password@localhost:5432/mydb"
}
EOF
    success "Created config.json with fake API keys"
    
    # Create .env file with credentials
    cat > .env << 'EOF'
DATABASE_HOST=localhost
DATABASE_USER=admin
DATABASE_PASSWORD=SuperSecretPassword123!
AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE
AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
STRIPE_SECRET_KEY=sk_test_4eC39HqLyjWDarjtT1zdp7dc
EOF
    success "Created .env file with fake credentials"
    
    # Create a source file with hardcoded tokens
    cat > app.js << 'EOF'
const express = require('express');
const app = express();

// Hardcoded API token
const API_TOKEN = "Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c";
const GITHUB_TOKEN = "ghp_1234567890abcdefghijklmnopqrstuvwxyz";

app.get('/', (req, res) => {
  res.send('Hello World!');
});

app.listen(3000);
EOF
    success "Created app.js with hardcoded tokens"
    
    # Create a private key file
    cat > private_key.pem << 'EOF'
-----BEGIN RSA PRIVATE KEY-----
MIIEogIBAAKCAQEA6arGDc4l2xH6JYPYhdNiZJvG+hng6tQQC7g5KKnx5T8Li1aW
TYt3mxQOZEGhKPXZleqg1aOymnGqVXaCK7RqeYU1mfd7WuCr3kLRlWqFfpkfVUgC
fake_private_key_content_for_testing_purposes_only
-----END RSA PRIVATE KEY-----
EOF
    success "Created private_key.pem file"
}

test_security_fail() {
    echo
    info "Changes to be committed:"
    git diff
    
    echo
    info "Running commit-creator.sh (expecting it to fail)..."
    
    # Run commit-creator and expect it to fail
    if "$COMMIT_CREATOR_SCRIPT" 2>&1; then
        error "commit-creator.sh succeeded when it should have failed!"
    else
        local exit_code=$?
        success "commit-creator.sh failed as expected (exit code: $exit_code)"
    fi
    
    # Check if security check file was created
    if [[ -f "./FAILED-SECURITY-CHECK.txt" ]]; then
        success "FAILED-SECURITY-CHECK.txt was created"
        echo
        info "Security check failure details:"
        cat "./FAILED-SECURITY-CHECK.txt"
    else
        # The file might have been cleaned up, but that's okay
        info "FAILED-SECURITY-CHECK.txt was not found (may have been cleaned up)"
    fi
    
    # Verify no new commits were created
    local commit_count=$(git rev-list --count HEAD)
    if [[ $commit_count -eq 1 ]]; then
        success "No new commit was created (as expected)"
    else
        error "Unexpected number of commits: $commit_count"
    fi
}

main() {
    echo "=== Commit Creator Security Fail Test ==="
    echo
    
    check_dependencies
    echo
    
    create_test_repo
    echo
    
    create_initial_commit
    echo
    
    create_files_with_credentials
    echo
    
    test_security_fail
    echo
    
    success "Security test completed successfully!"
    echo
    info "The commit-creator properly detected and rejected credentials"
}

main