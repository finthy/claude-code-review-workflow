# Claude 自动 Code Review

> 往 PR 推代码 → 自动审查 → 结果贴到 PR 页面对应行。跟人 review 一样精准。

## 部署（2 分钟）

### 1. 拿到 API Key
打开 https://console.anthropic.com/keys → Create Key → 复制

### 2. 配 Secret
仓库 → Settings → Secrets and variables → Actions → New secret
- Name: `ANTHROPIC_API_KEY`
- Value: 刚复制的 key

### 3. 放文件
把下面两个文件放进仓库根目录

**`.github/workflows/claude-review.yml`**

```yaml
name: Claude Code Review

on:
  pull_request:
    types: [opened, synchronize]
    paths-ignore:
      - '*.lock' '*.json' '*.md' '*.txt' '*.yml' '*.yaml'
      - '*.svg' '*.png' '*.jpg' '*.gif' '*.ico' '*.woff*'
      - 'dist/**' 'build/**' 'node_modules/**' '.github/**'

permissions:
  pull-requests: write
  contents: read

jobs:
  review:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with: { fetch-depth: 0 }
      - uses: actions/setup-node@v4
        with: { node-version: '20' }
      - run: npm install -g @anthropic-ai/claude-code
      - env:
          ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
          GITHUB_REPOSITORY: ${{ github.repository }}
          PR_NUMBER: ${{ github.event.pull_request.number }}
          BASE_REF: ${{ github.event.pull_request.base.ref }}
          HEAD_SHA: ${{ github.event.pull_request.head.sha }}
          GH_TOKEN: ${{ github.token }}
          CLAUDE_MODEL: claude-opus-4-7
        run: bash .github/scripts/review.sh
```

**`.github/scripts/review.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail

MODEL="${CLAUDE_MODEL:-claude-opus-4-7}"
REPO="${GITHUB_REPOSITORY:-}"
PR_NUMBER="${PR_NUMBER:-}"
BASE_REF="${BASE_REF:-main}"
HEAD_SHA="${HEAD_SHA:-}"

if [[ -z "${ANTHROPIC_API_KEY:-}" || -z "$REPO" || -z "$PR_NUMBER" ]]; then
  echo "ERROR: missing required env vars"
  exit 1
fi

echo "[*] Reviewing ${REPO}#${PR_NUMBER} [gstack | ${MODEL}]"

CHECKLIST='## Review Checklist (gstack two-pass)

### Pass 1 — CRITICAL (blocking)
**SQL & Data Safety** — String interpolation in SQL, TOCTOU races, N+1 queries, missing transactions
**Race Conditions** — Read-check-write without uniqueness, find-or-create without unique index, atomic status transitions
**Injection & Trust** — Unsanitized input to eval/exec/template, missing auth/authz, hardcoded secrets

### Pass 2 — INFORMATIONAL (non-blocking)
**Conditional Side Effects** — Side effects forgotten on one branch
**Dead Code** — Variables assigned but never read, stale comments
**Error Handling** — Swallowed errors, missing cleanup/rollback
**Test Gaps** — Security features without tests, missing negative-path tests
**Performance** — N+1 queries, expensive ops in loops, missing pagination
**API Contracts** — Breaking changes without versioning, schema mismatches
**Crypto** — Non-crypto RNG for security values, non-constant-time comparison
**Type Coercion** — Values crossing serialization boundaries where type could change

### Suppressions: NO style nits, NO naming conventions, NO "add a comment", NO formatting changes'

prompt=$(cat <<PROMPT
You are an expert code reviewer. Perform a two-pass pre-landing review using the gstack methodology.

## Repository: ${REPO} | PR #${PR_NUMBER} | Head: ${HEAD_SHA}

${CHECKLIST}

## Rules
- Read the FULL diff first. Do NOT flag issues already addressed.
- Use Read/Grep/Glob to explore source files for context — avoid false positives.
- ONLY flag issues in files and lines in the diff.
- Be terse: one line problem, one line fix. No preamble.
- Respect suppressions.

## Steps

### 1. Get the diff
\`\`\`
git fetch origin ${BASE_REF} --quiet 2>/dev/null
git diff origin/${BASE_REF} -- . ':!package-lock.json' ':!*.lock' ':!dist/**' ':!build/**'
\`\`\`

### 2. Read source files for context
For any suspicious change, use Read to see the full file. Check callers/callees, error paths, concurrency patterns.

### 3. Two-pass review
Pass 1 — CRITICAL (SQL, race, injection). Pass 2 — INFORMATIONAL (everything else).

### 4. Post inline comments on exact lines
For EVERY issue, run:
\`\`\`
gh api repos/${REPO}/pulls/${PR_NUMBER}/comments \
  -f body="**[CRITICAL]** or **[INFO]**: <problem>"$'\\n'$"Fix: <fix>" \
  -f commit_id="${HEAD_SHA}" \
  -f path="<file_path>" \
  -f line=<line_number>
\`\`\`

### 5. Post summary
\`\`\`
gh api repos/${REPO}/issues/${PR_NUMBER}/comments -f body="<summary>"
\`\`\`
Start with **Request changes** (any CRITICAL), **Approve with comments** (only INFO), or **LGTM** (no issues).
Format: \`Review: N issues (X critical, Y informational)\` then bullet list with [file:line].
PROMPT
)

echo "[*] Running Claude (${#prompt} chars)..."
echo "$prompt" | claude -p --model "$MODEL" --max-budget-usd 5 \
  --allowedTools "Bash(gh:*)" "Bash(git:*)" "Bash(jq:*)" "Read" "Grep" "Glob" 2>&1
```

### 4. Push

```bash
git add .github/
git commit -m "Add Claude automated code review"
git push
```

## 效果

```
PR 页面 ↓

┌─ Files changed ──────────────────────────────┐
│ src/auth.ts:42                               │
│ └ 💬 [CRITICAL] Missing error handling...    │  ← inline comment
│ src/api.ts:88                                │
│ └ 💬 [INFO] N+1 query in loop...             │  ← inline comment
├─ Conversation ───────────────────────────────┤
│ 🤖 Claude Code Review                        │
│    Review: 3 issues (1 critical, 2 info)     │  ← 总结
└──────────────────────────────────────────────┘
```

## 自定义

| 改什么 | 改哪里 |
|--------|--------|
| 换模型（Opus→Sonnet 更快） | workflow 里 `CLAUDE_MODEL: claude-sonnet-4-6` |
| 只审特定语言 | workflow `paths-ignore` 换成 `paths: ['src/**.ts']` |
| 调审查严格度 | 编辑 `CHECKLIST`，增删审查类别 |
| 大 PR 跳过 | workflow 加 `if: github.event.pull_request.changed_files < 100` |

## 常见问题

**要钱吗？** 一次 review 约 $0.05～0.50，新用户有免费额度。

**重复评论？** 每次 push 都会重新审。如果 Claude 找到之前说过的问题会再提一次，所以尽量修复后再 push。

**token 安全吗？** Key 存在 GitHub Secrets 里，日志不会打印，外部不可见。
