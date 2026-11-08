---
name: explain-pr
description: "Walk through a PR: what changed, why, risks, and agent decisions. Read-only; never writes markers or merges. Optional comprehension quiz."
argument-hint: "<pr-number> [--quiz]"
allowed-tools: Bash, Read, Grep, Glob, AskUserQuestion
---

Writing: read docs/skills/shared/writing-rule.md before you write a durable artifact.

# /explain-pr — Explain a pull request

Read-only walkthrough of a PR for the operator. It never writes an approval marker and never merges.

## Process

### 1. Parse the PR number and flags

Extract the PR number from `$ARGUMENTS`. Infer from the current branch open PR when omitted.
Resolve `REPO` from `owner/repo#N` or `git remote get-url origin`.
Recognise `--quiz` for an optional comprehension check at the end.

### 2. Resolve the ops root

Use the same ops-root walk as `/approve-merge` step 3 so the quiz helper loads from the fork.

```bash
OPS_ROOT=""
PIN_FILE="${APEXYARD_OPS_PIN_DIR:-$HOME/.claude/apexyard}/ops-root-${CLAUDE_CODE_SESSION_ID:-}"
if [ -z "${APEXYARD_OPS_DISABLE_PIN:-}" ] && [ -n "${CLAUDE_CODE_SESSION_ID:-}" ] && [ -f "$PIN_FILE" ]; then
  IFS= read -r OPS_ROOT < "$PIN_FILE" || OPS_ROOT=""
fi
if [ -n "$OPS_ROOT" ] && [ ! -f "$OPS_ROOT/.apexyard-fork" ] && \
   { [ ! -f "$OPS_ROOT/onboarding.yaml" ] || [ ! -f "$OPS_ROOT/apexyard.projects.yaml" ]; }; then
  OPS_ROOT=""
fi
if [ -z "$OPS_ROOT" ]; then
  r=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
  while [ -n "$r" ] && [ "$r" != "/" ]; do
    if [ -f "$r/.apexyard-fork" ] || { [ -f "$r/onboarding.yaml" ] && [ -f "$r/apexyard.projects.yaml" ]; }; then
      OPS_ROOT="$r"; break
    fi
    r=$(dirname "$r")
  done
fi
MARKER_HOME="${OPS_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
```

### 3. Load the PR

```bash
gh pr view <pr> --repo "$REPO" --json title,body,baseRefName,headRefName,files,commits
gh pr diff <pr> --repo "$REPO"
```

Stop on a failed read. Do not invent facts outside the PR title, body, diff, and linked ticket text named in the body.

### 4. Explain

Report four short sections in this order:

1. What changed — files and the main edits, with file names.
2. Why — the reason from the PR body and any linked ticket text in that body.
3. Risky parts — trust-chain, data, migrations, or behaviour that can break callers. Say "None found in the diff" when none appear.
4. Decisions the agent made — choices visible in the diff or named in the PR body (for example an AgDR link). Do not invent a decision that is not there.

### 5. Optional comprehension quiz

When `$ARGUMENTS` contains `--quiz`, or when the operator asks for the quiz after the walkthrough:

1. Build the evidence pack with `approval-quiz.sh pack` from the same diff and body.
2. Follow `docs/skills/approval-quiz.md`.
3. Ask three `AskUserQuestion` items that name files and lines.
4. On a wrong answer, show the packed lines and ask again.

This skill still writes no marker and runs no merge after the quiz.

## Rules

1. Read-only. Never write `.ceo.approved`, never call `tracker_pr_merge`, never invoke `/approve-merge`.
2. Ground every claim in the PR diff or body (and ticket text only when the body links it and you can read it).
3. The quiz is optional. Default approve-merge modes stay unchanged.
4. Model invocation is allowed. This skill is not human-only.

## Glossary

| Term | Definition |
|------|------------|
| Comprehension check | Questions that show the approver understood the change before approving it. |

---

*Part of ApexYard — multi-project SDLC framework for Claude Code.*
