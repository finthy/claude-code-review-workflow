# Claude 自动 Code Review 部署指南

## 效果

每次往任意 PR 推送代码，GitHub Actions 自动触发 Claude 进行深度代码审查，审查结果以 **行级评论 + 总结** 的形式贴在 PR 页面上。

> 审查方法论基于 [gstack](https://github.com/garrytan/gstack) 两轮审查：第一轮查严重问题（SQL 安全、竞态条件、注入），第二轮查代码质量（错误处理、死代码、性能）。

---

## 部署步骤（5 分钟）

### 第一步：获取 Anthropic API Key

1. 打开 https://console.anthropic.com/keys
2. 登录或注册 Anthropic 账号（新用户有免费额度）
3. 点击 **Create Key**，复制生成的 key

### 第二步：给仓库加 Secret

1. 打开目标 GitHub 仓库 → **Settings** → **Secrets and variables** → **Actions**
2. 点击 **New repository secret**
   - Name 填：`ANTHROPIC_API_KEY`
   - Value 填：第一步复制的 key
3. 点 **Add secret** 保存

### 第三步：把工作流文件放进仓库

方式一（推荐）：直接复制模板仓库的文件。

```bash
# Clone 模板
git clone https://github.com/finthy/claude-code-review-workflow.git

# 把 .github 文件夹拷贝到你的项目根目录
cp -r claude-code-review-workflow/.github /你的项目路径/

# 提交推送
cd /你的项目路径
git add .github/
git commit -m "Add Claude automated code review"
git push
```

方式二：手动在项目根目录创建以下两个文件。

**`.github/workflows/claude-review.yml`**

```yaml
name: Claude Code Review

on:
  pull_request:
    types: [opened, synchronize]

permissions:
  pull-requests: write
  contents: read

jobs:
  review:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Run Claude Code Review
        env:
          ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
          GITHUB_REPOSITORY: ${{ github.repository }}
          PR_NUMBER: ${{ github.event.pull_request.number }}
          GH_TOKEN: ${{ github.token }}
          CLAUDE_MODEL: claude-sonnet-4-6
        run: |
          bash .github/scripts/review.sh
```

**`.github/scripts/review.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail

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

if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
  echo "ERROR: ANTHROPIC_API_KEY not set"
  exit 1
fi

if [[ -z "$REPO" || -z "$PR_NUMBER" ]]; then
  echo "ERROR: GITHUB_REPOSITORY or PR_NUMBER not set"
  exit 1
fi

echo "[*] Reviewing ${REPO}#${PR_NUMBER}"
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

echo "[*] Sending to Claude (model: ${MODEL})..."

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

if echo "$RESPONSE" | jq -e '.error' >/dev/null 2>&1; then
  echo "ERROR: API error — $(echo "$RESPONSE" | jq -r '.error.message')"
  exit 1
fi

REVIEW_JSON="$(echo "$RESPONSE" | jq -r '.content[0].text // empty' 2>/dev/null)"

if [[ -z "$REVIEW_JSON" ]]; then
  echo "ERROR: Empty response from Claude"
  echo "Raw: $RESPONSE" | head -c 500
  exit 1
fi

echo "[*] Review received: $(echo "$REVIEW_JSON" | head -c 200)"

VERDICT="$(echo "$REVIEW_JSON" | jq -r '.verdict // empty' 2>/dev/null)"
if [[ -z "$VERDICT" ]]; then
  echo "ERROR: Cannot parse review JSON"
  echo "Response: $REVIEW_JSON" | head -c 1000
  exit 1
fi

SUMMARY="$(echo "$REVIEW_JSON" | jq -r '.summary // ""' 2>/dev/null)"
ISSUE_COUNT="$(echo "$REVIEW_JSON" | jq -r '.issues | length' 2>/dev/null)"
echo "[*] Verdict: ${VERDICT}, Issues: ${ISSUE_COUNT}"

if [[ "$VERDICT" == "approve" && "$ISSUE_COUNT" == "0" ]]; then
  echo "[*] No issues found. Posting approval comment."
  gh pr review "$PR_NUMBER" --repo "$REPO" --approve --body "$(cat <<EOF
## Claude Code Review

${SUMMARY}
EOF
)" 2>/dev/null || echo "[!] Could not post review"
  echo "[+] Done."
  exit 0
fi

case "$VERDICT" in
  request_changes) EVENT="REQUEST_CHANGES" ;;
  approve)         EVENT="APPROVE" ;;
  *)               EVENT="COMMENT" ;;
esac

echo "[*] Posting review with ${ISSUE_COUNT} inline comments..."

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

COMMENTS_JSON="$(echo "$REVIEW_JSON" | jq -c '[.issues[] | {
  path: .path,
  line: .line,
  body: ("**\(.severity | ascii_upcase)** \(.problem)\n\nFix: \(.fix)")
}]' 2>/dev/null)"

if [[ -z "$COMMENTS_JSON" || "$COMMENTS_JSON" == "[]" ]]; then
  gh pr review "$PR_NUMBER" --repo "$REPO" "--${EVENT,,}" --body "$REVIEW_BODY" 2>/dev/null || {
    gh pr comment "$PR_NUMBER" --repo "$REPO" --body "$REVIEW_BODY" 2>/dev/null || echo "[!] Failed."
  }
else
  gh api "repos/${REPO}/pulls/${PR_NUMBER}/reviews" \
    -f body="$REVIEW_BODY" \
    -f event="$EVENT" \
    -f comments="$COMMENTS_JSON" 2>/dev/null || {
    gh pr comment "$PR_NUMBER" --repo "$REPO" --body "$REVIEW_BODY" 2>/dev/null || echo "[!] Failed."
  }
fi

echo "[+] Review posted: ${VERDICT} — ${ISSUE_COUNT} issues"
```

---

## 验证

1. 在仓库创建一个 PR
2. 打开 GitHub Actions 页面，应该看到 `Claude Code Review` 正在运行
3. 等待约 30 秒～2 分钟（取决于 diff 大小）
4. PR 页面会出现 Claude 的审查评论

---

## 自定义

| 需求 | 怎么做 |
|------|--------|
| 换模型 | 改 workflow 里的 `CLAUDE_MODEL`（`claude-opus-4-7` 更深入，`claude-haiku-4-5` 更快） |
| 改审查规则 | 编辑 `review.sh` 里的 `CHECKLIST` 变量 |
| 调低门槛只想看严重 bug | 改 System Prompt，要求只输出 CRITICAL |
| 大 PR 跳过不审 | 在 workflow 里加 `if: github.event.pull_request.changed_files < 100` |
| 只审某类文件 | 在 workflow 里加 `paths` 过滤，例如 `paths: ['src/**']` |

---

## 常见问题

**Q: 花费多少？**  
Sonnet 一次 review 约 $0.01～0.10，取决于 diff 大小。Hancu 更便宜。新用户有免费额度。

**Q: 会不会重复审查？**  
不会。只有 PR 新建（opened）和推送新代码（synchronize）时触发。

**Q: API key 安全吗？**  
存在 GitHub Secrets 里，Actions 日志中不会打印出来，其他人看不到。

**Q: 失败了怎么办？**  
GitHub Actions 页面会显示失败日志，通常是 API key 过期或网络问题。

---

## 模板仓库

https://github.com/finthy/claude-code-review-workflow
