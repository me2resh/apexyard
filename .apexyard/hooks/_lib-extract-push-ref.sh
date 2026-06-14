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
# USAGE
# -----
#   . "$(dirname "$0")/_lib-extract-push-ref.sh"
#   PUSH_REF=$(extract_push_ref "$COMMAND")
#   # Check is_tag_push first — tag pushes must be no-ops for a branch validator.
#   if is_tag_push "$COMMAND"; then exit 0; fi
#   BRANCH="${PUSH_REF:-$(git branch --show-current)}"
#
# Refs: me2resh/apexyard#194, me2resh/apexyard#547

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
is_tag_push() {
  local cmd="$1"

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
# none found.
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
extract_push_ref() {
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
