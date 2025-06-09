#!/usr/bin/env bash

set -euo pipefail

CLAUDE_EXECUTABLE="${CLAUDE_EXECUTABLE:-$HOME/.claude/local/claude}"


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
        if jq -e '.scripts.format' package.json &> /dev/null; then
            echo "Formatting with pnpm..." >&2
            if ! pnpm run format >&2 2>&1; then
                echo "Error: Code formatting failed" >&2
                exit 1
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
Here's your prompt with three carefully selected additions to make the list more complete, while preserving the structure and tone:

---

All changes are in the working tree and all context to create a commit message are in the conversation.
Follow these instructions step-by-step:

* Perform a safety and security check of the current repo changes
* Look for the following unsafe scenarios:

  * Suspicious files or changes
  * Any credentials are present
  * Files are committed that should be ignored
  * Binaries are committed
  * Secrets accidentally embedded in code (e.g., API keys, tokens)
  * Executable scripts without shebang or unexpected permissions
  * Unexpected changes to configuration or dependency files (e.g., package-lock.json, requirements.txt)
* When complete save file with the contents of the security check 
  * If no unsafe scenarios are present, save the summary as ./SUCCEEDED-SECURITY-CHECK.txt
  * If unsafe scenarios are present, save the summary as ./FAILED-SECURITY-CHECK.txt
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
        exit $exit_code
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
                echo "Error: Claude returned an error result" >&2
                rm -f "$output_file"
                exit 1
            else
                echo "Error: Invalid response format from Claude" >&2
                rm -f "$output_file"
                exit 1
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
        echo "No origin remote found. Creating GitHub repository..." >&2
        
        local repo_name=$(basename "$(pwd)")
        
        if ! command -v gh &> /dev/null; then
            echo "Error: GitHub CLI (gh) is not installed. Please install it to create a remote repository." >&2
            echo "Commit was created successfully but not pushed." >&2
            return 1
        fi
        
        if ! gh auth status &> /dev/null; then
            echo "Error: GitHub CLI is not authenticated. Please run 'gh auth login' first." >&2
            echo "Commit was created successfully but not pushed." >&2
            return 1
        fi
        
        echo "Creating private GitHub repository: $repo_name" >&2
        if gh repo create "$repo_name" --private --source=. --remote=origin --push; then
            echo "Repository created and pushed successfully!" >&2
        else
            echo "Error: Failed to create GitHub repository" >&2
            echo "Commit was created successfully but not pushed." >&2
            return 1
        fi
    else
        echo "Pushing to origin..." >&2
        local current_branch=$(git rev-parse --abbrev-ref HEAD)
        if git push -u origin "$current_branch"; then
            echo "Pushed successfully!" >&2
        else
            echo "Error: Failed to push to origin" >&2
            echo "Commit was created successfully but not pushed." >&2
            return 1
        fi
    fi
}

commit_creator() {
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
            exit 1
        fi
        
        if [[ ! -f "./SUCCEEDED-SECURITY-CHECK.txt" ]]; then
            echo "Error: Security check did not complete successfully!" >&2
            echo "Missing ./SUCCEEDED-SECURITY-CHECK.txt file" >&2
            exit 1
        fi
        
        rm -f "./SUCCEEDED-SECURITY-CHECK.txt"
        echo "Security check passed." >&2
        
        echo "Generating commit message..." >&2
        local create_commit_prompt
        create_commit_prompt=$(get_create_commit_prompt)
        local commit_message
        commit_message=$(run_claude "$create_commit_prompt" "true" "true")
        
        if [[ -z "$commit_message" ]]; then
            echo "Error: No commit message was generated!" >&2
            exit 1
        fi
        
        echo "Creating commit with message:" >&2
        echo "$commit_message" >&2
        
        if git commit -m "$commit_message"; then
            echo "Commit created successfully!" >&2
            show_commit_summary
            echo >&2
            setup_remote_and_push
        else
            echo "Error: Failed to create commit!" >&2
            exit 1
        fi
    else
        echo "No changes to commit. Ensuring repository is pushed to GitHub..." >&2
        setup_remote_and_push
    fi
}

commit_creator
