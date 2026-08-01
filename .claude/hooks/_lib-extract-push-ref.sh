#!/bin/bash
# Shared push-source-ref extraction for hooks that gate on `git push`.
#
# Not a hook itself (prefixed with `_lib-` so it's never wired as one). Sourced
# by hooks via `. "$(dirname "$0")/_lib-extract-push-ref.sh"`.
#
# WHY THIS EXISTS
# ---------------
# Validation hooks like `validate-branch-name.sh` historically read the branch
# from `git branch --show-current`, which resolves against the harness's $PWD.
# When the harness $PWD is a sibling worktree of the worktree the operator
# actually ran the command in (e.g. an Agent fan-out worker that `cd`'d into
# its own worktree), the resolved branch is wrong — the hook reads the parent
# session's branch, not the agent's.
#
# Fix: parse the actual command for the source ref. `git push origin <branch>`
# carries the source ref directly; that's the ground truth, regardless of $PWD.
# Falls back to no-op (caller uses local HEAD) when no ref is present in the
# command (e.g. no-arg `git push` relying on upstream tracking).
#
# Same shape pattern as `_lib-extract-pr.sh` for the merge-gate hooks (#47):
# gate on the command's actual context, not the harness's $PWD.
#
# HEREDOC-BODY HANDLING (me2resh/apexyard#1066, #1075) — READ THIS
# ------------------------------------------------------------------
# `is_tag_push` and `extract_push_ref` both strip CONFIRMED heredoc bodies
# (via `strip_heredoc_bodies` in `_lib-strip-heredoc.sh`) before answering
# "which ref / is this exempt". That is an ADDITIVE refinement: correct only
# for deciding WHICH ref, never for deciding WHETHER a push exists at all.
#
# **Callers MUST perform their own "is there a push/commit here" presence
# check against the RAW, unfiltered command — never against this file's
# output.** A first version of the #1066 fix ran the presence check itself
# through heredoc-stripped text; a security review found eight malformed-
# heredoc shapes that made the stripper eat the real command, so the
# presence check silently never fired (exit 0, no validation at all). See
# `_lib-strip-heredoc.sh`'s governance comment and
# docs/agdr/AgDR-0113-heredoc-stripper-additive-only.md for the full
# incident and the additive-vs-subtractive framing that fixes it.
#
# USAGE
# -----
#   . "$(dirname "$0")/_lib-extract-push-ref.sh"
#   # 1. Presence check against RAW $COMMAND (never stripped text):
#   if ! echo "$COMMAND" | grep -qE '\bgit\s+push\b'; then exit 0; fi
#   # 2. is_tag_push / extract_push_ref may freely use heredoc-stripped text
#   #    internally — that's the additive "which ref" question:
#   if is_tag_push "$COMMAND"; then exit 0; fi
#   PUSH_REF=$(extract_push_ref "$COMMAND")
#   # 3. Fail closed, don't silently fall back, when raw text plainly has an
#   #    explicit ref that heredoc-stripping made disappear:
#   if [ -z "$PUSH_REF" ]; then
#     RAW_REF=$(_extract_push_ref_core "$COMMAND")   # no heredoc stripping
#     if [ -n "$RAW_REF" ]; then
#       # ambiguous — block, don't guess. See hook scripts for the message.
#     fi
#     # else: genuinely bare push (no ref anywhere) — fall back to local HEAD.
#   fi
#
# Refs: me2resh/apexyard#194, me2resh/apexyard#547, me2resh/apexyard#1066

# SELF-LOCATION BOOTSTRAP (me2resh/apexyard#1102 / AgDR-0118)
# ------------------------------------------------------------
# Was `HOOK_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"` -- no
# `:-` guard at all. Under a non-bash sourcing shell (zsh), BASH_SOURCE is
# unset/empty, so `dirname ""` -> `.` and HOOK_LIB_DIR silently became the
# CALLER's $PWD. If that cwd happened to ship a same-named
# `_lib-strip-heredoc.sh`, it would be sourced UNANCHORED. The bootstrap
# guard below (raw BASH_SOURCE[0] captured once, empty short-circuits to no
# self-location) plus `resolve_anchored_lib_dir` in _lib-ops-root.sh (the
# anchor check) are the ONE shared idiom every _lib-*.sh self-location site
# now uses -- see that function's header for why the very first hop can
# never itself be centralized behind a sourced call.
_RAW_BASH_SOURCE_0="${BASH_SOURCE[0]:-}"
HOOK_LIB_DIR=""
if [ -n "$_RAW_BASH_SOURCE_0" ]; then
  _CANDIDATE_LIB_DIR="$(cd "$(dirname "$_RAW_BASH_SOURCE_0")" 2>/dev/null && pwd)"
  if [ -n "$_CANDIDATE_LIB_DIR" ] && [ -f "$_CANDIDATE_LIB_DIR/_lib-ops-root.sh" ]; then
    # shellcheck source=./_lib-ops-root.sh
    # shellcheck disable=SC1091
    . "$_CANDIDATE_LIB_DIR/_lib-ops-root.sh"
    if command -v resolve_anchored_lib_dir >/dev/null 2>&1; then
      HOOK_LIB_DIR="$(resolve_anchored_lib_dir "$_RAW_BASH_SOURCE_0")"
    fi
  fi
  unset _CANDIDATE_LIB_DIR
fi
unset _RAW_BASH_SOURCE_0

# shellcheck source=./_lib-strip-heredoc.sh
if [ -n "$HOOK_LIB_DIR" ] && [ -f "$HOOK_LIB_DIR/_lib-strip-heredoc.sh" ]; then
  # shellcheck disable=SC1091
  . "$HOOK_LIB_DIR/_lib-strip-heredoc.sh"
fi

# Returns true (0) when the command is a tag push that has no branch ref at all.
# Tag pushes must be a no-op for a *branch*-name validator.
#
# Detects:
#   git push <remote> --tags              → true
#   git push <remote> tag <name>          → true
#   git push --tags                       → true
#   git push <remote> refs/tags/<name>    → true
#   git push <remote> +refs/tags/<name>:refs/tags/<name>  → true (refspec targeting tags/)
#   git push <remote> v1.0.0              → NOT detected (bare tag name = branch name,
#                                            validator falls back to local HEAD)
#
# Uses heredoc-stripped text internally (see file header) — this is safe
# because the only failure direction is a FALSE NEGATIVE (over-stripping a
# genuine `--tags` mention makes this return false, so the caller proceeds
# to validate a real tag push as if it were a branch push — annoying, not a
# bypass). A FALSE POSITIVE would be dangerous (skips validation of a real
# branch push); stripping can only ever remove text, never add a `--tags`
# that wasn't already in the raw command, so it cannot manufacture one.
is_tag_push() {
  local cmd="$1"

  # Strip heredoc bodies FIRST (me2resh/apexyard#1066) — prose inside a
  # heredoc that mentions "--tags" or "tag <name>" must not be mistaken for
  # a real tag-push flag. Safe direction only — see doc comment above.
  if declare -F strip_heredoc_bodies > /dev/null 2>&1; then
    cmd=$(strip_heredoc_bodies "$cmd")
  fi

  # Strip everything after the first shell redirection/pipe so the check isn't
  # fooled by `2>&1 | tail` appended to the command.
  local clean_cmd
  # require a WHITESPACE boundary before the redirection/pipe operator so a bare
  # `>` inside an ASCII arrow `->` in a commit message is not treated as one (#584).
  clean_cmd=$(echo "$cmd" | sed 's/[[:space:]][0-9]*[>|].*$//')

  # --tags flag: `git push [opts] --tags [remote]`
  if echo "$clean_cmd" | grep -qE '\bgit\s+push\b.*\s--tags(\s|$)'; then
    return 0
  fi

  # `git push <remote> tag <name>` (explicit `tag` keyword before ref)
  if echo "$clean_cmd" | grep -qE '\bgit\s+push\b.*\stag\s+\S'; then
    return 0
  fi

  # refs/tags/ in any positional argument (e.g. push by full ref or refspec)
  if echo "$clean_cmd" | grep -qE '\brefs/tags/'; then
    return 0
  fi

  return 1
}

# Echoes the DESTINATION branch ref from a `git push` command, or empty if
# none found. Operates on WHATEVER TEXT IT IS GIVEN — no heredoc stripping.
# This is the shared token-parsing core; `extract_push_ref` (below) is the
# heredoc-aware wrapper most callers want. Exposed directly so callers can
# also run it against the RAW command as a comparison signal for the
# fail-closed check described in the file header (me2resh/apexyard#1075).
#
# KEY BEHAVIOUR CHANGES vs the original (me2resh/apexyard#547):
#
#   1. Shell redirections and pipes are stripped BEFORE token parsing so that
#      `2>&1`, `2>`, `>`, `|` tokens are not mistaken for branch names.
#
#   2. For a `src:dst` refspec (e.g. `HEAD:feature/GH-1-foo`), the DESTINATION
#      (right of the colon) is returned for validation, not the source. The
#      source side may be `HEAD`, a SHA, or an arbitrary local ref name that
#      the branch-name validator should not block on — the dst is what actually
#      lands on the remote.
#
#   3. Tag pushes are NOT handled here — call is_tag_push() first and exit 0
#      before calling extract_push_ref. This function still returns empty for
#      `--tags` (it's a boolean flag), which is the same as before, but the
#      caller should never reach the branch-name validation step for tag pushes.
#
# Recognises:
#   git push origin <branch>                           → <branch>
#   git push origin HEAD:<branch>                      → <branch>  (DST of refspec)
#   git push origin <src>:<dst-branch>                 → <dst-branch>
#   git push -u origin <branch>                        → <branch>
#   git push --set-upstream origin <branch>            → <branch>
#   git push --force origin <branch>                   → <branch>
#   git push --force-with-lease origin <branch>        → <branch>
#   git push origin HEAD                               → empty (HEAD alone, no dst)
#   git push origin --tags                             → empty (tag push, no branch)
#   git push                                           → empty (relies on upstream tracking)
#   git push origin                                    → empty (no ref given)
#   git push origin --delete <branch>                  → empty (deletion, no source-ref)
#   git push upstream HEAD:feature/GH-1-foo 2>&1 | tl → feature/GH-1-foo (redirections stripped)
#
# Returns: prints the ref to stdout (or empty), always exits 0.
_extract_push_ref_core() {
  local cmd="$1"
  local push_segment ref

  # Bail on `--delete` / `-d` shapes — they don't have a source ref.
  if echo "$cmd" | grep -qE '\bgit\s+push\b[^|;&]*(--delete\b|[[:space:]]-d\b)'; then
    echo ""
    return 0
  fi

  # Strip shell redirections and pipeline suffixes from the raw command before
  # we extract the push segment.  A command like:
  #   git push upstream --tags 2>&1 | tail -5
  # should be seen as:
  #   git push upstream --tags
  # We remove everything from the first redirection operator onward:
  #   - `NNN>` (e.g. `2>`, `1>`, plain `>`)
  #   - `|` pipe
  # This is conservative: we drop from the FIRST such operator to end-of-line.
  # The sed expression requires a WHITESPACE token boundary before the operator,
  # then optional fd digits, then `>` or `|`, then anything: `[[:space:]][0-9]*[>|].*`.
  # The leading whitespace is the #584 fix: the old `[[:space:]]*` (zero-width) let a
  # bare `>` inside an ASCII arrow `->` in a commit message match, truncating the
  # command before the trailing `&& git push <branch>` and falsely blocking the push.
  local stripped_cmd
  stripped_cmd=$(echo "$cmd" | sed 's/[[:space:]][0-9]*[>|].*$//')

  # Isolate the `git push ...` segment up to the first command separator
  # (|, ;, &&, &) so `git push origin foo && echo bar` doesn't pick up `echo`
  # tokens.  (After stripping redirections above, the push segment is usually
  # the whole remaining string, but the separator guard is a useful safety net.)
  push_segment=$(echo "$stripped_cmd" | grep -oE '\bgit\s+push\b[^|;&]*' | head -1)
  if [ -z "$push_segment" ]; then
    echo ""
    return 0
  fi

  # Strip the `git push` prefix so the remaining tokens are args/flags only.
  # BSD sed (macOS) does not support `\b`, so use POSIX-only constructs.
  # Since `git push` is always the first match for the segment we just
  # extracted, a literal-prefix removal via parameter expansion is enough.
  push_segment="${push_segment#*git}"
  # Drop leading whitespace then the literal `push`.
  push_segment="${push_segment#"${push_segment%%[![:space:]]*}"}"
  push_segment="${push_segment#push}"

  # Walk the remaining tokens, skipping flags + their values + the remote.
  # The first non-flag, non-remote positional is the refspec (or branch).
  #
  # Recognised flags that consume a following value:
  #   -o / --push-option, --recurse-submodules, --signed, --receive-pack /
  #   --exec. The common short flags (-u, -f, -n, -v, -q, --force,
  #   --force-with-lease, --tags, --follow-tags, --atomic, --dry-run,
  #   --no-verify, --set-upstream, --prune, --mirror, --all) take no value.
  #
  # Recognised "remote" candidates: `origin`, `upstream`, or any single
  # non-flag token that appears before the ref. We heuristically treat the
  # FIRST non-flag positional as the remote and the SECOND as the ref.
  # `git push <ref>` (one positional, no remote) is rare in scripts; if it
  # happens, this returns empty and the caller falls back to local HEAD.
  local positional_count=0
  local skip_next=0
  ref=""

  # shellcheck disable=SC2086
  for token in $push_segment; do
    if [ "$skip_next" -eq 1 ]; then
      skip_next=0
      continue
    fi

    case "$token" in
      # Flags that consume the next token as a value
      -o|--push-option|--recurse-submodules|--signed|--receive-pack|--exec|--repo)
        skip_next=1
        continue
        ;;
      # `--<flag>=value` form — value is part of the same token, no skip needed.
      --push-option=*|--recurse-submodules=*|--signed=*|--receive-pack=*|--exec=*|--repo=*)
        continue
        ;;
      # Boolean flags — no value.
      -[unfvq]|-[unfvq][unfvq]*|--force|--force-with-lease*|--tags|--follow-tags|--atomic|--dry-run|--no-verify|--set-upstream|--prune|--mirror|--all|--no-tags|--quiet|--verbose|--ipv4|--ipv6|--progress|--no-progress|--thin|--no-thin|--porcelain|--no-recurse-submodules)
        continue
        ;;
      # Anything else starting with - is some other flag we don't know — skip
      # to be safe (don't consume a following value, since most git push flags
      # are boolean).
      -*)
        continue
        ;;
    esac

    positional_count=$((positional_count + 1))
    if [ "$positional_count" -eq 2 ]; then
      ref="$token"
      break
    fi
  done

  if [ -z "$ref" ]; then
    echo ""
    return 0
  fi

  # Strip a single pair of surrounding quote characters, if present, e.g.
  # `git push origin "main"` or `git push origin 'main'`. Without this,
  # the extracted ref carries its quotes into the protected-branch /
  # naming-convention regex match, which never matches `"main"` against
  # `^(main|master|dev|develop)$` — the push then executes unvalidated.
  # Mirrors block-main-push.sh's `cd`-target quote-stripping, which the
  # #580 review of #549 called "the security-critical part" for the same
  # reason (me2resh/apexyard#1079).
  ref="${ref#\"}"; ref="${ref#\'}"
  ref="${ref%\"}"; ref="${ref%\'}"

  # Strip any leading `+` (force-update marker on a refspec).
  ref="${ref#+}"

  # Refspec form `<src>:<dst>` — validate the DESTINATION (right side) because:
  #   - The dst is what lands on the remote and whose name matters for the
  #     branch-naming convention.
  #   - The src may be `HEAD`, a SHA, or a differently-named local tracking
  #     branch — none of which should be validated as a remote branch name.
  # If there is no `:` the whole token is the branch name.
  if echo "$ref" | grep -q ':'; then
    # Take the DST side (right of colon).
    ref="${ref#*:}"
  fi

  if [ -z "$ref" ]; then
    echo ""
    return 0
  fi

  # `HEAD` without a refspec dst — not a branch name we can validate.
  if [ "$ref" = "HEAD" ]; then
    echo ""
    return 0
  fi

  # Strip leading `refs/heads/` if present — leave just the branch shorthand.
  ref="${ref#refs/heads/}"

  echo "$ref"
}

# Heredoc-aware wrapper around _extract_push_ref_core (me2resh/apexyard#1066).
#
# A heredoc body is literal payload data — a commit message, a PR body,
# review prose — not a command. But _extract_push_ref_core scans the WHOLE
# text it's given for the first `git push`-shaped match. This repo's own
# commit messages routinely *discuss* git behaviour in prose, so a call like:
#
#   cat > /tmp/m.txt <<EOF
#   The previous commit claimed terminal `git push` still runs the checks...
#   EOF
#   git commit -F /tmp/m.txt
#   git push upstream fix/GH-1031-untrack-project-config-json
#
# would otherwise match the FIRST "git push" occurrence — inside the prose —
# and extract "still" as the branch name instead of the real push destination.
#
# This function strips CONFIRMED heredoc bodies (see _lib-strip-heredoc.sh)
# before delegating to the core parser. This is an ADDITIVE refinement of
# "which ref" — see the file header and _lib-strip-heredoc.sh's governance
# comment for why callers must NEVER use this function's emptiness to decide
# whether a push exists at all; that's a separate, RAW-text presence check.
extract_push_ref() {
  local cmd="$1"
  if declare -F strip_heredoc_bodies > /dev/null 2>&1; then
    cmd=$(strip_heredoc_bodies "$cmd")
  fi
  _extract_push_ref_core "$cmd"
}

# Scans the RAW command for EVERY "git push ..." occurrence — not just the
# first — and echoes every destination ref found, one per line (skipping
# occurrences with no ref: --delete/-d shapes, --tags-only, a bare `git
# push`). Deliberately independent of heredoc parsing: does not call
# strip_heredoc_bodies, does not care whether a heredoc is confirmed or
# declined, does not touch stripped text at all.
#
# WHY THIS EXISTS (me2resh/apexyard#1075 — decoy-ref hijack, second review
# round on top of the presence-check fix)
# ------------------------------------------------------------------------
# `_lib-strip-heredoc.sh` only strips a heredoc it can CONFIRM (anchored +
# terminated) — by design, an unconfirmed candidate (a backslash-escaped,
# multi-word, or dotted delimiter; `<<EOF` merely inside a quoted string;
# two heredocs on one line) is left completely untouched, because stripping
# it would risk eating a real command that follows. That conservatism is
# correct for the STRIPPER's own job, but it means the (declined) heredoc
# BODY stays visible to `extract_push_ref`'s single first-match scan. If
# that body happens to contain a plausible, non-protected decoy ref BEFORE
# the real `git push` later in the command, `extract_push_ref` returns the
# decoy — a confident WRONG answer, not empty — so the fail-closed check in
# block-main-push.sh (which only engages when the result is EMPTY) never
# fires. Real bash terminates the heredoc at its actual delimiter and
# executes the real push regardless of what the decoy said:
#
#   cat > /tmp/m.txt <<END.OF
#   see git push origin feature/GH-1-safe
#   END.OF
#   git push origin main
#
# `extract_push_ref` returns `feature/GH-1-safe` (not protected) here — not
# empty — while bash terminates at `END.OF` and pushes to `main` for real.
#
# Rather than trying to make heredoc-delimiter parsing perfect (it can't
# be — see AgDR-0104), this scans the RAW command for every push-shaped
# occurrence and lets the caller (block-main-push.sh) block if ANY of them
# names a protected branch. That closes the decoy-hijack without depending
# on heredoc detection succeeding at all — a decoy sitting in a body this
# parser can't confirm is still just TEXT, and text-with-a-protected-name
# is exactly what this function looks for, independent of where it sits.
#
# Accepted trade-off, same direction as elsewhere in this file: a
# heredoc-authored commit message that merely *discusses* pushing to a
# protected branch, with no real push to it anywhere in the command, will
# also surface that mention here and can cause an over-block. See
# docs/agdr/AgDR-0113-heredoc-stripper-additive-only.md.
#
# Returns: zero or more refs, one per line, in the order they appear.
# Always exits 0.
_extract_all_push_refs_core() {
  local cmd="$1"
  local stripped_cmd

  # Same redirect/pipe stripping as _extract_push_ref_core, applied to the
  # WHOLE command before segmenting.
  stripped_cmd=$(echo "$cmd" | sed 's/[[:space:]][0-9]*[>|].*$//')

  echo "$stripped_cmd" | grep -oE '\bgit\s+push\b[^|;&]*' | while IFS= read -r segment; do
    [ -z "$segment" ] && continue

    # --delete / -d shapes have no source ref — skip this occurrence, keep
    # scanning the rest.
    if echo "$segment" | grep -qE '(--delete\b|[[:space:]]-d\b)'; then
      continue
    fi

    # Strip the "git push" prefix so remaining tokens are args/flags only.
    segment="${segment#*git}"
    segment="${segment#"${segment%%[![:space:]]*}"}"
    segment="${segment#push}"

    local positional_count=0
    local skip_next=0
    local ref=""

    # shellcheck disable=SC2086
    for token in $segment; do
      if [ "$skip_next" -eq 1 ]; then
        skip_next=0
        continue
      fi

      case "$token" in
        -o|--push-option|--recurse-submodules|--signed|--receive-pack|--exec|--repo)
          skip_next=1
          continue
          ;;
        --push-option=*|--recurse-submodules=*|--signed=*|--receive-pack=*|--exec=*|--repo=*)
          continue
          ;;
        -[unfvq]|-[unfvq][unfvq]*|--force|--force-with-lease*|--tags|--follow-tags|--atomic|--dry-run|--no-verify|--set-upstream|--prune|--mirror|--all|--no-tags|--quiet|--verbose|--ipv4|--ipv6|--progress|--no-progress|--thin|--no-thin|--porcelain|--no-recurse-submodules)
          continue
          ;;
        -*)
          continue
          ;;
      esac

      positional_count=$((positional_count + 1))
      if [ "$positional_count" -eq 2 ]; then
        ref="$token"
        break
      fi
    done

    [ -z "$ref" ] && continue
    # Strip a single pair of surrounding quote characters, if present --
    # see _extract_push_ref_core's identical comment (me2resh/apexyard#1079).
    ref="${ref#\"}"; ref="${ref#\'}"
    ref="${ref%\"}"; ref="${ref%\'}"
    ref="${ref#+}"
    case "$ref" in *:*) ref="${ref#*:}" ;; esac
    [ -z "$ref" ] && continue
    [ "$ref" = "HEAD" ] && continue
    ref="${ref#refs/heads/}"
    echo "$ref"
  done
}

# Returns true (0) when the raw command contains AT LEAST ONE "git
# push"-shaped occurrence that is BOTH (a) missing its own tag-push
# evidence (no `--tags` flag, `tag <name>` keyword, or `refs/tags/`
# reference within that occurrence's own segment text) AND (b) missing an
# explicit destination ref (a bare push, relying on upstream tracking).
# Such an occurrence is the one case neither of the other two checks in
# this file can validate: decision point 4's scan-all only ever inspects
# EXPLICIT refs (a bare push has none), and `is_tag_push`'s global
# exemption cannot safely cover it either (it is not a genuine tag push).
# It needs the local-branch fallback, unconditionally — and per-occurrence
# is the only granularity at which that determination is safe. See the
# THIRD version note below for why a whole-command boolean (either "does
# this command have exactly one occurrence" or "does every occurrence
# carry evidence") cannot make this call correctly.
#
# WHY PER-OCCURRENCE, NOT A WHOLE-COMMAND VERDICT (me2resh/apexyard#1075,
# seventh review round — this replaced a SECOND over-narrow version,
# `_is_genuine_single_tag_push`, in the same file)
# ------------------------------------------------------------------------
# Two prior versions of this check, both whole-command booleans, each
# failed a DIFFERENT real shape:
#
#   FIRST version: "exactly one push-shaped occurrence in the command,
#   and it carries tag evidence." Over-blocked a normal release step —
#   pushing tags to two remotes in one command:
#
#     git push origin --tags && git push upstream --tags
#
#   has TWO occurrences, both genuinely tag-shaped, no decoy anywhere —
#   rejected anyway, because "exactly one" counted occurrences instead of
#   asking whether each one was safe.
#
#   SECOND version (a same-day fix to the first): "every occurrence
#   carries its own tag evidence." This fixed the two-remote case, but
#   broke a DIFFERENT genuine shape it hadn't been checked against — a
#   plain, ordinary push to a non-protected branch, followed by a
#   SEPARATE genuine tag push, no heredoc anywhere:
#
#     git push origin feature/GH-1-x && git push origin --tags
#
#   Under "every occurrence must carry evidence," the feature-branch
#   occurrence (no tag evidence at all — it's an ordinary push) made the
#   WHOLE command untrusted, which forced PUSH_DST empty and triggered the
#   fail-closed block with a message blaming heredoc structure that does
#   not exist in this command at all. `dev` allows this command; so did
#   this file before either whole-command version existed.
#
#   The reason BOTH whole-command versions kept failing on a NEW shape
#   each time: an occurrence that carries an EXPLICIT ref needs no
#   special handling here at all — decision point 4's scan-all has
#   ALREADY checked it against the protected list, independent of
#   whether it's a tag push. Folding that occurrence into a "does the
#   WHOLE command's tag-push signal deserve trust" verdict was always the
#   wrong question. The right question is per-occurrence: does THIS
#   occurrence need something neither scan-all nor the tag exemption
#   already covers? Only a bare, evidence-less push does — because it has
#   no ref for scan-all to check, and no tag evidence for the exemption
#   to cover.
#
# A genuine tag push (alone, after a confirmed decoy-free heredoc, to
# several remotes, or alongside an ordinary explicit-ref push to a
# different, non-protected branch) never has a bare evidence-less
# occurrence, so this correctly returns false (nothing to force) for all
# of them.
#
# Deliberately independent of heredoc parsing, matching
# _extract_all_push_refs_core's philosophy: operates on the RAW command,
# does not call strip_heredoc_bodies, does not care whether any heredoc in
# the command was confirmed or declined.
#
# NOTE ON NAMING: this function's name no longer contains "tag" or
# "single" precisely because its predecessors' names (and the reasoning
# embedded in them) actively misled two rounds of otherwise-careful
# review toward a whole-command verdict. The name states exactly what the
# function checks: is there an untagged, ref-less push anywhere in this
# command.
#
# Returns: 0 (true — found at least one; force the ref-less fallback path)
# or 1 (false — none found; every occurrence is either a genuine tag push
# or already covered by decision point 4's scan-all). Always exits
# cleanly either way.
_command_has_untagged_refless_push() {
  local cmd="$1" stripped_cmd segment has_evidence seg
  local positional_count skip_next token ref found

  stripped_cmd=$(echo "$cmd" | sed 's/[[:space:]][0-9]*[>|].*$//')
  found=1

  while IFS= read -r segment; do
    [ -z "$segment" ] && continue

    # --delete / -d shapes have no source ref and no branch to protect —
    # not the shape this function looks for, skip like
    # _extract_all_push_refs_core does.
    if echo "$segment" | grep -qE '(--delete\b|[[:space:]]-d\b)'; then
      continue
    fi

    has_evidence=0
    if echo "$segment" | grep -qE '\s--tags(\s|$)' \
       || echo "$segment" | grep -qE '\stag\s+\S' \
       || echo "$segment" | grep -qE 'refs/tags/'; then
      has_evidence=1
    fi

    # Determine whether THIS segment has an explicit positional ref —
    # same token walk as _extract_all_push_refs_core, applied per segment
    # so evidence and ref-presence are checked on the SAME occurrence.
    seg="${segment#*git}"
    seg="${seg#"${seg%%[![:space:]]*}"}"
    seg="${seg#push}"
    positional_count=0
    skip_next=0
    ref=""

    # shellcheck disable=SC2086
    for token in $seg; do
      if [ "$skip_next" -eq 1 ]; then
        skip_next=0
        continue
      fi
      case "$token" in
        -o|--push-option|--recurse-submodules|--signed|--receive-pack|--exec|--repo)
          skip_next=1
          continue
          ;;
        --push-option=*|--recurse-submodules=*|--signed=*|--receive-pack=*|--exec=*|--repo=*)
          continue
          ;;
        -[unfvq]|-[unfvq][unfvq]*|--force|--force-with-lease*|--tags|--follow-tags|--atomic|--dry-run|--no-verify|--set-upstream|--prune|--mirror|--all|--no-tags|--quiet|--verbose|--ipv4|--ipv6|--progress|--no-progress|--thin|--no-thin|--porcelain|--no-recurse-submodules)
          continue
          ;;
        -*)
          continue
          ;;
      esac
      positional_count=$((positional_count + 1))
      if [ "$positional_count" -eq 2 ]; then
        ref="$token"
        break
      fi
    done

    if [ "$has_evidence" -eq 0 ] && [ -z "$ref" ]; then
      found=0
    fi
  done < <(echo "$stripped_cmd" | grep -oE '\bgit\s+push\b[^|;&]*')

  return "$found"
}
