#!/bin/bash
# _lib-pr-repo.sh — resolve the target repo of a `gh pr create` command and
# compare it against the current git working tree's origin remote.
#
# WHY THIS EXISTS
# ---------------
# Two PreToolUse hooks (`require-agdr-for-arch-pr.sh` and
# `validate-pr-create.sh`) compute diffs and tracker lookups against the
# session-pinned ops-fork. When the `gh pr create` command carries
# `--repo <owner/repo>` that differs from the ops-fork's origin, the hooks
# target the WRONG repo and false-positive (me2resh/apexyard#464).
#
# This library gives every PR-create hook a single, tested way to answer:
#   "Is the PR targeting the same repo this git working tree belongs to?"
#
# If the answer is "no", the hook is operating in a cross-repo context and
# must either skip the check or re-target the correct repo.
#
# PUBLIC FUNCTIONS
# ----------------
#   pr_cmd_target_repo <command>
#       Echoes the `owner/repo` slug from `--repo <slug>` in the command, or
#       empty string if the flag is absent.
#
#   git_origin_repo [<git-dir>]
#       Echoes the `owner/repo` slug for the `origin` remote of the git repo
#       rooted at <git-dir> (default: $PWD). Returns empty on failure.
#
#   pr_repo_matches_cwd <command> [<git-dir>]
#       Returns 0 if the PR target repo matches the git working tree's origin
#       (or if there is no `--repo` flag, in which case they implicitly match).
#       Returns 1 if they differ (cross-repo context).
#
#   pr_cmd_cd_target <command>
#       Echoes the path from a leading `cd <path> && …` (or `cd <path>; …`)
#       prefix in the command, or empty string if absent. Used by PR-create
#       hooks to discover the directory the `gh` call is ABOUT to run in — the
#       PreToolUse hook fires before the in-command `cd` executes, so the
#       hook's own cwd is NOT yet the PR's repo (me2resh/apexyard#669).
#
# USAGE
# -----
#   . "$(dirname "$0")/_lib-pr-repo.sh"
#   if ! pr_repo_matches_cwd "$COMMAND" "$REPO_ROOT"; then
#     # Cross-repo: cannot evaluate this check from current working tree.
#     exit 0
#   fi
#
# NOTES ON SCOPE
# --------------
# This library is intentionally narrow: it only resolves origin remotes to
# compare slugs. It does NOT walk the ops root, read project config, or touch
# session state — callers that need those must source the relevant libs.
#
# Normalisation: both remotes are normalised via _git_remote_to_slug so
# HTTPS and SSH URL formats compare equal for the same repo.

[ -n "${_LIB_PR_REPO_SOURCED:-}" ] && return 0
_LIB_PR_REPO_SOURCED=1

# Internal: parse `owner/repo` from a git remote URL.
# Handles:
#   git@github.com:owner/repo.git
#   https://github.com/owner/repo.git
#   https://github.com/owner/repo
#
# Uses two sed patterns (with optional .git suffix handled separately) for
# macOS POSIX-sed compatibility — the `?` quantifier is unreliable in BSD sed.
# Pattern 1: URL ends in .git → capture what comes before.
# Pattern 2: URL does NOT end in .git → capture the last two path components.
_git_remote_to_slug() {
  local url="$1"
  echo "$url" | sed -nE \
    's|.*[:/]([^/:]+/[^/]+)\.git$|\1|p; s|.*[:/]([^/:]+/[^/]+)$|\1|p' | head -1
}

# Internal: expand a leading `~` or `~user` in a path to an absolute path.
#
# WHY THIS EXISTS (me2resh/apexyard bug report, 2026-07)
# -------------------------------------------------------
# `pr_cmd_cd_target` extracts the literal path text from a `cd <path> && …`
# prefix. When the operator's command reads `cd ~/Projects/foo && gh pr
# create …`, the extracted path is the literal string `~/Projects/foo` — the
# shell would expand that tilde when it actually runs the `cd`, but this hook
# never runs a shell over the extracted string, it hands it straight to
# `git -C`. `git -C` does NOT perform tilde-expansion (it treats `~` as a
# literal directory-name character), so `git -C "~/Projects/foo"` fails
# silently, every caller's cd-target resolution comes back empty, and each
# hook falls back to its own cwd (typically the ops-fork root on `dev`) —
# producing misleading errors like "Branch 'dev' missing ticket ID" for a
# perfectly valid PR from a tilde-path worktree.
#
# This helper mirrors the shell's own tilde-expansion rules for the two forms
# that matter:
#   `~` / `~/...`       → the current user's $HOME
#   `~user` / `~user/…` → that user's home directory, resolved via `eval echo`
#                          ONLY after validating the extracted token looks
#                          like a real username (alnum/dot/dash/underscore) —
#                          refuses to eval anything that could smuggle shell
#                          metacharacters through the path text.
#
# Graceful fallback: if expansion cannot be resolved (unknown user, `eval`
# failure), the original string is returned unchanged rather than throwing —
# callers already treat an unresolvable `git -C` target as "can't check from
# here" and degrade non-misleadingly (skip/warn), so returning the original
# text preserves that existing, safe behaviour rather than fabricating a path.
#
# Security note (Hakim / PR #792 review): the username allowlist check below
# uses bash's `[[ =~ ]]` against the WHOLE string, anchored at both ends —
# deliberately NOT `grep -qE '^…$'`, which matches per LINE. A multi-line
# `$user` whose first line happens to look like a valid username would pass
# a per-line grep check and reach `eval` with the remaining lines still
# attached (a latent command-injection surface in a trust-chain hook). Not
# reachable through today's sole caller (`pr_cmd_cd_target`'s `sed` output is
# always single-line, further guaranteed by `head -1`), but this is a shared
# lib function — a future caller that skips that sanitization would open the
# hole `[[ =~ ]]` closes here for free (the whole-string anchor treats a
# newline as just another character the charset must match, so ANY embedded
# newline fails the check).
_pr_repo_expand_tilde() {
  local p="$1"
  # shellcheck disable=SC2088  # intentional: matching a literal leading '~'
  # in a case pattern, not asking the shell to expand it here.
  case "$p" in
    '~')
      printf '%s' "$HOME"
      ;;
    '~/'*)
      printf '%s' "$HOME/${p#\~/}"
      ;;
    '~'*)
      local rest user tail_part home
      rest="${p#\~}"
      user="${rest%%/*}"
      tail_part=""
      case "$rest" in
        */*) tail_part="/${rest#*/}" ;;
      esac
      if [[ "$user" =~ ^[A-Za-z0-9._-]+$ ]]; then
        home=$(eval echo "~${user}" 2>/dev/null)
        case "$home" in
          '~'*|'')
            printf '%s' "$p"  # unresolved (no such user) — return unchanged
            ;;
          *)
            printf '%s%s' "$home" "$tail_part"
            ;;
        esac
      else
        # Token doesn't look like a safe username — don't eval it.
        printf '%s' "$p"
      fi
      ;;
    *)
      printf '%s' "$p"
      ;;
  esac
}

# Public: pr_cmd_target_repo <command>
#   Echoes the owner/repo slug from the --repo / -R flag in the command.
#   Handles all four CLI forms:
#     --repo VALUE    --repo=VALUE    -R VALUE    -R=VALUE
#   Returns empty string when the flag is absent.
#   Strips an optional host prefix (e.g. github.com/owner/repo → owner/repo)
#   so the result is always a plain owner/repo slug.
#
#   Each form uses `.*[[:space:]]<FLAG><SEP>` (greedy, with a required leading
#   whitespace) so the flag boundary is honoured:
#     - `--repository me2resh/x` does NOT match `--repo ` (different flag)
#     - Flags in a quoted --body string are ignored in practice because `gh`
#       position-normalises flag order (--repo always precedes --body on the
#       command line as generated by the Claude Code harness).
#   BSD sed (macOS) is used throughout; the alternation-capture-group form
#   `(^|[[:space:]])…\2` is intentionally avoided because BSD sed does not
#   correctly output only group 2 when group 1 is the empty string from `^`.
pr_cmd_target_repo() {
  local cmd="$1"
  local raw
  # Form 1: --repo VALUE  (space-separated)
  raw=$(printf '%s' "$cmd" | sed -nE 's/.*[[:space:]]--repo[[:space:]]+([^[:space:]]+).*/\1/p' | head -1)
  # Form 2: --repo=VALUE  (equals-separated)
  if [ -z "$raw" ]; then
    raw=$(printf '%s' "$cmd" | sed -nE 's/.*[[:space:]]--repo=([^[:space:]]+).*/\1/p' | head -1)
  fi
  # Form 3: -R VALUE  (short alias, space-separated)
  if [ -z "$raw" ]; then
    raw=$(printf '%s' "$cmd" | sed -nE 's/.*[[:space:]]-R[[:space:]]+([^[:space:]]+).*/\1/p' | head -1)
  fi
  # Form 4: -R=VALUE  (short alias, equals-separated)
  if [ -z "$raw" ]; then
    raw=$(printf '%s' "$cmd" | sed -nE 's/.*[[:space:]]-R=([^[:space:]]+).*/\1/p' | head -1)
  fi
  # Strip optional host prefix (e.g. github.com/owner/repo → owner/repo).
  if [ -n "$raw" ]; then
    raw=$(printf '%s' "$raw" | sed -E 's|^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}/||')
  fi
  printf '%s' "$raw"
}

# Public: git_origin_repo [<git-dir>]
#   Echoes the owner/repo slug for the origin remote of the repo at <git-dir>.
git_origin_repo() {
  local git_dir="${1:-$PWD}"
  local url
  url=$(git -C "$git_dir" remote get-url origin 2>/dev/null) || return 1
  _git_remote_to_slug "$url"
}

# Public: pr_cmd_cd_target <command>
#   Echoes the path from a leading `cd <path> && …` / `cd <path>; …` prefix,
#   or empty string when the command does not start with a `cd`.
#
#   Only a `cd` at the START of the command is honoured (the harness-generated
#   `cd <repo> && gh pr …` pattern). A `cd` buried later in a pipeline is
#   intentionally ignored — it does not establish the directory the leading
#   `gh` runs in. Handles unquoted, single-quoted, and double-quoted paths so
#   `cd '../my repo' && …` resolves correctly.
pr_cmd_cd_target() {
  local cmd="$1"
  local raw
  # Strip leading whitespace, then match `cd ` followed by a quoted or bare
  # path up to the first `&&`, `;`, or `|` separator.
  raw=$(printf '%s' "$cmd" | sed -nE \
    "s/^[[:space:]]*cd[[:space:]]+\"([^\"]+)\"[[:space:]]*(&&|;|\|).*/\1/p;
     s/^[[:space:]]*cd[[:space:]]+'([^']+)'[[:space:]]*(&&|;|\|).*/\1/p;
     s/^[[:space:]]*cd[[:space:]]+([^&;|[:space:]]+)[[:space:]]*(&&|;|\|).*/\1/p" \
    | head -1)
  [ -z "$raw" ] && return 0
  # Expand a leading ~ / ~user before handing the path to any caller — git -C
  # does not shell-expand tilde itself (see _pr_repo_expand_tilde above).
  _pr_repo_expand_tilde "$raw"
}

# Public: pr_repo_matches_cwd <command> [<git-dir>]
#   Returns 0  when the PR target repo matches the working tree's origin,
#              OR when no --repo flag is present (implicit same-repo create).
#   Returns 1  when --repo is set and it differs from the origin slug.
#
# Callers use this to decide whether to apply repo-specific checks:
#
#   if ! pr_repo_matches_cwd "$COMMAND" "$REPO_ROOT"; then
#     exit 0   # cross-repo: cannot check from this cwd
#   fi
pr_repo_matches_cwd() {
  local cmd="$1"
  local git_dir="${2:-$PWD}"

  local cmd_repo
  cmd_repo=$(pr_cmd_target_repo "$cmd")

  # No --repo flag → implicit same-repo → match.
  if [ -z "$cmd_repo" ]; then
    return 0
  fi

  local origin_slug
  origin_slug=$(git_origin_repo "$git_dir")

  # If we can't resolve the origin, assume match (safe default — don't block
  # when we can't determine context). Emit a WARN so this degraded state is
  # visible rather than silent (me2resh/apexyard#464 review finding 3).
  if [ -z "$origin_slug" ]; then
    echo "WARN: _lib-pr-repo.sh: could not resolve origin remote for $git_dir — pr_repo_matches_cwd treating as same-repo (safe default, but cross-repo guard DEGRADED)." >&2
    return 0
  fi

  # Normalise both to lowercase for a case-insensitive GitHub comparison.
  local cmd_repo_lc origin_lc
  cmd_repo_lc=$(printf '%s' "$cmd_repo" | tr '[:upper:]' '[:lower:]')
  origin_lc=$(printf '%s' "$origin_slug" | tr '[:upper:]' '[:lower:]')

  if [ "$cmd_repo_lc" = "$origin_lc" ]; then
    return 0
  fi

  return 1
}
