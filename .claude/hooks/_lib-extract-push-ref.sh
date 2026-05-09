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
#   BRANCH="${PUSH_REF:-$(git branch --show-current)}"
#
# Refs: me2resh/apexyard#194

# Echoes the source ref from a `git push` command, or empty if none found.
#
# Recognises:
#   git push origin <branch>                           → <branch>
#   git push origin <branch>:<remote-branch>           → <branch>  (LHS of refspec)
#   git push -u origin <branch>                        → <branch>
#   git push --set-upstream origin <branch>            → <branch>
#   git push --force origin <branch>                   → <branch>
#   git push --force-with-lease origin <branch>        → <branch>
#   git push origin HEAD                               → empty (HEAD is not a ref name we can validate)
#   git push                                           → empty (relies on upstream tracking)
#   git push origin                                    → empty (no ref given)
#   git push origin --delete <branch>                  → empty (deletion, no source-ref check)
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

  # Isolate the `git push ...` segment up to the first command separator
  # (|, ;, &&, &) so `git push origin foo && echo bar` doesn't pick up `echo`
  # tokens.
  push_segment=$(echo "$cmd" | grep -oE '\bgit\s+push\b[^|;&]*' | head -1)
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
  # The first non-flag, non-remote positional that isn't HEAD is the source ref.
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

  # `git push origin HEAD` — HEAD isn't a branch name we can validate; let the
  # caller fall back to local HEAD resolution.
  if [ "$ref" = "HEAD" ]; then
    echo ""
    return 0
  fi

  # Refspec form `<src>:<dst>` — the LHS is the branch the operator is pushing.
  # Strip the colon-and-after so `feature/GH-1-x:main` → `feature/GH-1-x`.
  ref="${ref%%:*}"

  # Strip any leading `+` (force-update marker on a refspec).
  ref="${ref#+}"

  # Strip leading `refs/heads/` if present — leave just the branch shorthand.
  ref="${ref#refs/heads/}"

  echo "$ref"
}
