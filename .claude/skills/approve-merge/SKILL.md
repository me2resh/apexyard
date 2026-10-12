---
name: approve-merge
description: Record per-PR CEO approval and merge in one turn. ONLY on an explicit per-PR "approved" — never on umbrella "go".
disable-model-invocation: true
argument-hint: "<pr-number> [--no-merge]"
effort: low
---

Writing: read docs/skills/shared/writing-rule.md before you write a durable artifact.

# /approve-merge — Record CEO Approval and Merge

Write per-PR approval, then merge through the tracker adapter.
Rationale: read docs/skills/approve-merge-rationale.md for gate history and AgDR references.

## The one rule you must not break

Invoke only on explicit user approval for this PR. A plan-level "go" is not merge approval.
Stop and ask when the PR or intent is unclear. Only the human can invoke this skill (#1042).

## Process

### 0. Resolve the configured approver display title (SOFT, prose-only)

Before addressing the user in any confirmation question or report, read the configured display title for the human per-PR merge approver:

```bash
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-read-config.sh"
APPROVER_TITLE=$(config_get_or '.review_markers.human_approver_title' 'CEO')
```

Use `$APPROVER_TITLE` in prose only. Keep the `-ceo` filename and marker fields unchanged.
If config or jq is unavailable, use `CEO`. This display setting must not block the skill.

### 1. Parse the PR number, the repo, and flags

Extract the PR number from `$ARGUMENTS`. If no number is given, try to infer from:

- The current branch's open PR via `gh pr view --json number --jq '.number'`
- The user's most recent message, if it named a PR explicitly

If the PR number is ambiguous (multiple PRs on the branch, unclear which was approved), STOP and ask the user which PR.

Resolve `REPO` from `owner/repo#N` or an explicit `owner/repo` argument.
Otherwise, parse the current checkout's `git remote get-url origin`. Do not use ambient gh resolution or `headRepository` (#887).
Scope each host query to `REPO`, then `PR_HOST_REPO` after step 4.
Recognise `--no-merge`. It writes approval without merging.

### 2. Sanity-check the user's intent

Before doing anything, re-read the user's most recent message:

- Did the user explicitly name this PR, or can I point at a direct "Ready to merge PR #X — approved?" question from me that they are responding to?
- Is the user's message a standalone merge nod, or is it an umbrella "go" on a broader plan?
- If the latter — **STOP**. Reply with a per-PR explicit question instead:
  > "PR #X is ready to merge. Just confirming — explicit approval to merge PR #X, now?"

Only proceed past this step if the user has given an unambiguous per-PR approval.

### 3. Resolve the ops root

Keep this bootstrap inline. It locates the script from workspace clones and split-portfolio forks (#229, #230, #559).

```bash
OPS_ROOT=""
PIN_FILE="${APEXYARD_OPS_PIN_DIR:-$HOME/.claude/apexyard}/ops-root-${CLAUDE_CODE_SESSION_ID:-}"
if [ -z "${APEXYARD_OPS_DISABLE_PIN:-}" ] && [ -n "${CLAUDE_CODE_SESSION_ID:-}" ] && [ -f "$PIN_FILE" ]; then
  IFS= read -r OPS_ROOT < "$PIN_FILE" || OPS_ROOT=""
fi
# Validate the pin (self-heal a stale one): must satisfy a fork anchor.
if [ -n "$OPS_ROOT" ] && [ ! -f "$OPS_ROOT/.apexyard-fork" ] && \
   { [ ! -f "$OPS_ROOT/onboarding.yaml" ] || [ ! -f "$OPS_ROOT/apexyard.projects.yaml" ]; }; then
  OPS_ROOT=""
fi
# Fallback: walk up from git toplevel (pre-#381 behaviour, safety net).
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

### 4. Check merge prerequisites once

Run this command once. Capture stdout. Show stderr to the user.

```bash
CHECK_JSON=$(bash "$MARKER_HOME/.claude/skills/approve-merge/scripts/approve-merge.sh" <pr> "$REPO" "$MARKER_HOME")
CHECK_RC=$?
[ "$CHECK_RC" -eq 0 ] || exit "$CHECK_RC"
printf '%s' "$CHECK_JSON" | jq -e '
  type == "object" and
  (.marker_home | type == "string" and length > 0) and
  (.pr_host_repo | type == "string" and length > 0) and
  (.strategy | type == "string" and length > 0) and
  (.release_class | type == "boolean")' >/dev/null || exit 1
MARKER_HOME=$(printf '%s' "$CHECK_JSON" | jq -r '.marker_home') || exit 1
PR_HOST_REPO=$(printf '%s' "$CHECK_JSON" | jq -r '.pr_host_repo') || exit 1
MERGE_STRATEGY=$(printf '%s' "$CHECK_JSON" | jq -r '.strategy') || exit 1
RELEASE_CLASS=$(printf '%s' "$CHECK_JSON" | jq -r '.release_class') || exit 1
case "$MERGE_STRATEGY" in
  squash|merge|rebase) ;;
  *) echo "Invalid merge strategy." >&2; exit 1 ;;
esac
source "$MARKER_HOME/.claude/hooks/_lib-review-markers.sh" || exit 1
HEAD_SHA=$(gh pr view <pr> --repo "$PR_HOST_REPO" --json headRefOid -q '.headRefOid') || exit 1
[ -n "$HEAD_SHA" ] || exit 1
```

Stop on any non-zero exit, invalid JSON, or missing field. NEVER assume a pass.
Accept only squash, merge, rebase as strategy values.

- Exit 10: the branch is behind and the base touches shared files. Tell the user to update the branch.
  Show `gh pr update-branch <pr> --repo "$REPO"`. Wait for green CI. Run the carry-over check before requesting a Rex delta review.
  Use `AskUserQuestion` with "Run it yourself (Recommended)" and "Approve me to run it".
  The first choice means the operator runs the command. The second permits the agent to push the branch update.
  Update nothing before the operator chooses. If the harness lacks this tool, show the same choices as a numbered list.
- Exit 11: the behind check could not run. Retry or verify the base manually. Stop before writing any marker.
- Exit 12: the Rex marker is missing or stale. Never move, rename, or copy a marker file.
  Use `rm` to delete the gate-invisible file named in stderr. Re-run `/code-review <pr>` without a marker path.
- Exit 13: the release PR title or body is unreadable. Fix the read failure and retry. Never use a bare squash fallback.
- Other exit: show the error and stop.

### 5. Write the structured CEO marker

The marker is a key/value file with required fields. The format:

```
sha=<40-char hex — must be the PR HEAD from step 3>
approved_by=user
approved_at=<ISO-8601 UTC timestamp, e.g. 2026-05-03T13:25:42Z>
skill_version=2
approval_summary="<truncated user approval message, ≤200 chars>"
```

Keep all marker fields below. Use the ops root and the repo-qualified `review_marker_path` helper (AgDR-0060, #765).
Use `HEAD_SHA` from the scoped host query in step 4.

```bash
# (MARKER_HOME and PR_HOST_REPO already resolved in step 4 — reuse them here.)
mkdir -p "$MARKER_HOME/.claude/session/reviews"
ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Sanitise: drop newlines, drop shell-special chars, truncate to 200.
summary=$(echo "<user approval message>" | tr '\n' ' ' | tr -d '"`$\\' | cut -c1-200)

# CEO marker keyed on the BASE repo — same key as Rex's marker and the gate's
# lookup (#765). Keying it on the fork would leave a cross-fork merge blocked.
CEO=$(review_marker_path "$PR_HOST_REPO" <pr> ceo "$MARKER_HOME")
cat > "$CEO" <<EOF
sha=${HEAD_SHA}
approved_by=user
approved_at=${ts}
skill_version=2
approval_summary="${summary}"
EOF
```

### 6. Merge with the checked strategy

Skip this step for `--no-merge`. Run this entire block in one shell.
Keep tracker_pr_merge as a bare top-level statement. Redirect stdout, then read the result separately.

```bash
source "$MARKER_HOME/.claude/hooks/_lib-tracker.sh" || exit 1
RELEASE_SUBJECT=""
RELEASE_BODY_FILE=""
if [ "$RELEASE_CLASS" = true ]; then
  RELEASE_SUBJECT=$(gh pr view <pr> --repo "$PR_HOST_REPO" --json title -q '.title') || exit 1
  if [ -z "$RELEASE_SUBJECT" ]; then
    echo "ERROR: could not read the release PR's title." >&2
    exit 1
  fi
  RELEASE_BODY_FILE=$(mktemp) || exit 1
  if ! gh pr view <pr> --repo "$PR_HOST_REPO" --json body -q '.body' > "$RELEASE_BODY_FILE" \
     || [ ! -s "$RELEASE_BODY_FILE" ]; then
    echo "ERROR: could not read the release PR's body. Refusing a bare squash." >&2
    rm -f "$RELEASE_BODY_FILE"
    exit 1
  fi
fi
MERGE_RESULT_FILE=$(mktemp) || exit 1
tracker_pr_merge "$PR_HOST_REPO" "<pr>" "${MERGE_STRATEGY}" true "$RELEASE_SUBJECT" "$RELEASE_BODY_FILE" > "$MERGE_RESULT_FILE"
MERGE_RC=$?
MERGE_RESULT="$(cat "$MERGE_RESULT_FILE")"
MERGE_SHA=$(printf '%s' "$MERGE_RESULT" | jq -r '.sha // empty' 2>/dev/null)
rm -f "$MERGE_RESULT_FILE" "$RELEASE_BODY_FILE"
```

### 7. Process the merge result

On `MERGE_RC` 0, report `MERGE_SHA` and continue.
On any other result, show the exact error. The CEO marker stays on disk for a retry.
`MERGE_RC` 3 means `tracker.kind` is `none`. Report approval and ask the user to merge manually on the host.
No further `/approve-merge` invocation is needed after that manual merge.

### 8. Move the board card to "Measurement" (opt-in)

After a successful merge, call `board_move_card` to signal that the work has
shipped and is entering the measurement/observe phase. This is a no-op unless
`enable_auto_moves` is `true` in the fork's `github_projects` config.

```bash
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-project-board.sh"
board_move_card "<pr>" "measurement"
```

`board_move_card` degrades gracefully — any failure warns to stderr and returns
0. It never blocks the merge report.

### 9. Report

Single-line confirmation (include the merge strategy used so the operator can see it):

```
✓ Merged PR #<pr> as commit <MERGE_SHA> (strategy: squash). Branch deleted.
```

or for sync PRs:

```
✓ Merged PR #<pr> as commit <MERGE_SHA> (strategy: merge, auto-detected sync PR — ancestry preserved). Branch deleted.
```

After a successful merge (`MERGE_RC` 0), add this final report line:

```text
Next: run /compact to free context before the next task.
```

If the merge gate blocked (`MERGE_RC` non-zero and not 3), surface the exact error and tell the user how to retry:

```
✗ Merge blocked: <reason from gate>. Marker still on disk at <CEO path from review_marker_path> — fix the issue and re-invoke `/approve-merge <pr>` (the marker is still valid, no need to re-approve).
```

If `MERGE_RC` = 3 (`tracker.kind: none`, no host CLI configured):

```
✓ CEO approval recorded for PR #<pr>. No tracker CLI is configured (tracker.kind: none) — merge <pr> manually on the host; the marker on disk covers the approval, no further /approve-merge invocation needed.
```

### 9a. Optional: offer to remove the merged PR's worktree

Skip this step when `MERGE_RC` is not 0, and when `--no-merge` was passed.

A merged PR often leaves a linked worktree on disk. Removing it also removes its ticket marker, because the marker lives in the worktree's git dir. Offer the removal. Never do it without a yes.

1. Find the local clone of the PR's repo, the **source tree**. For a registered project it is `workspace/<name>/`, or the `workspace:` path of its registry entry. For a PR on the ops fork it is the ops root.
2. List the candidates with the helper. The head branch is the merged PR's head branch:

   ```bash
   .claude/skills/approve-merge/remove-worktree.sh list "<source-tree>" "<head-branch>"
   ```

   The helper takes candidates only from `git worktree list --porcelain -z`, run with `-C` on the validated common dir. The `-z` option needs git 2.36 or later. With an older git, the helper lists no worktree, prints an error and removes nothing. Tell the user that the worktree stays on disk. The helper prints `ok` or `refused (<reason>)` for each worktree that holds the branch, and the ignored files of each `ok` worktree. It refuses the main worktree, a locked worktree, the session's own tree, and any path that equals or contains the ops root.
3. If there is an `ok` worktree, ask with `AskUserQuestion`. Show the path and the ignored files the helper listed, because `git worktree remove` deletes them. Offer "Remove it" and "Keep it".
4. On "Remove it", run:

   ```bash
   .claude/skills/approve-merge/remove-worktree.sh remove "<source-tree>" "<path>" "<head-branch>"
   ```

   The helper first re-checks that the worktree still holds the merged head branch and passes every refusal rule. It runs `git worktree remove` with no `--force`. A dirty worktree stops the step. Report the helper's message, and leave the worktree for the user.
5. On "Keep it", do nothing. Do not ask again.

Never remove a path that the helper did not list. Never pass `--force`.

### 10. Optional: post-merge child-issue closure

If the PR's merge commit / PR body contains `Closes <owner/repo>#<N>` references that GitHub's auto-closer didn't catch (squash merges with cross-repo refs sometimes silently miss), you can offer to close them with a comment. This is **out of scope for the default flow** — only do it if the user explicitly asks. Don't auto-close child issues; that's another externally-visible action that needs its own per-issue confirmation.

## --no-merge opt-out

`/approve-merge <pr> --no-merge` writes the marker and stops. Useful when:

- CI is still running and you want to record approval before the green light, then merge later
- You want to record approval but defer the merge for a batch
- You want the marker on disk to unblock a teammate who'll do the merge themselves
- A regulated environment requires temporal separation between approval and execution

The skill never writes the marker AND defers the merge in any other case. The default IS auto-merge.

## Notes

- The marker is gitignored session state.
- A retry replaces the marker with the current head and timestamp.
- New commits invalidate approval unless the gate verifies Rex carry-over (#1437, #1456). Never rewrite a Rex marker.
- Legacy bare-SHA markers are rejected. Run this skill again to write version 2.
- Invoke this skill on human approval. Do not poll for approval.
