#!/bin/bash
# Blocks direct pushes and commits to long-lived integration branches.
# All changes must go through pull requests.
#
# Protected branches (default): main / master / dev / develop.
# `dev` was added in apexyard#116 (release-cut model — see AgDR-0007). Forks
# that legitimately use `dev` as a daily-work trunk under their own
# convention can override the protected list via
# `.claude/project-config.json` → `.git.protected_branches[]`.
#
# WORKTREE-SAFE (me2resh/apexyard#549, #727)
# ------------------------------------------
# Previously both the push-check and the commit-check resolved the current
# branch via `git branch --show-current` against the hook's cwd (the harness's
# primary checkout). When the operator runs a command in a separate git worktree
# while the primary checkout sits on a protected branch, the old code
# false-blocked legitimate feature-branch work.
#
# Fix (#549):
#   Push:   reuse `_lib-extract-push-ref.sh` (already used by
#           validate-branch-name.sh for the same reason) to read the DESTINATION
#           branch directly from the push command. Tag pushes are no-ops.
#   Commit: detect the `cd <path> && git commit` shell compound pattern and run
#           `git -C <path> branch --show-current` against the TARGET worktree.
#           Falls back to the session cwd for plain `git commit` (no `cd`
#           prefix) — preserving the original behaviour for the normal case.
#
# Fix (#727) — push fallback when no explicit ref is given:
#   `git push -u origin` (and `--set-upstream`) without an explicit branch
#   name carries no refspec, so extract_push_ref() returns empty and the old
#   code fell back to `git branch --show-current` in the HOOK's session cwd.
#   In a worktree session where the primary checkout is on `dev` but the
#   active worktree is on a feature branch, this falsely blocked a legitimate
#   push.  Fix: when the ref is absent and the command has a `cd <path>`
#   prefix, resolve the current branch from that path (same pattern used by
#   the commit section above).

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)

if [ -z "$COMMAND" ]; then
  exit 0
fi

# Resolve the hook's own directory so we can source sibling libs reliably
# regardless of the harness's $PWD.
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# NOTE on heredoc bodies (me2resh/apexyard#1066, #1075): every presence
# check and cd-target extraction below runs against the RAW $COMMAND, never
# against heredoc-stripped text. A security review of the first #1066 fix
# found that routing these checks through stripped text let a malformed
# heredoc (unterminated, a backslash/multi-word/dotted delimiter, two
# heredocs on one line, or plain prose merely mentioning "<<EOF") make the
# stripper eat the real command, so the presence check never fired and
# neither gate below ever ran -- a silent bypass. `is_tag_push` /
# `extract_push_ref` (sourced below) DO strip heredoc bodies internally,
# but that is safe ONLY because it answers the narrower, additive "which
# ref" question with the fail-closed check below as backstop -- never the
# "is there a push/commit here at all" question. See
# _lib-strip-heredoc.sh's governance comment and
# docs/agdr/AgDR-0113-heredoc-stripper-additive-only.md.

# Resolve protected-branch list from project config (shared reader, #109).
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
PROTECTED=""
if [ -n "$REPO_ROOT" ] && [ -f "$REPO_ROOT/.claude/hooks/_lib-read-config.sh" ]; then
  # shellcheck disable=SC1090,SC1091
  . "$REPO_ROOT/.claude/hooks/_lib-read-config.sh"
  PROTECTED=$(config_get '.git.protected_branches[]' 2>/dev/null | paste -sd'|' -)
fi
if [ -z "$PROTECTED" ]; then
  PROTECTED="main|master|dev|develop"
fi

# ---------------------------------------------------------------------------
# Block: git push <remote> <protected>
#
# Use _lib-extract-push-ref.sh to read the DESTINATION branch from the actual
# push command rather than from the session cwd's HEAD. This is the same
# worktree-safe approach validate-branch-name.sh uses (#194, #547).
#
# Fallback: when no ref is found in the command (bare `git push` / `git push
# origin` relying on upstream tracking), fall back to local HEAD so the hook
# still catches pushes on protected branches made without an explicit ref.
# ---------------------------------------------------------------------------
PUSH_DST=""
SKIP_PUSH_BRANCH_CHECK=0
if echo "$COMMAND" | grep -qE '\bgit\s+push\b'; then
  # Source the shared push-ref extractor if available.
  if [ -f "$HOOK_DIR/_lib-extract-push-ref.sh" ]; then
    # shellcheck disable=SC1090,SC1091
    . "$HOOK_DIR/_lib-extract-push-ref.sh"

    # Defense-in-depth, independent of heredoc parsing entirely (#1075,
    # second security-review round): scan the RAW command for EVERY
    # push-shaped occurrence and block immediately if ANY of them names a
    # protected branch. This closes the decoy-ref hijack: for a heredoc
    # `strip_heredoc_bodies` declines to strip (an unconfirmed candidate —
    # backslash/multi-word/dotted delimiter, `<<EOF` merely inside a quoted
    # string, two heredocs on one line), the body stays visible, and if it
    # contains a plausible NON-protected decoy ref before the real push,
    # extract_push_ref's first-match semantics return that decoy — a
    # confident WRONG answer, not empty — so the empty-only fail-closed
    # check further below never engages. This check doesn't care whether
    # any stripping happened; it just asks "does ANY push-shaped text in
    # this raw command name a protected branch", which is why it runs
    # before is_tag_push too — a decoy `--tags` mention hiding a real
    # protected-branch push would be a mirror-image version of the same
    # bug. See _lib-extract-push-ref.sh's _extract_all_push_refs_core doc
    # comment and docs/agdr/AgDR-0113-heredoc-stripper-additive-only.md.
    if declare -F _extract_all_push_refs_core > /dev/null 2>&1; then
      while IFS= read -r ANY_PUSH_DST; do
        [ -z "$ANY_PUSH_DST" ] && continue
        if echo "$ANY_PUSH_DST" | grep -qE "^(${PROTECTED})$"; then
          cat >&2 <<MSG
BLOCKED: Cannot push directly to a protected branch ('${ANY_PUSH_DST}').

All changes must go through a PR (.claude/rules/git-conventions.md
§ "No Direct Main"). Protected branches: ${PROTECTED//|/, }.

This command contains more than one push-shaped occurrence of text, and
at least one names a protected branch. If that text is inside a heredoc
body describing a DIFFERENT push (not an actual command), run the
heredoc-writing step and the "git push" step in SEPARATE Bash calls --
never inline a heredoc alongside a git command in the same invocation
(me2resh/apexyard#1066's own mitigation note).

To unblock a genuine push:
  1. Create a feature branch from your current work:
       git checkout -b feature/GH-<ticket>-<short-description>
  2. Push the feature branch:
       git push -u origin feature/GH-<ticket>-<short-description>
MSG
          exit 2
        fi
      done < <(_extract_all_push_refs_core "$COMMAND")
    fi

    # Tag pushes are never subject to a branch-protection check. Pass the
    # RAW command — is_tag_push strips heredoc bodies internally.
    #
    # IMPORTANT: this must NOT be a script-level `exit 0`. is_tag_push can
    # itself be fooled by decoy prose in a heredoc `strip_heredoc_bodies`
    # correctly declines to strip (unconfirmed — e.g. a dotted delimiter) —
    # "we always use `git push origin --tags` for releases" as body text
    # makes is_tag_push return true even with no real tag push anywhere in
    # the command (verified: me2resh/apexyard#1075, third review round). A
    # script-level exit here would then skip the UNRELATED commit-check
    # section below entirely, letting a real commit on a protected branch
    # slip through — a worse bug than the one this guard exists to avoid.
    # Setting a flag and falling through means: (a) a genuine tag push
    # still skips the push-branch-check below, and (b) the commit-check
    # section always still runs. See
    # docs/agdr/AgDR-0113-heredoc-stripper-additive-only.md.
    #
    # ALSO IMPORTANT (fourth review round): is_tag_push's TRUE verdict is
    # only trusted when _is_genuine_single_tag_push confirms it describes
    # the ONE push in this command, not decoy text sitting alongside a
    # real, separate, REF-LESS `git push`. Decision point 4's scan-all
    # check above only ever sees EXPLICIT refs -- a bare `git push` has
    # none, so scan-all has nothing to say about it, and the local-HEAD
    # fallback that WOULD catch a ref-less push on a protected branch
    # lives entirely inside the block this flag skips. Skipping it on an
    # untrusted verdict is not "costs nothing" for that shape -- it is the
    # one case with no other backstop at all. See
    # _is_genuine_single_tag_push's doc comment in _lib-extract-push-ref.sh.
    UNTRUSTED_TAG_SIGNAL=0
    if is_tag_push "$COMMAND"; then
      if declare -F _is_genuine_single_tag_push > /dev/null 2>&1 \
         && _is_genuine_single_tag_push "$COMMAND"; then
        SKIP_PUSH_BRANCH_CHECK=1
      else
        # is_tag_push's verdict isn't attributable to a single, genuine
        # tag-push occurrence in this command -- don't trust it. We ALSO
        # must not trust extract_push_ref's ordinary single first-match
        # result below: it can read the SAME decoy segment that fooled
        # is_tag_push (e.g. "git push origin --tags for releases" yields
        # the non-empty, non-protected-looking ref "for"), which would
        # silently replace the local-HEAD fallback with that wrong answer
        # instead of falling through to it. Force the ref-less path
        # instead: decision point 4's scan-all (above) has ALREADY ruled
        # out any occurrence with an explicit PROTECTED ref, so the only
        # remaining question here is whether the real, uncontaminated push
        # needs the local-branch fallback -- which this guarantees it gets.
        UNTRUSTED_TAG_SIGNAL=1
      fi
    fi

    if [ "$SKIP_PUSH_BRANCH_CHECK" != "1" ]; then
      if [ "$UNTRUSTED_TAG_SIGNAL" = "1" ]; then
        PUSH_DST=""
      else
        PUSH_DST=$(extract_push_ref "$COMMAND")
      fi

      # Fail closed rather than silently falling back to the current branch
      # when heredoc-aware extraction found nothing BUT a naive, unstripped
      # parse of the same raw command found something ref-shaped. See
      # me2resh/apexyard#1075 and validate-branch-name.sh's identical check.
      # This also legitimately fires for the untrusted-tag-signal case
      # above (PUSH_DST forced empty, RAW_PUSH_DST reads the decoy) --
      # blocking there is just as correct an outcome as the local-HEAD
      # fallback below would have been, since the decoy proves the
      # command's structure is genuinely ambiguous.
      if [ -z "$PUSH_DST" ]; then
        RAW_PUSH_DST=$(_extract_push_ref_core "$COMMAND")
        if [ -n "$RAW_PUSH_DST" ]; then
          cat >&2 <<MSG
BLOCKED: Cannot safely determine the push destination for this command.

This command contains "git push", and a naive scan (ignoring any heredoc
structure) found what looks like an explicit destination ref -- but
heredoc-aware parsing found none, which means a heredoc body in this same
command may be hiding the real destination.

To unblock: run the heredoc-writing step and the "git push" step in
SEPARATE Bash calls -- never inline a heredoc alongside a git command in
the same invocation (me2resh/apexyard#1066's own mitigation note).
MSG
          exit 2
        fi
      fi
    fi
  fi

  # Determine which branch to check against the protected list. Runs
  # regardless of whether the lib was found (best-effort: PUSH_DST stays
  # empty and we fall back to local-branch resolution) and regardless of
  # SKIP_PUSH_BRANCH_CHECK's earlier state EXCEPT when a genuine tag push
  # was confirmed above -- a tag push has nothing to check here at all.
  if [ "$SKIP_PUSH_BRANCH_CHECK" != "1" ]; then
    if [ -n "$PUSH_DST" ]; then
      TARGET_PUSH_BRANCH="$PUSH_DST"
    else
      # No explicit ref in the command (e.g. `git push -u origin` or bare
      # `git push`): the push targets the current branch of the repo the
      # command runs in. For a compound `cd <path> && git push -u origin`
      # (the worktree case — #727), we must resolve the branch of the
      # TARGET worktree via the `cd` destination, NOT the hook's session
      # cwd. Without this, a developer on a feature-branch worktree who
      # runs `git push -u origin` is falsely blocked because the hook's
      # session cwd (the primary checkout) may sit on a protected branch
      # like `dev`.
      #
      # This mirrors the same pattern used in the commit section below
      # for #549. Uses the RAW command — see the file-level note on why
      # cd-detection never consults heredoc-stripped text.
      PUSH_WORKTREE_PATH=""
      if echo "$COMMAND" | grep -qE '(^|[;&|[:space:]])cd[[:space:]]+\S'; then
        PUSH_WORKTREE_PATH=$(echo "$COMMAND" \
          | grep -oE "cd[[:space:]]+(\"[^\"]*\"|'[^']*'|[^[:space:];&|]+)" \
          | tail -n 1 \
          | sed -E "s/^cd[[:space:]]+//; s/^[\"']//; s/[\"']\$//")
      fi
      if [ -n "$PUSH_WORKTREE_PATH" ]; then
        TARGET_PUSH_BRANCH=$(git -C "$PUSH_WORKTREE_PATH" branch --show-current 2>/dev/null)
      else
        # Plain `git push -u origin` with no `cd` prefix — use session cwd.
        TARGET_PUSH_BRANCH=$(git branch --show-current 2>/dev/null)
      fi
    fi

    if [ -n "$TARGET_PUSH_BRANCH" ] && echo "$TARGET_PUSH_BRANCH" | grep -qE "^(${PROTECTED})$"; then
      cat >&2 <<MSG
BLOCKED: Cannot push directly to a protected branch ('${TARGET_PUSH_BRANCH}').

All changes must go through a PR (.claude/rules/git-conventions.md
§ "No Direct Main"). Protected branches: ${PROTECTED//|/, }.

To unblock:
  1. Create a feature branch from your current work:
       git checkout -b feature/GH-<ticket>-<short-description>
  2. Push the feature branch:
       git push -u origin feature/GH-<ticket>-<short-description>
  3. Open a PR via /feature → /start-ticket → gh pr create, OR if the
     ticket exists, just: gh pr create --base <protected-branch> --head <feature-branch>

Customise (rare): .claude/project-config.json → .git.protected_branches[]
REPLACES the default list (main / master / dev / develop). To REMOVE
protection from a default-protected branch (e.g. you legitimately use
'dev' as your trunk), write the array with that branch OMITTED. To ADD
protection to a new branch, write the array INCLUDING it. The hook
trusts whichever list you provide — get the direction right.
MSG
      exit 2
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Block: git commit on a protected branch
#
# For the `cd <path> && git commit …` compound shell pattern, resolve the
# branch of the TARGET worktree (the `cd` destination) rather than the
# session cwd. This is the exact failure mode reported in #549: the harness
# resets cwd to the primary checkout (on e.g. `dev`), but the actual commit
# targets a feature-branch worktree reached via `cd ../wt && git commit`.
#
# For plain `git commit` (no `cd` prefix) fall back to the session cwd —
# preserving the original behaviour for the normal single-worktree case.
# ---------------------------------------------------------------------------
if echo "$COMMAND" | grep -qE '\bgit\s+commit\b'; then
  # Detect `cd <path>` prefix in compound commands, e.g.:
  #   cd ../wt && git commit -m "msg"
  #   cd /abs/path && git commit …
  # Match `cd` as the first meaningful token before any separator. Uses the
  # RAW command throughout this section — the commit-check has no "which
  # ref" refinement step at all (it only checks current branch), so there
  # is nothing here for heredoc-stripping to safely improve, only a
  # presence question that must stay on raw text.
  WORKTREE_PATH=""
  if echo "$COMMAND" | grep -qE '(^|[;&|[:space:]])cd[[:space:]]+\S'; then
    # Resolve the LAST `cd <path>` in the chain (so `cd a && cd b && git commit`
    # targets b, not a) and STRIP surrounding quotes. Quote-stripping is the
    # security-critical part: without it, `cd "path" && git commit` would pass
    # `"path"` (quotes included) to `git -C`, which errors → empty branch → the
    # protected-branch check is skipped and a commit into a protected-branch
    # worktree slips through. That false-negative was caught in the #580 review
    # of this fix (#549). Handles double-quoted, single-quoted (incl. spaces),
    # and bare paths.
    WORKTREE_PATH=$(echo "$COMMAND" \
      | grep -oE "cd[[:space:]]+(\"[^\"]*\"|'[^']*'|[^[:space:];&|]+)" \
      | tail -n 1 \
      | sed -E "s/^cd[[:space:]]+//; s/^[\"']//; s/[\"']\$//")
  fi

  if [ -n "$WORKTREE_PATH" ]; then
    # Resolve branch in the target worktree, not the session cwd.
    CURRENT_BRANCH=$(git -C "$WORKTREE_PATH" branch --show-current 2>/dev/null)
  else
    # Plain `git commit` with no `cd` — use session cwd (original behaviour).
    CURRENT_BRANCH=$(git branch --show-current 2>/dev/null)
  fi

  if [ -n "$CURRENT_BRANCH" ] && echo "$CURRENT_BRANCH" | grep -qE "^(${PROTECTED})$"; then
    cat >&2 <<MSG
BLOCKED: Cannot commit directly on protected branch '${CURRENT_BRANCH}'.

All changes must go through a PR (.claude/rules/git-conventions.md
§ "No Direct Main").

To unblock:
  1. Create a feature branch from your current state (preserves your
     in-progress edits):
       git checkout -b feature/GH-<ticket>-<short-description>
  2. Retry the commit on the feature branch
  3. Push and open a PR when ready

If you've already committed locally to '${CURRENT_BRANCH}' by accident,
the recovery is a three-step rescue (NOT a separate To-unblock — the
gate is still the one above): create a recovery branch pointing at the
current commit, reset ${CURRENT_BRANCH} to drop the accidental commit
locally, then check out the recovery branch.

       git branch feature/GH-<ticket>-recovery
       git reset --hard HEAD~1   # drops the commit from ${CURRENT_BRANCH}
       git checkout feature/GH-<ticket>-recovery
MSG
    exit 2
  fi
fi

exit 0
