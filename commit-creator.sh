#!/usr/bin/env bash

set -euo pipefail

run_command() {
    local cmd="$1"
    local capture_output="${2:-false}"
    local check="${3:-true}"
    
    if [[ "$capture_output" == "true" ]]; then
        local output
        output=$(eval "$cmd" 2>&1) || {
            local exit_code=$?
            if [[ "$check" == "true" ]]; then
                return $exit_code
            fi
        }
        echo "$output"
    else
        eval "$cmd" || {
            local exit_code=$?
            if [[ "$check" == "true" ]]; then
                return $exit_code
            fi
            return $exit_code
        }
    fi
}

check_required_executables() {
    local missing=()
    
    if ! command -v git &> /dev/null; then
        missing+=("  - git: Git is required for version control operations")
    fi
    
    if ! command -v tree &> /dev/null; then
        missing+=("  - tree: tree is required for displaying project structure")
    fi
    
    if ! command -v context-composer &> /dev/null; then
        missing+=("  - context-composer: context-composer is required for generating commit context")
    fi
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "Error: Required executables are missing:" >&2
        printf '%s\n' "${missing[@]}" >&2
        echo -e "\nPlease install the missing executables before running this script." >&2
        exit 1
    fi
}

ensure_git_repository() {
    if ! git rev-parse --git-dir &> /dev/null; then
        echo "Error: Not in a git repository" >&2
        exit 1
    fi
}

format_code() {
    if [[ -f "./package.json" ]]; then
        echo "Formatting with pnpm..." >&2
        if ! pnpm format >&2 2>&1; then
            echo "Error: Code formatting failed" >&2
            exit 1
        fi
    elif [[ -f "./Makefile" ]]; then
        echo "Formatting with make..." >&2
        if ! make format >&2 2>&1; then
            echo "Error: Code formatting failed" >&2
            exit 1
        fi
    else
        echo "No formatting configuration found (package.json or Makefile)" >&2
    fi
}

check_staged_changes() {
    local staged_files
    staged_files=$(git diff --cached --name-only)
    [[ -n "$staged_files" ]]
}

stage_all_changes_and_verify() {
    echo "Adding all files to git..." >&2
    git add .
    
    if ! check_staged_changes; then
        echo "There is nothing to commit."
        exit 1
    fi
}

run_tests() {
    if [[ -f "./package.json" ]]; then
        if npx js-yaml package.json 2>/dev/null | jq -e '.scripts.test' &> /dev/null; then
            echo "Running tests with npm test..." >&2
            if ! pnpm test; then
                echo "Error: Tests failed" >&2
                exit 1
            fi
        else
            echo "No test script found in package.json" >&2
        fi
    elif [[ -f "./pyproject.toml" ]]; then
        if grep -q "pytest" ./pyproject.toml; then
            echo "Running tests with uv run pytest..." >&2
            if ! uv run pytest; then
                echo "Error: Tests failed" >&2
                exit 1
            fi
        else
            echo "No pytest configuration found in pyproject.toml" >&2
        fi
    else
        echo "No test configuration found" >&2
    fi
}

create_toolset_file() {
    local tmpfile
    tmpfile=$(mktemp /tmp/toolset.XXXXXX.yaml)
    
    cat > "$tmpfile" << 'EOF'
allowed:
  - mcp__commit-composer__git_commit
  - mcp__commit-composer__git_push
  - mcp__commit-composer__ensure_remote

mcp:
  commit-composer:
    type: stdio
    command: commit-composer-mcp
EOF
    
    echo "$tmpfile"
}

get_prompt() {
    context-composer show commit-composer
}

run_claude_composer() {
    local context="$1"
    local toolset_path
    toolset_path=$(create_toolset_file)
    
    # Ensure cleanup on exit
    trap "rm -f '$toolset_path'" EXIT
    
    echo "$context" | claude-composer \
        --toolset "$toolset_path" \
        --dangerously-allow-in-dirty-directory \
        --print \
        --verbose \
        --output-format stream-json \
        --model sonnet \
        | while IFS= read -r line; do
            if [[ -n "$line" ]]; then
                echo "$line" | jq . 2>/dev/null || echo "$line"
            fi
        done
    
    local exit_code=${PIPESTATUS[1]}
    rm -f "$toolset_path"
    
    if [[ $exit_code -ne 0 ]]; then
        exit $exit_code
    fi
}

show_commit_summary() {
    git --no-pager show --stat
}

commit_creator() {
    check_required_executables
    ensure_git_repository
    format_code
    stage_all_changes_and_verify
    run_tests
    
    local prompt
    prompt=$(get_prompt)
    
    run_claude_composer "$prompt"
    show_commit_summary
}

commit_creator
