#!/usr/bin/env bash
set -euo pipefail

# ─── Config ───────────────────────────────────────────────────────────────
MODEL="${CLAUDE_MODEL:-claude-sonnet-4-6}"
API_URL="https://api.anthropic.com/v1/messages"
MAX_TOKENS=4096
CHECKLIST='## Review Checklist

### Pass 1 — CRITICAL (blocking)

**SQL & Data Safety**
- String interpolation in SQL — use parameterized queries
- TOCTOU races: check-then-set without atomic ops
- N+1 queries: missing eager loading in loops
- Missing transaction boundaries around multi-step mutations

**Race Conditions & Concurrency**
- Read-check-write without uniqueness constraint
- Find-or-create on columns without unique index
- Status transitions without atomic compare-and-swap
- Shared mutable state without synchronization

**Injection & Trust Boundaries**
- User data passed to eval/exec/system/template without sanitization
- Missing auth/authz checks on new endpoints
- Hardcoded secrets, credentials, or API keys

### Pass 2 — INFORMATIONAL (non-blocking)

**Error Handling**
- Swallowed errors (caught but not logged/handled)
- Missing error checks on I/O, network, type assertions
- Missing cleanup/rollback on partial failure

**Dead Code & Consistency**
- Variables assigned but never read
- Comments describing old behavior

**Test Gaps**
- Security features without integration tests
- Missing negative-path tests

**Performance**
- N+1 queries or unbounded DB fetches
- Expensive ops inside loops
- Missing pagination on list endpoints

**API Contracts**
- Breaking changes without versioning
- Request/response schema mismatches'
REPO="${GITHUB_REPOSITORY:-}"
PR_NUMBER="${PR_NUMBER:-}"
GH_TOKEN="${GH_TOKEN:-}"

# ─── Check Prerequisites ──────────────────────────────────────────────────
if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
  echo "ERROR: ANTHROPIC_API_KEY not set"
  exit 1
fi

if [[ -z "$REPO" || -z "$PR_NUMBER" ]]; then
  echo "ERROR: GITHUB_REPOSITORY or PR_NUMBER not set"
  exit 1
fi

echo "[*] Reviewing ${REPO}#${PR_NUMBER}"

# ─── Get PR Info ──────────────────────────────────────────────────────────
echo "[*] Fetching PR diff..."
DIFF="$(gh pr diff "$PR_NUMBER" --repo "$REPO" 2>/dev/null)" || {
  echo "ERROR: Cannot get diff for PR #${PR_NUMBER}"
  exit 1
}

if [[ -z "$DIFF" ]]; then
  echo "[*] Empty diff — nothing to review."
  exit 0
fi

HEAD_SHA="$(gh pr view "$PR_NUMBER" --repo "$REPO" --json headRefOid --jq '.headRefOid' 2>/dev/null)"

DIFF_LENGTH=${#DIFF}
echo "[*] Diff: ${DIFF_LENGTH} chars"

# ─── Build Prompt ─────────────────────────────────────────────────────────

read -r -d '' SYSTEM_PROMPT <<'SYSEOF' || true
You are an expert code reviewer performing a pre-landing review. Follow the review checklist provided by the user. Use the gstack two-pass methodology:

- Pass 1: CRITICAL issues (SQL safety, race conditions, injection, auth) — these are BLOCKING.
- Pass 2: INFORMATIONAL issues (error handling, dead code, test gaps, performance, API contracts) — non-blocking.

Rules:
- Be TERSER. One line for problem, one line for fix.
- Do NOT flag issues already addressed in the diff.
- Do NOT flag style preferences, naming nits, or formatting.
- Only flag REAL problems. Skip anything that's fine.
- For each issue, provide exact file path and line number (the NEW line number in the diff).

You MUST respond with a JSON object (no markdown, no backticks, raw JSON only):

{
  "verdict": "request_changes" or "comment" or "approve",
  "summary": "one-line verdict summary",
  "issues": [
    {
      "path": "src/file.ts",
      "line": 42,
      "severity": "critical" or "info",
      "problem": "one line describing the problem",
      "fix": "suggested fix"
    }
  ]
}

If no issues found, return: {"verdict":"approve","summary":"No issues found. LGTM","issues":[]}

Important:
- "request_changes" verdict if ANY critical issue exists.
- "comment" verdict if only informational issues.
- "approve" only if zero issues.
- Line numbers must be from the NEW file (lines starting with + or context lines in the diff).
- ONLY flag issues in files/lines that appear in the diff.
SYSEOF

USER_MESSAGE="## PR Diff (${REPO}#${PR_NUMBER})

\`\`\`diff
${DIFF}
\`\`\`

${CHECKLIST}

Review this PR diff. Output raw JSON only."

# ─── Call Anthropic API ───────────────────────────────────────────────────

echo "[*] Sending to Claude (model: ${MODEL})..."

# Escape special chars for JSON
SYSTEM_PROMPT_ESCAPED="$(echo "$SYSTEM_PROMPT" | jq -Rs .)"
USER_MESSAGE_ESCAPED="$(echo "$USER_MESSAGE" | jq -Rs .)"

BODY="$(cat <<BOD
{
  "model": "${MODEL}",
  "max_tokens": ${MAX_TOKENS},
  "system": ${SYSTEM_PROMPT_ESCAPED},
  "messages": [
    {"role": "user", "content": ${USER_MESSAGE_ESCAPED}}
  ]
}
BOD
)"

RESPONSE="$(curl -s -X POST "$API_URL" \
  -H "x-api-key: ${ANTHROPIC_API_KEY}" \
  -H "anthropic-version: 2023-06-01" \
  -H "content-type: application/json" \
  -d "$BODY" 2>/dev/null)" || {
  echo "ERROR: API call failed"
  exit 1
}

# Check for API error
if echo "$RESPONSE" | jq -e '.error' >/dev/null 2>&1; then
  echo "ERROR: API error — $(echo "$RESPONSE" | jq -r '.error.message')"
  exit 1
fi

# ─── Parse Response ───────────────────────────────────────────────────────

REVIEW_JSON="$(echo "$RESPONSE" | jq -r '.content[0].text // empty' 2>/dev/null)"

if [[ -z "$REVIEW_JSON" ]]; then
  echo "ERROR: Empty response from Claude"
  echo "Raw: $RESPONSE" | head -c 500
  exit 1
fi

echo "[*] Review received: $(echo "$REVIEW_JSON" | head -c 200)"

# ─── Validate JSON ────────────────────────────────────────────────────────

VERDICT="$(echo "$REVIEW_JSON" | jq -r '.verdict // empty' 2>/dev/null)"
if [[ -z "$VERDICT" ]]; then
  echo "ERROR: Cannot parse review JSON"
  echo "Response: $REVIEW_JSON" | head -c 1000
  exit 1
fi

SUMMARY="$(echo "$REVIEW_JSON" | jq -r '.summary // ""' 2>/dev/null)"
ISSUE_COUNT="$(echo "$REVIEW_JSON" | jq -r '.issues | length' 2>/dev/null)"

echo "[*] Verdict: ${VERDICT}, Issues: ${ISSUE_COUNT}"

# ─── Exit early if LGTM ───────────────────────────────────────────────────

if [[ "$VERDICT" == "approve" && "$ISSUE_COUNT" == "0" ]]; then
  echo "[*] No issues found. Posting approval comment."
  gh pr review "$PR_NUMBER" --repo "$REPO" --approve --body "$(cat <<EOF
## Claude Code Review

${SUMMARY}
EOF
)" 2>/dev/null || echo "[!] Could not post review (may need different token permissions)"
  echo "[+] Done."
  exit 0
fi

# ─── Post Inline Comments ──────────────────────────────────────────────────

# Map verdict to review event
case "$VERDICT" in
  request_changes) EVENT="REQUEST_CHANGES" ;;
  approve)         EVENT="APPROVE" ;;
  *)               EVENT="COMMENT" ;;
esac

echo "[*] Posting review with ${ISSUE_COUNT} inline comments..."

# Build review summary body
REVIEW_BODY="## Claude Code Review

**${SUMMARY}**

| Severity | Count |
|----------|-------|
"

CRITICAL_COUNT="$(echo "$REVIEW_JSON" | jq -r '[.issues[] | select(.severity == "critical")] | length' 2>/dev/null)"
INFO_COUNT="$(echo "$REVIEW_JSON" | jq -r '[.issues[] | select(.severity == "info")] | length' 2>/dev/null)"
REVIEW_BODY="${REVIEW_BODY}| Critical | ${CRITICAL_COUNT} |
| Info | ${INFO_COUNT} |
"

# Build comments JSON array for inline comments
COMMENTS_JSON="$(echo "$REVIEW_JSON" | jq -c '[.issues[] | {
  path: .path,
  line: .line,
  body: ("**\(.severity | ascii_upcase)** \(.problem)\n\nFix: \(.fix)")
}]' 2>/dev/null)"

if [[ -z "$COMMENTS_JSON" || "$COMMENTS_JSON" == "[]" ]]; then
  # No inline comments — just post a summary
  echo "[*] No inline comments to post — summary only."
  gh pr review "$PR_NUMBER" --repo "$REPO" "--${EVENT,,}" --body "$REVIEW_BODY" 2>/dev/null || {
    echo "[!] Could not post review. Trying comment instead."
    gh pr comment "$PR_NUMBER" --repo "$REPO" --body "$REVIEW_BODY" 2>/dev/null || echo "[!] Failed."
  }
else
  # Post review with inline comments
  gh api "repos/${REPO}/pulls/${PR_NUMBER}/reviews" \
    -f body="$REVIEW_BODY" \
    -f event="$EVENT" \
    -f comments="$COMMENTS_JSON" 2>/dev/null || {
    echo "[!] Could not post review with inline comments. Trying individual comments..."
    # Fallback: post as a single summary comment
    gh pr comment "$PR_NUMBER" --repo "$REPO" --body "$REVIEW_BODY" 2>/dev/null || echo "[!] Failed."
  }
fi

echo "[+] Review posted: ${VERDICT} — ${ISSUE_COUNT} issues"
