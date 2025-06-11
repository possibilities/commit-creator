#!/usr/bin/env bash

set -euo pipefail

CLAUDE_EXECUTABLE="${CLAUDE_EXECUTABLE:-$HOME/.claude/local/claude}"

PROJECT_NAME=$(basename "$(pwd)")
COMMIT_MESSAGE=""

cleanup_security_files() {
    rm -f ./SUCCEEDED-SECURITY-CHECK.txt
}

trap 'cleanup_security_files' EXIT
trap 'error_code=$?; 
      if command -v notify-send &> /dev/null; then 
          notify-send "❌ Error: Commit Not Created" "Project: $PROJECT_NAME\nScript failed at line $LINENO (exit code: $error_code)" --urgency=critical; 
      fi; 
      echo "Error: Script failed at line $LINENO (exit code: $error_code)" >&2; 
      exit $error_code' ERR

error_exit() {
    local message="$1"
    echo "$message" >&2
    if command -v notify-send &> /dev/null; then
        notify-send "❌ Error: Commit Not Created" "Project: $PROJECT_NAME\n$message" --urgency=critical
    fi
    trap - ERR
    exit 1
}


check_required_executables() {
    local missing=()
    
    if ! command -v git &> /dev/null; then
        missing+=("  - git: Git is required for version control operations")
    fi
    
    if ! command -v tree &> /dev/null; then
        missing+=("  - tree: tree is required for displaying project structure")
    fi
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "Error: Required executables are missing:" >&2
        printf '%s\n' "${missing[@]}" >&2
        error_exit "\nPlease install the missing executables before running this script."
    fi
}

ensure_git_repository() {
    if ! git rev-parse --git-dir &> /dev/null; then
        error_exit "Not in a git repository"
    fi
}

format_code() {
    if [[ -f "./package.json" ]]; then
        if jq -e '.scripts.format' package.json &> /dev/null; then
            echo "Formatting with pnpm..." >&2
            if ! pnpm run format >&2 2>&1; then
                error_exit "Code formatting failed"
            fi
        else
            echo "No format script found in package.json" >&2
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
        return 1
    fi
    return 0
}

run_tests() {
    if [[ -f "./package.json" ]]; then
        if jq -e '.scripts.test' package.json &> /dev/null; then
            echo "Running tests with pnpm test..." >&2
            if ! pnpm run test; then
                error_exit "Tests failed"
            fi
        else
            echo "No test script found in package.json" >&2
        fi
    elif [[ -f "./Makefile" ]]; then
        if grep -q "^test:" ./Makefile; then
            echo "Running tests with make test..." >&2
            if ! make test; then
                error_exit "Tests failed"
            fi
        else
            echo "No test target found in Makefile" >&2
        fi
    elif [[ -f "./pyproject.toml" ]]; then
        if grep -q "pytest" ./pyproject.toml; then
            echo "Running tests with uv run pytest..." >&2
            if ! uv run pytest; then
                error_exit "Tests failed"
            fi
        else
            echo "No pytest configuration found in pyproject.toml" >&2
        fi
    else
        echo "No test configuration found" >&2
    fi
}

get_safety_check_prompt() {
    local tree_output=$(tree --gitignore 2>&1 || echo "tree command failed")
    local diff_output=$(git --no-pager diff --cached 2>&1 || echo "git diff failed")
    local status_output=$(git status --porcelain 2>&1 || echo "git status failed")
    
    cat << EOF
<Role>
You are a engineer who is an expert at performing software security checks.
</Role>

<Context>
<Command>
<CommandDescription>
A tree of all repository files and directories
</CommandDescription>
<CommandInput>
tree --gitignore
</CommandInput>
<CommandOutput>
$tree_output
</CommandOutput>
</Command>

<Command>
<CommandDescription>
All staged changes
</CommandDescription>
<CommandInput>
git --no-pager diff --cached
</CommandInput>
<CommandOutput>
$diff_output
</CommandOutput>
</Command>

<Command>
<CommandDescription>
Status of repo changes
</CommandDescription>
<CommandInput>
git status --porcelain
</CommandInput>
<CommandOutput>
$status_output
</CommandOutput>
</Command>
</Context>

<Instructions>
All changes are in the working tree and all context to create a commit message are in the conversation.
Follow these instructions step-by-step:
- Perform a safety and security check of the current repo changes
- Look for the following unsafe scenarios:
  - Suspicious files or changes
  - Any credentials are present
  - Files are committed that should be ignored
  - Binaries are committed
  - Secrets accidentally embedded in code (e.g., API keys, tokens)
  - Executable scripts without shebang or unexpected permissions
  - Unexpected changes to configuration or dependency files (e.g., package-lock.json, requirements.txt)
- When complete save file with the contents of the security check 
  - If no unsafe scenarios are present, save the summary as ./SUCCEEDED-SECURITY-CHECK.txt
  - If unsafe scenarios are present, save the summary as ./FAILED-SECURITY-CHECK.txt
</Instructions>
EOF
}

get_create_commit_prompt() {
    local tree_output=$(tree --gitignore 2>&1 || echo "tree command failed")
    local diff_output=$(git --no-pager diff --cached 2>&1 || echo "git diff failed")
    local status_output=$(git status --porcelain 2>&1 || echo "git status failed")
    
    cat << EOF
<Role>
You are a engineer who is an expert at git and writing commit messages. You are a human making a commit for code written by you, a human.
</Role>

<Rules>
- When writing a commit message summarize the changes
  - Explain _what_ changed and what the effects on users will be
  - **Never** try to explain _why_ the changes were made unless it is explicit in the context
</Rules>

<Context>
<Command>
<CommandDescription>
A tree of all repository files and directories
</CommandDescription>
<CommandInput>
tree --gitignore
</CommandInput>
<CommandOutput>
$tree_output
</CommandOutput>
</Command>

<Command>
<CommandDescription>
All staged changes
</CommandDescription>
<CommandInput>
git --no-pager diff --cached
</CommandInput>
<CommandOutput>
$diff_output
</CommandOutput>
</Command>

<Command>
<CommandDescription>
  Status of repo changes
</CommandDescription>
<CommandInput>
git status --porcelain
</CommandInput>
<CommandOutput>
$status_output
</CommandOutput>
</Command>
</Context>

<Instructions>
All changes are in the working tree and all context to create a commit message are in the conversation. Analyze the changes and respond with ONLY the commit message text - no explanations, no additional commentary, just the commit message itself.
</Instructions>
EOF
}

run_claude() {
    local context="$1"
    local validate_result="${2:-false}"
    local capture_file_content="${3:-false}"
    
    if [[ "$capture_file_content" != "true" ]]; then
        echo '-----' >&2
        echo "$context" >&2
        echo '-----' >&2
    fi
    
    local output_file=$(mktemp)
    
    echo "$context" | "$CLAUDE_EXECUTABLE" \
        --print \
        --verbose \
        --output-format stream-json \
        --allowedTools Write \
        --disallowedTools Read \
        --disallowedTools Bash \
        --disallowedTools Task \
        --disallowedTools Glob \
        --disallowedTools Grep \
        --disallowedTools LS \
        --disallowedTools Edit \
        --disallowedTools MultiEdit \
        --disallowedTools NotebookRead \
        --disallowedTools NotebookEdit \
        --disallowedTools WebFetch \
        --disallowedTools TodoRead \
        --disallowedTools TodoWrite \
        --disallowedTools WebSearch \
        --model sonnet \
        | while IFS= read -r line; do
            if [[ -n "$line" ]]; then
                echo "$line" >> "$output_file"
                if [[ "$capture_file_content" != "true" ]]; then
                    echo "$line" | jq . 2>/dev/null || echo "$line"
                fi
            fi
        done
    
    local exit_code=${PIPESTATUS[1]}
    
    if [[ $exit_code -ne 0 ]]; then
        rm -f "$output_file"
        error_exit "Claude command failed with exit code $exit_code"
    fi
    
    if [[ "$capture_file_content" == "true" ]]; then
        local last_line=$(tail -1 "$output_file")
        local message_content=$(echo "$last_line" | jq -r 'select(.type == "result" and .subtype == "success") | .result')
        if [[ -n "$message_content" && "$message_content" != "null" ]]; then
            echo "$message_content"
        fi
    fi
    
    if [[ "$validate_result" == "true" ]]; then
        local last_line=$(tail -1 "$output_file")
        local result_json=$(echo "$last_line" | jq -r 'select(.type == "result" and .subtype == "success")')
        
        if [[ -z "$result_json" ]]; then
            local error_json=$(echo "$last_line" | jq -r 'select(.type == "result" and .subtype != "success")')
            if [[ -n "$error_json" ]]; then
                rm -f "$output_file"
                error_exit "Claude returned an error result"
            else
                rm -f "$output_file"
                error_exit "Invalid response format from Claude"
            fi
        fi
    fi
    
    rm -f "$output_file"
}

show_commit_summary() {
    git --no-pager show --stat
}

setup_remote_and_push() {
    if ! git remote get-url origin &> /dev/null; then
        echo "No origin remote found. Creating git repository..." >&2
        
        local repo_name=$(basename "$(pwd)")
        
        if ! command -v gh &> /dev/null; then
            error_exit "GitHub CLI (gh) is not installed. Please install it to create a remote repository.\nCommit was created successfully but not pushed."
        fi
        
        if ! gh auth status &> /dev/null; then
            error_exit "GitHub CLI is not authenticated. Please run 'gh auth login' first.\nCommit was created successfully but not pushed."
        fi
        
        echo "Creating private git repository: $repo_name" >&2
        if gh repo create "$repo_name" --private --source=. --remote=origin --push; then
            echo "Repository created and pushed successfully!" >&2
        else
            error_exit "Failed to create git repository.\nCommit was created successfully but not pushed."
        fi
    else
        echo "Pushing to origin..." >&2
        local current_branch=$(git rev-parse --abbrev-ref HEAD)
        if git push -u origin "$current_branch"; then
            echo "Pushed successfully!" >&2
        else
            error_exit "Failed to push to origin.\nCommit was created successfully but not pushed."
        fi
    fi
}

commit_creator() {
    rm -f ./SUCCEEDED-SECURITY-CHECK.txt
    
    check_required_executables
    ensure_git_repository
    format_code
    
    if stage_all_changes_and_verify; then
        run_tests
        
        echo "Running security check..." >&2
        local safety_check_prompt
        safety_check_prompt=$(get_safety_check_prompt)
        run_claude "$safety_check_prompt" "true"

        if [[ -f "./FAILED-SECURITY-CHECK.txt" ]]; then
            echo "Error: Security check failed!" >&2
            echo "Security issues found:" >&2
            cat "./FAILED-SECURITY-CHECK.txt" >&2
            rm -f "./FAILED-SECURITY-CHECK.txt"
            error_exit "Security check failed! Check the security issues above."
        fi
        
        if [[ ! -f "./SUCCEEDED-SECURITY-CHECK.txt" ]]; then
            error_exit "Security check did not complete successfully! Missing ./SUCCEEDED-SECURITY-CHECK.txt file"
        fi
        
        rm -f "./SUCCEEDED-SECURITY-CHECK.txt"
        echo "Security check passed." >&2
        
        rm -f "./FAILED-SECURITY-CHECK.txt"
        
        echo "Generating commit message..." >&2
        local create_commit_prompt
        create_commit_prompt=$(get_create_commit_prompt)
        COMMIT_MESSAGE=$(run_claude "$create_commit_prompt" "true" "true")
        
        if [[ -z "$COMMIT_MESSAGE" ]]; then
            error_exit "No commit message was generated!"
        fi
        
        echo "Creating commit with message:" >&2
        echo "$COMMIT_MESSAGE" >&2
        
        if git commit -m "$COMMIT_MESSAGE"; then
            echo "Commit created successfully!" >&2
            echo >&2
            setup_remote_and_push
            if command -v notify-send &> /dev/null; then
                local first_line=$(echo "$COMMIT_MESSAGE" | head -n1)
                notify-send "✅ Commit Created" "Project: $PROJECT_NAME\n$first_line" --urgency=critical
            fi
            show_commit_summary
        else
            error_exit "Failed to create commit!"
        fi
    else
        echo "No changes to commit. Ensuring repository is pushed to git repo..." >&2
        setup_remote_and_push
        if command -v notify-send &> /dev/null; then
            notify-send "✅ Commit Created" "Project: $PROJECT_NAME\nRepository synced with git repo (no new changes)" --urgency=critical
        fi
    fi
}

commit_creator
