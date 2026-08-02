#!/bin/bash
# CLASS: BACKSTOP — blocking, but not the primary control (AgDR-0114).
#
# Blocks direct pushes and commits to long-lived integration branches from
# Claude Code sessions (a PreToolUse hook, evaluated before the shell ever
# runs). All changes must go through pull requests.
#
# THE controls for protected-branch enforcement are the git-native hooks:
#   .githooks/pre-push     — terminal `git push`, ground truth via git's own
#                             stdin ref resolution (me2resh/apexyard#1086
#                             step 2)
#   .githooks/pre-commit    — terminal `git commit`, ground truth via
#                             `git symbolic-ref --short HEAD` (step 3,
#                             AgDR-0114)
# Both need no command-text parsing at all — immune by construction to every
# heredoc/decoy/quoting shape docs/agdr/AgDR-0113-heredoc-stripper-additive-only.md
# catalogues for THIS file's text-matching approach.
#
# THIS file stays a BLOCKING backstop (AgDR-0114 — relabel + keep blocking,
# not demote to advisory), because it is the only layer that covers two
# gaps the git-native hooks structurally cannot close:
#
#   1. `--no-verify` bypasses every git-native hook by git's own design.
#      This file is a Claude Code PreToolUse hook — it intercepts the Bash
#      tool call BEFORE the shell (and therefore before git, and therefore
#      before --no-verify's effect) ever runs, so it stays effective
#      regardless of that flag. See the "--no-verify" note attached to
#      each blocked-push/blocked-commit message below.
#   2. `core.hooksPath` is not installed by default on managed-project
#      clones (me2resh/apexyard#1088, deliberately unresolved) — this file
#      fires process-wide regardless of which repo's clone the command's
#      cwd targets, where the git-native hooks never fire at all.
#
# See docs/agdr/AgDR-0114-block-main-push-honest-naming-blocking-backstop.md
# for the full decision record and docs/agdr/AgDR-0104-trust-chain-controls-vs-backstops.md
# for the "control vs backstop, honestly named" framing this file follows.
#
# Protected branches (default): main / master / dev / develop, resolved via
# the shared `.claude/hooks/_lib-protected-branches.sh` predicate
# (`is_protected_branch`) — the same lib `.githooks/pre-push` and
# `.githooks/pre-commit` use, so all three layers agree on one source of
# truth instead of three copies that have to be trusted to stay in sync.
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
#
# SELF-LOCATION BOOTSTRAP (me2resh/apexyard#1102 / #1126, AgDR-0118)
# ------------------------------------------------------------
# Was `HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"` with no
# anchor check on the resolved dir -- an unset/empty BASH_SOURCE[0]
# (non-bash shell) makes `dirname ""` resolve to ".", silently substituting
# the caller's cwd for this file's real location. That matters MORE here
# than on the other sites migrated alongside this one: HOOK_DIR below is
# used to locate PROTECTED_LIB="$HOOK_DIR/_lib-protected-branches.sh", and
# this file is the protected-branch BLOCKING backstop (AgDR-0114) — a
# cwd-substituted HOOK_DIR pointed at an attacker-controlled directory
# could source an impostor lib defining a permissive is_protected_branch().
# The bootstrap guard (raw BASH_SOURCE[0] captured once, empty
# short-circuits to no self-location, never $0) plus
# `resolve_anchored_lib_dir` in _lib-ops-root.sh (the anchor check) are the
# ONE shared idiom every _lib-*.sh / hook self-location site now uses --
# see that function's header for why the very first hop can never itself
# be centralized behind a sourced call. When self-location is unavailable,
# HOOK_DIR stays empty, PROTECTED_LIB resolves to a nonexistent path, and
# the existing "declare -F is_protected_branch" fallback below fails
# CLOSED to the hardcoded default list — the same fail-closed behaviour
# this file already had for "lib file missing/broken", now also covering
# "self-location unavailable". No behaviour change for the normal case
# (bash, BASH_SOURCE[0] populated): HOOK_DIR resolves exactly as before.
RAW_BASH_SOURCE_0="${BASH_SOURCE[0]:-}"
HOOK_DIR=""
if [ -n "$RAW_BASH_SOURCE_0" ]; then
  _CANDIDATE_DIR="$(cd "$(dirname "$RAW_BASH_SOURCE_0")" 2>/dev/null && pwd)"
else
  _CANDIDATE_DIR=""
fi
if [ -n "$_CANDIDATE_DIR" ] && [ -f "$_CANDIDATE_DIR/_lib-ops-root.sh" ]; then
  # shellcheck source=./_lib-ops-root.sh
  # shellcheck disable=SC1091
  . "$_CANDIDATE_DIR/_lib-ops-root.sh"
  if command -v resolve_anchored_lib_dir >/dev/null 2>&1; then
    HOOK_DIR="$(resolve_anchored_lib_dir "$RAW_BASH_SOURCE_0")"
  fi
fi
unset _CANDIDATE_DIR

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

# Resolve the protected-branch predicate from the shared lib (me2resh/apexyard#1086
# step 2/3, AgDR-0114) instead of resolving `.git.protected_branches[]` a
# second time inline. This file previously carried its own copy of the same
# three lines `_lib-protected-branches.sh` already implements — the
# "duplicate that has to be trusted to agree" pattern AgDR-0113 catalogues as
# this file family's dominant defect generator. Sourcing the lib means this
# file, .githooks/pre-push, and .githooks/pre-commit all resolve the SAME
# list, and all three inherit is_protected_branch()'s fail-closed hardening
# (a malformed `.git.protected_branches[]` entry, or a renamed/missing
# protected_branch_regex function, is treated as PROTECTED, never as a
# silent allow).
PROTECTED_LIB="$HOOK_DIR/_lib-protected-branches.sh"
if [ -f "$PROTECTED_LIB" ]; then
  # shellcheck disable=SC1090,SC1091
  . "$PROTECTED_LIB"
fi
if ! declare -F is_protected_branch > /dev/null 2>&1; then
  # Old clone that hasn't pulled the lib file yet (or it's syntactically
  # broken). Fail closed on the documented default list rather than
  # skipping protected-branch enforcement entirely — this file is a
  # blocking backstop; a missing lib must not turn it into a no-op.
  echo "WARN: $PROTECTED_LIB not found or is_protected_branch unavailable -- falling back to the default protected-branch list (main/master/dev/develop only; .git.protected_branches[] override not applied)." >&2
  is_protected_branch() {
    local b="$1"
    [ -n "$b" ] && echo "$b" | grep -qE '^(main|master|dev|develop)$'
  }
  protected_branch_regex() { echo "main|master|dev|develop"; }
fi

# Display-only rendering of the protected list for BLOCKED messages below
# (e.g. "Protected branches: main, master, dev, develop").
PROTECTED_DISPLAY=$(protected_branch_regex 2>/dev/null)
if [ -z "$PROTECTED_DISPLAY" ]; then
  PROTECTED_DISPLAY="main|master|dev|develop"
fi

# --no-verify note (me2resh/apexyard#1086 step 3, AgDR-0114): --no-verify
# does not bypass THIS file (a PreToolUse hook, not a git hook), but an
# operator seeing a block after passing --no-verify may reasonably wonder
# why the flag "didn't work". Detected once, appended to every BLOCKED
# message below so the reason is explicit rather than left to be
# rediscovered. Detection is deliberately simple (a whitespace-bounded
# literal match) -- this is an explanatory note, not a new gate; the
# existing push/commit checks above and below already block the command
# regardless of --no-verify, with or without this note.
NO_VERIFY_NOTE=""
if echo "$COMMAND" | grep -qE '(^|[[:space:]])--no-verify([[:space:]]|$)'; then
  NO_VERIFY_NOTE="
NOTE: --no-verify does not bypass this check. This hook is a Claude Code
PreToolUse hook (AgDR-0114) that runs BEFORE the shell -- and therefore
before git, and therefore before --no-verify's effect -- ever executes.
The git-native .githooks/pre-push and .githooks/pre-commit hooks WOULD be
skipped by --no-verify; this backstop is not."
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
        if is_protected_branch "$ANY_PUSH_DST"; then
          cat >&2 <<MSG
BLOCKED: Cannot push directly to a protected branch ('${ANY_PUSH_DST}').

All changes must go through a PR (.claude/rules/git-conventions.md
§ "No Direct Main"). Protected branches: ${PROTECTED_DISPLAY//|/, }.

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
${NO_VERIFY_NOTE}
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
    # ALSO IMPORTANT (per-occurrence check, seventh review round):
    # is_tag_push's TRUE verdict is a WHOLE-COMMAND signal ("some push
    # somewhere looks tag-shaped") — it must never be trusted or
    # distrusted as a single whole-command boolean, because both directions
    # of that mistake produced a real, verified bug in earlier rounds of
    # this file: trusting it unconditionally let a decoy hide a real
    # ref-less push (fixed by not skipping the whole script — see above);
    # and later, DIS-trusting it whenever ANY occurrence lacked evidence
    # false-blocked a perfectly ordinary compound push
    # (`git push origin feature/GH-1-x && git push origin --tags` — one
    # explicit-ref push plus one genuine tag push, no heredoc anywhere;
    # `dev` allows it, this file blocked it with a message blaming heredoc
    # structure that does not exist in the command at all).
    #
    # The correct question is per-occurrence, not whole-command:
    # `_command_has_untagged_refless_push` scans every push-shaped
    # occurrence and asks, for EACH one, "does this specific occurrence
    # carry its own tag evidence, or an explicit ref?" — either answer
    # means the occurrence is already safe (exempt, or already checked by
    # decision point 4's scan-all above). Only a BARE occurrence with
    # NEITHER (no tag evidence AND no explicit ref) is unaddressed by
    # anything else in this hook, because scan-all has nothing to check
    # (no ref) and the tag exemption doesn't apply (no evidence) — that
    # occurrence, and only that occurrence, needs the local-HEAD fallback
    # forced. See _command_has_untagged_refless_push's doc comment in
    # _lib-extract-push-ref.sh and docs/agdr/AgDR-0113-heredoc-stripper-additive-only.md.
    UNTRUSTED_TAG_SIGNAL=0
    if is_tag_push "$COMMAND"; then
      if declare -F _command_has_untagged_refless_push > /dev/null 2>&1 \
         && _command_has_untagged_refless_push "$COMMAND"; then
        # At least one occurrence is bare (no ref) AND carries no tag
        # evidence of its own -- neither scan-all nor the tag exemption
        # covers it. We must not trust extract_push_ref's ordinary single
        # first-match result below either: it can read a DIFFERENT
        # occurrence's decoy/tag segment and return a confident,
        # non-protected-looking ref (e.g. "for" from
        # "git push origin --tags for releases"), which would silently
        # replace the local-HEAD fallback with that wrong answer instead
        # of falling through to it. Force the ref-less path instead.
        UNTRUSTED_TAG_SIGNAL=1
      else
        # No bare, evidence-less occurrence anywhere in this command:
        # every occurrence is either a genuine tag push (exempt) or
        # carries an explicit ref that decision point 4's scan-all has
        # ALREADY checked against the protected list above. Nothing left
        # to validate -- safe to skip the ordinary branch-check entirely.
        SKIP_PUSH_BRANCH_CHECK=1
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

This command contains "git push", and a naive scan found what looks like
an explicit destination ref elsewhere in the same command -- but the
push actually being validated has no ref of its own, so it isn't
possible to confirm that the other ref-shaped text is unrelated. This
can happen because of a heredoc body (a commit message or PR body
mentioning a push) or other prose sitting alongside a real, ref-less
push in the same Bash call.

To unblock: run the heredoc/text-writing step and the "git push" step in
SEPARATE Bash calls -- never inline a heredoc or unrelated prose
alongside a git command in the same invocation (me2resh/apexyard#1066's
own mitigation note).
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

    if is_protected_branch "$TARGET_PUSH_BRANCH"; then
      cat >&2 <<MSG
BLOCKED: Cannot push directly to a protected branch ('${TARGET_PUSH_BRANCH}').

All changes must go through a PR (.claude/rules/git-conventions.md
§ "No Direct Main"). Protected branches: ${PROTECTED_DISPLAY//|/, }.

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
${NO_VERIFY_NOTE}
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

  if is_protected_branch "$CURRENT_BRANCH"; then
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
${NO_VERIFY_NOTE}
MSG
    exit 2
  fi
fi

exit 0
