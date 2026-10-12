# Security reviewer reference

This document holds the long examples and rationale that `.claude/agents/security-reviewer.md` used to carry inline.
They moved here in me2resh/apexyard#1662 to cut the input tokens of each security review.
Hakim does not need this document for a review.
The agent file states every check, rule, and required output.

## Consolidation note (Wave 2 PR 3 — #347)

This agent file previously ran as `Hatim` (utility agent, narrow PR-review scope, `model: inherit`). Per AgDR-0050 § Axis 2 and the CONSOLIDATE decision recorded in PR #347 PR 3, the persona has been renamed to **Hakim** and the scope broadened to the full Security Auditor role. One agent file, one persona, one canonical role at `@roles/security/security-auditor.md`. The `security-reviewer.md` filename is preserved because the `/security-review` skill, the auto-fire trigger in `.claude/rules/role-triggers.md`, and the `auto-code-review.sh` hook all reference it.

## Approve-verdict and exit-code explanation

**You MUST submit a review to the PR before returning. Do NOT return analysis text only.**

Post the review **through the tracker abstraction** (`tracker_review_submit`), NOT a hardcoded `gh pr review` — so it lands on the right host (GitHub PR, GitLab MR, or a `custom` host) for the project's configured `tracker.kind` (#763, mirroring the code-reviewer routing in #758). Write your review to a temp body-file and pass the `comment` verdict:

```bash
# Full resolution — source _lib-tracker.sh, resolve $PR_HOST_REPO (the PR/MR base
# repo, NOT the fork), write $REVIEW_BODY_FILE — is in the Process section below.
tracker_review_submit "$PR_HOST_REPO" {number} comment "$REVIEW_BODY_FILE"
```

### Pass the `comment` verdict, not `approve` — and treat an `approve` block as expected, not a failure

- **Canonical happy path:** call `tracker_review_submit "$PR_HOST_REPO" {number} comment "$REVIEW_BODY_FILE"` and state the verdict (`APPROVED` / `CHANGES REQUESTED`) in the body itself. On gh it maps to `gh pr review --comment`; on glab to an MR note; on custom to the operator's `review_command`.
- **Do NOT pass the `approve` verdict by default.** On gh it maps to `gh pr review --approve`, which GitHub refuses on the common single-account setup ("Cannot approve your own PR"); that block is **expected, not a failure**. Unlike Rex, the security review has **no merge-gate marker** — the review's *visibility on the host* is its whole output, so a `comment` post fully satisfies `/security-review`. Do not retry or escalate an `approve` block.
- The `request-changes` verdict is fine for a non-approving result you want reflected in the host's review state (on gh; on glab it posts a note, since GitLab has no request-changes state).

**Submit contract.** `tracker_review_submit` exit codes: `0` = posted (good); `3` = `tracker.kind=none` — no host CLI, so the function echoes your review body to stdout: include it verbatim in your final report so a human can post it (**not** a failure); any other non-zero = host CLI failed (network / auth / transient) — **warn loudly and include the full review body in your final report** so it isn't lost, then tell the operator to re-post manually.

---

## Trigger list

Invoked when a PR needs security review, especially for:

- Authentication / authorisation changes
- User input handling
- API endpoints
- Data storage changes
- Third-party integrations

## Scratch-clone detail

Some reviews need to run tests or attack probes against the PR head, outside this repository's working tree. Use one of these two sanctioned patterns.

1. `git clone <fork-url> <literal-scratch-path>` — a plain clone at a physical, symlink-free path under a temporary directory. Use a literal path, not a shell variable. The ticket gate resolves a literal path. It cannot resolve a variable. A session with an active Rex, Security, or Architecture review marker can write test fixtures in a standalone clone with an origin remote without a ticket. Symlinked targets remain gated. A `git worktree add` checkout is a linked worktree, and writes inside it still need an active ticket.
2. `git archive <ref> | tar -x -C <literal-non-git-dir>` — exports the PR head into a literal directory outside every git repository. The gate cannot read the tar extraction's own target. It treats that step as an unextractable write. That step needs an active session ticket (me2resh/apexyard#1396). The out-of-governance exemption (me2resh/apexyard#883) does not cover the extraction step. A later write to a literal path inside that directory can use the #883 exemption instead.

While the active-reviewer marker exists, `block-reviewer-repo-mutation.sh` blocks `git clone`, `git fetch`, and `git checkout`. The hook finds the ops fork from its own working directory, not from the command. The orchestrator prepares the scratch clone before it arms the marker. It clones the fork, fetches the PR head, and checks out the head at a literal path. Then it gives that path to the reviewer. Pattern 2 also needs the PR head in the local object store before the marker is armed. During the review, `git worktree add <literal-path> <sha>` stays available as a literal, single-line `git [-C <dir>] worktree add <path> <commit>` when the path sits outside the ops fork and the managed workspace (me2resh/apexyard#1275, #1509). The rest of that command is still checked. The linked checkout does not receive the scratch-clone ticket exemption.

If a hook blocks a command in the scratch clone or export, stop that step. Report the exact command, the hook name, and its message to the orchestrator. Never rephrase, split, encode, or disguise a command to get past a hook — see `.claude/rules/pr-workflow.md`'s least-privilege rule.

Never quote a tracker shell command — `gh issue`, `gh pr`, `tracker_create`, `tracker_review_submit`, `tracker_pr_merge` — inside a review body file. Describe the command in prose instead.

## Ops-root resolution and review posting: full script

Resolve the ops fork root **pin-first** (the SAME strategy the merge gate uses — `_lib-ops-root.sh::resolve_ops_root`) so you can source `_lib-tracker.sh` AND `_lib-review-markers.sh` (needed for `pr_base_repo`, below), then resolve the PR/MR **host (base) repo** and submit. Both libs live at `<ops_fork_root>/.claude/hooks/`; inside a `workspace/<project>/` clone, `git rev-parse --show-toplevel` is the project clone, NOT the ops fork — so resolve pin-first. (This agent writes **no** gate marker, so it does not need `review_marker_path` — only `pr_base_repo` from `_lib-review-markers.sh`.)

```bash
# 1. Pin-first ops-root resolution (points at the real ops fork regardless of cwd).
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
# Fallback: walk up from the repo root (pre-#381 behaviour, safety net).
if [ -z "$OPS_ROOT" ]; then
  r=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
  while [ -n "$r" ] && [ "$r" != "/" ]; do
    if [ -f "$r/.apexyard-fork" ] || { [ -f "$r/onboarding.yaml" ] && [ -f "$r/apexyard.projects.yaml" ]; }; then
      OPS_ROOT="$r"; break
    fi
    r=$(dirname "$r")
  done
fi
LIB_HOME="${OPS_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
# shellcheck source=/dev/null
. "$LIB_HOME/.claude/hooks/_lib-tracker.sh"
# shellcheck source=/dev/null
. "$LIB_HOME/.claude/hooks/_lib-review-markers.sh"

# 2. Resolve the repo YOU already know hosts this PR — that is how you got
# {number} in the first place (the `{repo}` input above, when the invoking
# skill threaded it through). NEVER re-derive this via an unscoped
# `gh pr view {number} --json headRepository` call: that call (a) reads the
# WRONG field for this purpose (the PR's head/fork, not its base) and (b) is
# itself an unscoped, ambient-resolved gh query — the exact class of bug #887
# fixed (gh's ambient default prefers the parent/upstream, which is wrong for
# a same-repo fork PR opened against the fork's own main). When {repo} wasn't
# threaded through, fall back to the CURRENT checkout's own remote — a
# deterministic, non-ambient source of truth — never to a second gh guess.
REPO="{repo}"
if [ -z "$REPO" ] || [ "$REPO" = "{repo}" ]; then
  origin_url=$(git remote get-url origin 2>/dev/null)
  origin_url="${origin_url%.git}"
  REPO=$(printf '%s' "$origin_url" | sed -E 's#^(https?://[^/]+/|git@[^:]+:)##')
fi

# 3. Resolve the PR/MR HOST (base) repo — where the review must be POSTED and
# the repo tracker_review_submit selects its adapter from. On a cross-fork PR
# this differs from the fork (posting to the fork fails: the PR lives on the
# base). `pr_base_repo` (in _lib-review-markers.sh) REQUIRES the explicit
# $REPO above and scopes its gh query to it — NEVER gh's ambient/parent-
# preferring default (#887). Scoping to the repo you already know hosts the
# PR is authoritative, not a guess: a PR object only resolves through its own
# base repo's API path, so passing the wrong repo here fails closed instead
# of silently posting to an unrelated repo's PR of the same number.
PR_HOST_REPO=$(pr_base_repo {number} "$REPO")

# 4. Write the review to a temp body-file and submit through the abstraction.
# A file (not inline text) is the uniform path: gh takes --body-file, glab reads
# the file into an MR note, custom exposes it via $TRACKER_REVIEW_BODY_FILE.
REVIEW_BODY_FILE=$(mktemp)
cat > "$REVIEW_BODY_FILE" <<'REVIEW'
<your full security review — verdict (APPROVED / CHANGES REQUESTED / COMMENT) and commit SHA stated in the body>
REVIEW
tracker_review_submit "$PR_HOST_REPO" {number} comment "$REVIEW_BODY_FILE"; submit_rc=$?
# submit_rc: 0 = posted · 3 = kind=none (echo the body in your report) · other =
# host CLI failed (warn + include the body in your report). See the HARD STOP above.
```

## Example invocation

```
Security review PR #42 in your-org/your-repo
```

## Status of `omitClaudeMd`

Hakim keeps CLAUDE.md.
The agent file decreased from 21,723 to 11,996 bytes.
It sets no `omitClaudeMd` and has no floor block.

The #1650 eval tested corpus entry `hakim-1546-f78c8ae25`.
Hakim without CLAUDE.md missed its HIGH defect in 4 of 19 runs.
Hakim with CLAUDE.md missed it in 0 of 19 runs.

The #1662 transcript comparison covered all 46 #1650 runs on that entry.
All 27 runs with CLAUDE.md read `.claude/settings.json` and the later-version comment in `_lib-extract-pr.sh`.
That comment names the bash 3.2 stall.
Of the 19 runs without CLAUDE.md, 15 read both and caught the defect.
The other 4 read neither and missed it.
Those 4 reviews never read the later-version comment.

The #1662 step 2 cycle used `omitClaudeMd: true`, a floor block, and the trimmed prompt of 11,992 bytes.
The floor block included a hook-wiring bullet.
It required reading `.claude/settings.json` and checking what a timeout or hook error does to the gate.
At k=19 on `hakim-1546-f78c8ae25`, Hakim returned CHANGES REQUESTED in 15 runs, COMMENT in 3, and APPROVED in 1.
This result had 4 misses of 19.
Of the 19 runs, 18 read `.claude/settings.json`.
The 4 misses were the 4 runs that never read the later-version comment.

The hook-wiring bullet did not fix the misses.
The hook-wiring fact was not the cause.
The eval identified no other CLAUDE.md content as the cause.
The criterion of k=19 with 0 misses failed, so Hakim keeps CLAUDE.md.
The omit variant's median first-turn context was 11,028 tokens, against 25,970 for the shipped trim.

A later attempt needs to test the reviewer's path through the working tree as a run-level cause.
That path is an eval artifact: the eval lets the reviewer read a later repository version.

See the [eval report](../eval-agents/reports/review-agents-lean-2026-10-12.md).

## Persona and runtime wrapper

Read and adopt `@roles/security/security-auditor.md` for full identity, responsibilities, CAN / CANNOT boundaries, OWASP / threat-model methodology, severity-classification rules, and handoff conventions. The role file is the canonical persona definition; this file owns the runtime wrapper (model + tool restriction + agent metadata) plus the operational review-posting flow specific to `/security-review` — routed through the tracker-agnostic `tracker_review_submit` (gh PR / glab MR / custom host — #763), not a hardcoded `gh pr review`.

## Delta re-review rationale

Run a delta re-review after new commits land on a PR you already reviewed.

1. Find your last reviewed SHA from your own prior review comment.
2. Run `git diff <last-reviewed-SHA>..HEAD` and read only that delta.
3. Check each earlier finding against the delta. State whether the delta resolved it, left it open, or does not touch it.
4. Read surrounding code only when the delta calls for it — a changed call site or a changed contract the delta depends on.
5. When the PR merges the base branch into the PR branch, find `<new-base>` from the merge commit's own parents (`git log --merges -1 --format=%P HEAD` on the merge commit). Run `git range-diff <old-base>..<old-head> <new-base>..<new-head>` to confirm the PR's own changes did not move, AND read the merge commit's own combined diff with `git show --remerge-diff <merge-sha>` — not scoped to conflicted hunks only, since `git range-diff` skips merge commits and would otherwise miss a change the merge itself introduced. Review the conflict resolution.
6. When the PR was rebased or force-pushed instead of merged, the last reviewed SHA is not an ancestor of the new HEAD. Run `git range-diff <old-base>..<old-head> <new-base>..<new-head>` for this case too, using the old and new PR commit ranges.
7. State `Delta re-review` in the review body's Scope line (see Output Format below). A delta re-review may run at a lower effort level than a first review (me2resh/apexyard#1418 item 2). Steps 1–6 above already narrow the scope. Do not add a second shortcut on top of it.

`.claude/rules/pr-workflow.md` § "After Pushing Commits to an Open PR" stops a NEW round after round two only for a non-blocking finding. A blocking finding left open in round two, or found in any later round, still gets a delta re-review of its fix — the cap never blocks the one path a blocking finding needs to clear.

## Verdict and re-review rule detail

7. **A finding blocks only under the Blocking-Severity Bar** — a regression, a code-execution or approval-bypass vector, a correctness bug, or a failed acceptance criterion. See § "Blocking-Severity Bar". A MEDIUM or LOW finding stays advisory unless it independently meets one of the four kinds.
8. **A re-review is a delta re-review by default** — read only the commits since your last reviewed SHA, per § "Delta Re-Reviews". Read CI's own check-run result for the head SHA before running a test or probe yourself, per § "CI Ownership of the Test Suite". The two-round cap in `.claude/rules/pr-workflow.md` § "After Pushing Commits to an Open PR" stops a NEW round only for a non-blocking finding — a blocking finding always gets a delta re-review of its fix, whatever the round count.

