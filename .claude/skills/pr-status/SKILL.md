---
name: pr-status
description: "Show one PR's gate state: approval records, forge checks and rules, QA evidence, next missing action. Read-only; never writes markers or merges."
argument-hint: "<owner>/<repo>#<N> [--json]"
allowed-tools: Bash
---

Writing: read docs/skills/shared/writing-rule.md before you write a durable artifact.

# /pr-status — Show a pull request's gate state

Read-only. This skill runs `bin/apexyard-pr-status` and shows its output.
The operator, a developer and an agent then read the same state before they act.

## What it shows

- Repository, PR number, head SHA, base SHA, linked ticket, worktree and active review.
- Each approval record: `rex`, `security`, `design`, `architecture` and `ceo` (human approval), with the stored SHA.
- Local merge gates: the four merge-gate hooks, run with a synthetic merge payload. A hook only checks. It never merges.
- Forge: required checks, the CI rollup ("CI green"), formal "changes requested" reviews still in force, branch-rule requirements and the merge state.
- QA evidence: the pre-merge QA PASS stamp for the head (see `/code-review`).
- On the last line: the next missing action.

Each item has one status: `satisfied`, `stale`, `missing`, `not required` or `not verified`.
An item that cannot be checked is `not verified`. It is never `satisfied`.
"CI gate" is the merge hook result. "CI green" is the forge check result. They are separate rows.

The records use the same code as the merge gate: `review_marker_path`, `rex_approval_carries_over`, `resolve_pr_head` and the gate hooks themselves.
When the command and a gate do not agree, the item is `not verified` and shows the gate message.

## Steps

1. Read the argument. It must be `<owner>/<repo>#<N>`. If the operator gives only a number, use the repository of the current clone (`gh repo view --json nameWithOwner -q .nameWithOwner`).
2. Run the command from the clone or worktree of that repository, so that the carry-over check can read the commits:

   ```bash
   ops_root=$(p="${APEXYARD_OPS_PIN_DIR:-$HOME/.claude/apexyard}/ops-root-${CLAUDE_CODE_SESSION_ID:-}"; r=""; [ -z "${APEXYARD_OPS_DISABLE_PIN:-}" ] && [ -f "$p" ] && IFS= read -r r < "$p"; [ -f "$r/.claude/hooks/_lib-ops-root.sh" ] || { r="$PWD"; while [ -n "$r" ] && [ ! -f "$r/.claude/hooks/_lib-ops-root.sh" ]; do r=${r%/*}; done; }; [ -f "$r/.claude/hooks/_lib-ops-root.sh" ] && . "$r/.claude/hooks/_lib-ops-root.sh" && resolve_ops_root) && [ -n "$ops_root" ] || { echo "No ops root. See docs/skills/shared/ops-root.md." >&2; exit 1; }
   "$ops_root/bin/apexyard-pr-status" "<owner>/<repo>#<N>"
   ```

3. Show the output as it is. Add `--json` when the caller is a script or an agent that parses it.
4. Report the last line (the next missing action) to the operator.

## Rules

- Do not fix what the report shows. Do not write a marker, a label or a comment. Do not merge.
- Do not run a write command to make an item `satisfied`. Report the next action and stop.
- A `not verified` item is unknown. Do not report it as green.
