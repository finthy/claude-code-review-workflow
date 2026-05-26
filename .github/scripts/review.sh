#!/usr/bin/env bash
set -euo pipefail

MODEL="${CLAUDE_MODEL:-deepseek-v4-pro[1m]}"
REPO="${GITHUB_REPOSITORY:-}"
PR_NUMBER="${PR_NUMBER:-}"
BASE_REF="${BASE_REF:-main}"
HEAD_SHA="${HEAD_SHA:-}"
MAX_BUDGET="${MAX_BUDGET:-5}"

if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
  echo "ERROR: ANTHROPIC_API_KEY not set"
  exit 1
fi
if [[ -z "$REPO" || -z "$PR_NUMBER" ]]; then
  echo "ERROR: GITHUB_REPOSITORY or PR_NUMBER not set"
  exit 1
fi

echo "[*] Reviewing ${REPO}#${PR_NUMBER} [gstack mode, model: ${MODEL}]"
echo "[*] Base ref: ${BASE_REF}"

# ─── Build GStack Prompt (based on claude-code-reviewer gstack methodology) ──

CHECKLIST='## Review Checklist

Based on [gstack](https://github.com/garrytan/gstack) review methodology.

### Pass 1 — CRITICAL (blocking)

**SQL & Data Safety**
- String interpolation/concatenation in SQL — use parameterized queries or prepared statements
- TOCTOU races: check-then-set patterns that should be atomic operations
- N+1 queries: missing eager loading for associations used in loops
- Missing transaction boundaries around multi-step data mutations

**Race Conditions & Concurrency**
- Read-check-write without uniqueness constraint or conflict handling
- Find-or-create patterns on columns without unique index — concurrent calls can create duplicates
- Status transitions without atomic compare-and-swap — concurrent updates can skip or double-apply
- Shared mutable state accessed without synchronization (locks, mutexes, channels)

**Injection & Trust Boundaries**
- User-controlled data passed to html_safe/raw(), eval(), exec(), os.system(), template engines, or shell commands without sanitization
- LLM-generated values written to DB or passed to mailers without format validation
- Missing authentication or authorization checks on new endpoints
- Hardcoded secrets, credentials, or API keys in code

### Pass 2 — INFORMATIONAL (non-blocking)

**Conditional Side Effects**
- Code paths that branch but forget to apply a side effect on one branch, creating inconsistent state

**Magic Numbers & String Coupling**
- Bare numeric literals used in multiple files — should be named constants

**Dead Code & Consistency**
- Variables assigned but never read
- Comments/docstrings that describe old behavior after the code changed

**Error Handling**
- Swallowed errors (caught but not logged, returned, or handled)
- Missing error checks on I/O, network calls, type assertions
- Missing cleanup/rollback on partial failure

**Test Gaps**
- Security enforcement features (blocking, rate limiting, auth) without integration tests
- Negative-path tests that assert type/status but not the side effects

**Performance**
- N+1 queries or unbounded DB fetches
- Expensive operations inside loops (allocations, API calls, regex compilation)
- Missing pagination on list endpoints

**API Contracts**
- Breaking changes to public APIs without versioning
- Request/response schema mismatches
- Missing validation on required fields

**Crypto & Entropy**
- Truncation of data instead of hashing — less entropy, easier collisions
- rand() / Math.random() for security-sensitive values — use crypto-secure RNG

**Time Window Safety**
- Date-key lookups that assume "today" covers 24h — a report at 8am only sees midnight→8am

**Type Coercion at Boundaries**
- Values crossing language/serialization boundaries where type could change

---
## Suppressions — DO NOT flag these

- Style preferences, naming conventions, or nitpicks
- "Add a comment explaining why" — thresholds change during tuning, comments rot
- Redundant checks that aid readability
- Consistency-only changes (reformatting, wrapping a value to match another constant)
- Harmless no-ops
- ANYTHING already addressed in the diff being reviewed — read the FULL diff before commenting'

prompt=$(cat <<PROMPT
You are a code reviewer performing a pre-landing review using the gstack two-pass methodology. Analyze this branch's diff for structural issues that tests don't catch.

## Repository: ${REPO}
## PR #${PR_NUMBER}
## Head SHA: ${HEAD_SHA}

${CHECKLIST}

## Important Rules
- **Read the FULL diff before commenting.** Do not flag issues already addressed in the diff.
- **Use Read/Grep/Glob to read source files for context** — this avoids false positives. If the diff shows a change that interacts with other code, read those source files to understand the full picture.
- **ONLY review files and lines in the diff.** Do NOT report issues in other files, even if you read them for context.
- **Read-only by default.** Do not modify any files. Only post comments.
- **Be terse.** One line problem, one line fix. No preamble, no "looks good overall."
- **Only flag real problems.** Skip anything that's fine.
- **Respect suppressions.** Do NOT flag items listed in the "DO NOT flag" section.

## Instructions

### Step 1: Get the diff
Run these commands to get a fresh diff against the base branch:
\`\`\`
git fetch origin ${BASE_REF} --quiet 2>/dev/null
git diff origin/${BASE_REF} -- . ':!package-lock.json' ':!*.lock' ':!dist/**' ':!build/**'
\`\`\`

### Step 2: Read source files for context
For any files with changes that look potentially problematic, read the full file (not just the diff hunks) using the Read tool to understand the surrounding code. This helps avoid false positives. Focus on:
- Functions that touch databases, authentication, or external services
- Error handling and recovery paths
- Concurrency patterns (goroutines, threads, async)
- Callers and callees of changed functions

### Step 3: Two-pass review
Apply the checklist against the diff in two passes:
1. **Pass 1 (CRITICAL):** SQL & Data Safety, Race Conditions & Concurrency, Injection & Trust Boundaries
2. **Pass 2 (INFORMATIONAL):** Everything else in the checklist

### Step 4: Post INLINE Comments on Specific Lines
CRITICAL: For EVERY issue you find, post it as an inline comment on the exact line of code where the issue occurs.

**For each issue, run this command:**
\`\`\`
gh api repos/${REPO}/pulls/${PR_NUMBER}/comments \\
  -f body="**[CRITICAL]** or **[INFO]**: <one-line problem>
Fix: <suggested fix>" \\
  -f commit_id="${HEAD_SHA}" \\
  -f path="<file_path_from_diff>" \\
  -f line=<line_number_in_new_file>
\`\`\`

The \`path\` is from the diff header (\`+++ b/path/to/file.go\` → use \`path/to/file.go\`).
The \`line\` is the line number in the NEW version of the file (lines starting with + or context lines).

### Step 5: Post Summary
After all inline comments are posted, post ONE summary comment with the overall verdict:
\`\`\`
gh api repos/${REPO}/issues/${PR_NUMBER}/comments -f body="<summary>"
\`\`\`

The summary must start with one of: **Request changes** (if any CRITICAL issue), **Approve with comments** (only INFORMATIONAL issues), or **LGTM** (no issues).

Use this format:
\`\`\`
**Request changes** / **Approve with comments** / **LGTM**

Review: N issues (X critical, Y informational)

**CRITICAL** (blocking):
- [file:line] Problem. Fix: suggested fix

**Issues** (non-blocking):
- [file:line] Problem. Fix: suggested fix
\`\`\`
PROMPT
)

# ─── Run Claude (gstack mode — with full tool access) ─────────────────────

echo "[*] Prompt built (${#prompt} chars). Running Claude..."
echo "[*] Claude has access to: Read, Grep, Glob, Bash(git, gh, jq) — full gstack mode"

echo "$prompt" | claude -p \
  --model "$MODEL" \
  --max-budget-usd "$MAX_BUDGET" \
  --allowedTools "Bash(gh:*)" "Bash(git:*)" "Bash(jq:*)" "Read" "Grep" "Glob" \
  2>&1

exit_code=$?

if [[ $exit_code -eq 0 ]]; then
  echo "[+] Claude review completed."
else
  echo "[-] Claude exited with code ${exit_code}."
  exit $exit_code
fi
