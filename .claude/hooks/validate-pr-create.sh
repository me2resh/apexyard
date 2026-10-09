#!/bin/bash
# Validates PR creation:
# - PR title matches format: type(TICKET): description
# - PR body contains Summary, Testing, Glossary, and a ticket reference
# - Branch has a ticket ID
# - The ticket referenced in the title actually exists in the tracker repo
#   (backstop for the ticket-vocabulary rule — catches fabricated #N that
#   slipped through prose into a PR title)
#
# Customize the ticket pattern below if your team uses a different scheme.

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)

if [ -z "$COMMAND" ]; then
  exit 0
fi

# Keep the older broad scan: gh pr\<newline>create must remain visible,
# including pairs inside quoted data. Removal would hide the create verb.
. "$(dirname "${BASH_SOURCE[0]}")/_lib-awk-fallback.sh"
for fn in _run_awk_or_fallback join_shell_continuations _join_shell_continuations_fallback; do
  if ! declare -F "$fn" >/dev/null 2>&1; then
    printf 'BLOCKED: missing required awk helper %s. Restore _lib-awk-fallback.sh and retry.\n' "$fn" >&2
    exit 2
  fi
done
_vpc_join_fallback() {
  _join_shell_continuations_fallback "$1" broad-space
  return 1
}
_vpc_join_failed=0
if _vpc_joined=$(join_shell_continuations "$COMMAND" broad-space _vpc_join_fallback); then
  COMMAND=$_vpc_joined
else
  _vpc_join_failed=1
  COMMAND=$_vpc_joined
fi
unset _vpc_joined

# Parse --repo / -R from the gh command for cross-repo PR creation.
# Handles: --repo VALUE, --repo=VALUE, -R VALUE, -R=VALUE.
# Source _lib-pr-repo.sh when available (DRY — it owns the canonical parser).
# Inline fallback preserved for partial checkouts without the lib.
CMD_REPO=""
_VPC_HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$_VPC_HOOK_DIR/_lib-pr-repo.sh" ]; then
  # shellcheck source=/dev/null
  . "$_VPC_HOOK_DIR/_lib-pr-repo.sh"
  CMD_REPO=$(pr_cmd_target_repo "$COMMAND")
else
  # Inline fallback: handles all four forms without the lib.
  # Uses greedy `.*[[:space:]]<FLAG>` — see _lib-pr-repo.sh for the BSD-sed
  # rationale (alternation capture groups don't work reliably on macOS sed).
  CMD_REPO=$(printf '%s' "$COMMAND" | sed -nE 's/.*[[:space:]]--repo[[:space:]]+([^[:space:]]+).*/\1/p' | head -1)
  if [ -z "$CMD_REPO" ]; then
    CMD_REPO=$(printf '%s' "$COMMAND" | sed -nE 's/.*[[:space:]]--repo=([^[:space:]]+).*/\1/p' | head -1)
  fi
  if [ -z "$CMD_REPO" ]; then
    CMD_REPO=$(printf '%s' "$COMMAND" | sed -nE 's/.*[[:space:]]-R[[:space:]]+([^[:space:]]+).*/\1/p' | head -1)
  fi
  if [ -z "$CMD_REPO" ]; then
    CMD_REPO=$(printf '%s' "$COMMAND" | sed -nE 's/.*[[:space:]]-R=([^[:space:]]+).*/\1/p' | head -1)
  fi
  # Strip optional host prefix.
  if [ -n "$CMD_REPO" ]; then
    CMD_REPO=$(printf '%s' "$CMD_REPO" | sed -E 's|^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}/||')
  fi
fi

# Extract the cd-target early so it is available for --body-file path
# resolution below AND for the branch-name fallback near the end.
# pr_cmd_cd_target is provided by _lib-pr-repo.sh, sourced above.
CD_TARGET=""
if command -v pr_cmd_cd_target >/dev/null 2>&1; then
  CD_TARGET=$(pr_cmd_cd_target "$COMMAND")
fi

# Gate: only validate when the COMMAND HEAD is 'gh pr create'.
#
# Checking the raw command string (the pre-#743 approach) fires on any command
# whose --body inline content happens to mention "gh pr create" — for example,
# a bug-report filed via 'gh issue create --body "example: gh pr create ..."'.
# Stripping the body payload (--body / --body-file / -F and everything after)
# before the gate check means only the actual command verb is tested.
# Fixes apexyard#743 Bug 3.
#
# apexyard bug report (2026-07): stripping --body/--body-file/-F is NOT
# enough — the gate's match was an UNANCHORED substring grep
# ('\bgh pr create\b' with no position anchor), so any text ANYWHERE else in
# the command that happens to contain the words "gh pr create" also matched.
# The most common trigger: a `gh issue create --title '... gh pr create ...'`
# whose TITLE mentions the phrase (e.g. a bug report about this very hook) —
# --title is never stripped by the body-only cleanup above, so its content
# was fully exposed to the gate grep. Reproduced live: a `gh issue create`
# whose --title read "...gh pr create over-matches gh issue create..." was
# blocked with PR-only errors (title-format, missing ## Testing/## Glossary)
# even though the invoked command was `gh issue create`, not `gh pr create`.
#
# Fix: anchor the match to the actual command HEAD — "gh pr create" must be
# the verb actually being invoked (immediately at the start of the command,
# or immediately after a leading `cd <path> &&` / `cd <path>;` prefix), not
# merely present as a substring anywhere in a flag's value.
#
# Hakim's security review of the anchor fix (PR #792) flagged a MEDIUM
# completeness regression: anchoring to the head after stripping only ONE
# leading `cd … &&` prefix means a genuine `gh pr create` behind any OTHER
# prefix now SKIPS validation where the old (unanchored) gate caught it —
# `FOO=bar gh pr create`, `time gh pr create`, `cd a && cd b && gh pr create`
# (double cd), `X && gh pr create` (any non-cd prefix). That's a real
# completeness regression, not just a hardening nice-to-have.
#
# Fix (round 1, since superseded — see below): loop the prefix-strip over
# four bounded, mutually-exclusive prefix shapes until a fixed point (or a
# small iteration ceiling), THEN anchor:
#   1. `cd <path> (&&|;|\|)`               — quoted or bare path (as before)
#   2. `VAR=value ` (one or more)          — leading env-var assignment(s)
#   3. `time|command|nice|env `            — common command wrappers
#   4. `<quote-free segment> (&&|;|\|)`    — a generic chained prefix
#
# Hakim's SECOND security re-review of that fix (still PR #792) found a NEW
# blocking regression in shape 4: applying all four shapes unconditionally
# in every iteration, THEN checking the head only once the loop finished,
# let shape 4 consume a genuine verb the moment it sat at the head followed
# by a trailing separator — `gh pr create --fill --head br && echo done`,
# `gh pr create --title fixbug --head br; echo x`, `gh pr create --head br
# | cat` all got their own verb stripped as a "chained prefix" and the gate
# silently skipped validation (exit 0). Confirmed live against the real
# hook.
#
# Fix (round 2 — CHECK-THEN-STRIP): move the verb check to the TOP of every
# loop iteration and evaluate it BEFORE any of the four strip shapes run
# that iteration. The moment the current head already IS "gh pr create …",
# the loop stops and the gate fires immediately — it never reaches shape 4
# (or any shape) with the verb still sitting at the head, so the verb can
# never be stripped as if it were a prefix. Only when the head is NOT yet
# the verb do we attempt exactly ONE strip shape (in priority order 1-4)
# and loop back to the top to re-check. This costs a few more iterations
# for multi-prefix inputs (e.g. double `cd` now takes two passes instead of
# one) but the 10-iteration ceiling comfortably covers realistic prefix
# depths, and correctness — never eating the verb — matters more than
# iteration-count elegance here.
#
# Shape 4 is still the one that needs care: naively scanning for "gh pr
# create" at the head of ANY `&&`-delimited segment (rather than stripping
# bounded prefixes) is exactly what reintroduces the original over-match —
# a `--title '... && ...'` value containing a literal `&&` would get its
# quoted content misread as a chain of commands. Shape 4 avoids that by
# requiring the stripped segment to contain NO quote characters
# (`[^"'&;|]+`) — a quoted flag value always contains a quote character
# before the first genuine separator, so a segment carrying one is never
# eligible for this strip; it also naturally stops at the first real `&&`,
# `;`, or `|` because those characters are excluded from the segment's own
# character class. A bounded iteration ceiling (10) guards against any
# pathological input looping unboundedly; beyond the ceiling the gate fails
# OPEN (skips validation) rather than hanging or false-blocking, which is
# the safe direction for a completeness backstop like this one.
_cmd_for_gate=$(printf '%s' "$COMMAND" \
  | sed -E 's/[[:space:]]--body-file[[:space:]].*//' \
  | sed -E 's/[[:space:]]--body[[:space:]].*//' \
  | sed -E 's/[[:space:]]-F[[:space:]].*//')
_cmd_head="$_cmd_for_gate"
_gate_iter=0
_gate_fired=0
while [ "$_gate_iter" -lt 10 ]; do
  # CHECK before STRIP: if the current head already IS the pr-create verb,
  # stop right here and fire — this must happen before ANY of the four
  # strip shapes run this iteration. Checking only after a full pass of
  # stripping (the round-1 structure) is what let shape 4 consume a verb
  # that had just become the head as a side effect of an earlier shape in
  # the SAME iteration (or was the head from the very start, for a
  # prefix-free genuine invocation like `gh pr create ... && echo done`).
  if printf '%s' "$_cmd_head" | grep -qE '^[[:space:]]*gh[[:space:]]+pr[[:space:]]+create\b'; then
    _gate_fired=1
    break
  fi

  _cmd_head_prev="$_cmd_head"

  # Try exactly ONE strip shape this iteration, in priority order, then
  # loop back to the top so the verb-check above runs again before any
  # later shape gets a chance at the newly-shortened head. This is the
  # structural change from round 1 (which ran all four shapes every
  # iteration, unconditionally) to round 2 (check-then-strip).

  # 1. cd <path> && / || / ; / | -- quoted or bare path.
  #    Match `||` before `|` so a double-pipe chain is not left with a
  #    leading `|` that hides a later `gh pr create` (#1451 B1-c).
  _stripped=$(printf '%s' "$_cmd_head" | sed -E \
    "s/^[[:space:]]*cd[[:space:]]+\"[^\"]+\"[[:space:]]*(&&|\|\||;|\|)[[:space:]]*//;
     s/^[[:space:]]*cd[[:space:]]+'[^']+'[[:space:]]*(&&|\|\||;|\|)[[:space:]]*//;
     s/^[[:space:]]*cd[[:space:]]+[^&;|[:space:]]+[[:space:]]*(&&|\|\||;|\|)[[:space:]]*//")
  if [ "$_stripped" != "$_cmd_head" ]; then
    _cmd_head="$_stripped"
  else
    # 2. Leading env-var assignment(s): FOO=bar BAZ=qux <rest>.
    _stripped=$(printf '%s' "$_cmd_head" | sed -E \
      "s/^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+//")
    if [ "$_stripped" != "$_cmd_head" ]; then
      _cmd_head="$_stripped"
    else
      # 3. Common command wrappers.
      _stripped=$(printf '%s' "$_cmd_head" | sed -E \
        "s/^[[:space:]]*(time|command|nice|env)[[:space:]]+//")
      if [ "$_stripped" != "$_cmd_head" ]; then
        _cmd_head="$_stripped"
      else
        # 4. A quote-free arbitrary segment followed by a top-level
        #    separator — last resort, only tried once shapes 1-3 (and the
        #    verb-check above) have already failed to match this
        #    iteration's head. `||` before `|` (same as shape 1).
        _cmd_head=$(printf '%s' "$_cmd_head" | sed -E \
          "s/^[[:space:]]*[^\"'&;|]+(&&|\|\||;|\|)[[:space:]]*//")
      fi
    fi
  fi

  [ "$_cmd_head" = "$_cmd_head_prev" ] && break
  _gate_iter=$((_gate_iter + 1))
done
if [ "$_gate_fired" -ne 1 ] && [ "$_vpc_join_failed" -eq 0 ]; then
  unset _cmd_for_gate _cmd_head _cmd_head_prev _gate_iter _gate_fired _stripped
  exit 0
fi
unset _cmd_for_gate _cmd_head _cmd_head_prev _gate_iter _gate_fired _stripped

ERRORS=""
if [ "$_vpc_join_failed" -ne 0 ]; then
  # The broad tr fallback can alter title or path text. Continue validation,
  # but never accept a command after its exact normalization failed.
  ERRORS="${ERRORS}Could not normalize command text safely. Retry PR creation.\n"
fi
unset _vpc_join_failed

# Extract --title value (macOS-compatible, no grep -P).
#
# Kept as the original non-greedy `[^"']*` form: PR titles are short,
# single-line, and conventionally do NOT contain embedded `"` or `'`
# (they're command-line arguments and gh would have shell-escape
# friction). The greedy + flag-boundary fix used in the body extractors
# (me2resh/apexyard#227) is NOT applied here on purpose — when the
# command has a multi-line `--body "$(cat <<'EOF' ... EOF)"` after the
# title, greedy match over-consumes the body content as part of the
# title value. Non-greedy is correct for this position.
TITLE=$(echo "$COMMAND" | sed -n 's/.*--title[[:space:]]*["'"'"']\([^"'"'"']*\)["'"'"'].*/\1/p' | head -1)
if [ -z "$TITLE" ]; then
  TITLE=$(echo "$COMMAND" | sed -n 's/.*--title[[:space:]]*\([^[:space:]]*\).*/\1/p' | head -1)
fi

# Validate PR title format if we can extract it
# Accepts: type(<TICKET>): … or type(<TICKET>)!: … (breaking change)
# The !? makes the breaking-change marker optional per Conventional Commits 1.0.
#
# The accepted type list is project-configurable via .claude/project-config.json
# (.pr.title_type_whitelist). Defaults ship at .claude/project-config.defaults.json.
# See apexyard#109.
#
# Resolve the directory holding the config:
#   - HOOK_DIR points at the lib files (always next to this script).
#   - CONFIG_ROOT is the ops fork (where .claude/project-config.json lives).
#     When the operator runs inside workspace/<project>/, `git rev-parse
#     --show-toplevel` resolves to the project clone, NOT the ops fork —
#     resulting in tracker.kind defaulting to "gh" even when the operator
#     configured Linear / Jira / Asana / custom (me2resh/apexyard#310).
#     `_lib-ops-root.sh` walks up to the ops-fork anchor (v2 marker or v1
#     pair) and is the right primitive.
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
CONFIG_ROOT=""
if [ -f "$HOOK_DIR/_lib-ops-root.sh" ]; then
  # shellcheck disable=SC1090,SC1091
  . "$HOOK_DIR/_lib-ops-root.sh"
  CONFIG_ROOT=$(resolve_ops_root "$PWD")
fi
if [ -z "$CONFIG_ROOT" ]; then
  CONFIG_ROOT="$REPO_ROOT"
fi
PR_TYPES=""
if [ -f "$HOOK_DIR/_lib-read-config.sh" ]; then
  # shellcheck disable=SC1090,SC1091
  . "$HOOK_DIR/_lib-read-config.sh"
  PR_TYPES=$(config_get '.pr.title_type_whitelist[]' 2>/dev/null | paste -sd'|' -)
fi
if [ -z "$PR_TYPES" ]; then
  PR_TYPES="feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert|release|spike|sync"
fi

# External contributions (#1448): a PR aimed at a repository the adopter
# contributes to but does NOT govern. Such a repository has its own
# CONTRIBUTING.md and its own tracker, so imposing this framework's title
# convention on it refuses a PR that is correct for its destination.
#
# Opt-in and repo-scoped: `.external_contributions[]` in project-config, the
# same shape leak-protection uses for its public-framework-repo list.
#
# The registry WINS. If the target is a managed project, the exemption does
# not apply however the list is written — otherwise adding a governed repo to
# this list would quietly disable title validation for work the framework is
# supposed to be governing, which is a gate relaxation dressed up as config.
#
# Helpers for this block only (#1451 B1-b / B1-c / B2-b / A-2).

# Normalise a repo reference to lowercase owner/name. Strips scheme,
# git@host:, bare host/, trailing .git, and trailing /. Echoes nothing when
# the result is not exactly owner/name (caller decides whether to warn).
_vpc_normalize_repo_slug() {
  local s
  s=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  s=$(printf '%s' "$s" | sed -E 's|^[a-z][a-z0-9+.-]*://||')
  s=$(printf '%s' "$s" | sed -E 's|^git@[^:]+:||')
  s=$(printf '%s' "$s" | sed -E 's|^[a-z0-9.-]+\.[a-z]{2,}/||')
  s=$(printf '%s' "$s" | sed -E 's|\.git$||')
  s=$(printf '%s' "$s" | sed -E 's|/$||')
  if printf '%s' "$s" | grep -qE '^[^/]+/[^/]+$'; then
    printf '%s' "$s"
  fi
}

# Echo the PR-create SEGMENT of a quote-blanked first line (#1451 B1-c).
# Starts at the `gh pr create` invocation and ends at the next top-level
# `&&`, `||`, `;`, `|`, or end of line. A trailing unquoted `#` comment
# (a `#` that starts a shell word) is stripped so a comment mentioning
# `--repo` cannot grant the exemption. Echoes nothing when no create verb
# is present on the line.
_vpc_pr_create_segment() {
  # Portable word-boundary after "create": macOS awk (nawk) has no `\b`.
  printf '%s' "$1" | awk '
    {
      line = $0
      if (!match(line, /(^|[[:space:]])gh[[:space:]]+pr[[:space:]]+create([^a-zA-Z0-9_]|$)/)) next
      start = RSTART
      if (substr(line, start, 1) ~ /[[:space:]]/) start++
      seg = substr(line, start)
      out = ""
      n = length(seg)
      i = 1
      while (i <= n) {
        two = substr(seg, i, 2)
        if (two == "&&" || two == "||") break
        c = substr(seg, i, 1)
        if (c == ";" || c == "|") break
        out = out c
        i++
      }
      if (match(out, /(^|[[:space:]])#/)) {
        if (RSTART == 1) out = ""
        else out = substr(out, 1, RSTART - 1)
      }
      print out
    }
  '
}

EXTERNAL_TARGET=""
if [ -n "$CMD_REPO" ] && command -v config_get >/dev/null 2>&1; then
  # CMD_REPO is pr_cmd_target_repo's continuation-joined parse — the repo
  # the CLI will actually use. Normalise it before any list/registry match
  # (#1451 B2-b): URL and SSH forms must become owner/name or the registry-
  # wins rail never fires.
  _vpc_repo_lc=$(_vpc_normalize_repo_slug "$CMD_REPO")

  # FAIL CLOSED on an ambiguous / body-injected target (#1451 B1 / B1-b / B1-c).
  # Quote-blanking is line-oriented, so a multi-line --body heredoc left a
  # `--repo` token on a later line visible to a whole-command scan, and
  # CMD_REPO could be set from body text while the real create targeted the
  # governed cwd. Take the exemption candidate ONLY from the PR-create
  # SEGMENT of the command's first line (from `gh pr create` to the next
  # unquoted `&&` / `||` / `;` / `|` / newline, with trailing `#` comments
  # stripped), with quoted spans blanked there, and require that candidate
  # to equal CMD_REPO after the same normalisation. A prior `gh pr view
  # --repo … &&` or a trailing `# … --repo …` comment must not grant the
  # exemption. Reuse pr_cmd_target_repo for the segment value so there is
  # one parser. If the segment target cannot be resolved unambiguously,
  # no exemption.
  _vpc_ambiguous=""
  if [ -z "$_vpc_repo_lc" ]; then
    # CMD_REPO did not normalise to owner/name — cannot match the list safely.
    _vpc_ambiguous="1"
  else
    _vpc_first_line=$(printf '%s\n' "$COMMAND" | head -n 1)
    _vpc_first_unquoted=$(printf '%s' "$_vpc_first_line" \
      | sed -E 's/"[^"]*"/""/g; s/'"'"'[^'"'"']*'"'"'/'"''"'/g')
    _vpc_create_seg=$(_vpc_pr_create_segment "$_vpc_first_unquoted")
    if [ -z "$_vpc_create_seg" ]; then
      _vpc_ambiguous="1"
    else
      # Exactly one --repo/-R flag on the create segment, outside quotes.
      _vpc_repo_tokens=$(printf '%s\n' "$_vpc_create_seg" \
        | grep -oE '(^|[[:space:]])(--repo|-R)([[:space:]]+|=)' | wc -l | tr -d ' ')
      if [ "${_vpc_repo_tokens:-0}" != "1" ]; then
        _vpc_ambiguous="1"
      else
        _vpc_first_repo=""
        if command -v pr_cmd_target_repo >/dev/null 2>&1; then
          # Leading space satisfies pr_cmd_target_repo's flag-boundary sed.
          _vpc_first_repo=$(pr_cmd_target_repo " ${_vpc_create_seg}")
        else
          _vpc_first_repo=$(printf '%s' "$_vpc_create_seg" \
            | sed -nE 's/.*[[:space:]]--repo[[:space:]]+([^[:space:]]+).*/\1/p' | head -1)
          if [ -z "$_vpc_first_repo" ]; then
            _vpc_first_repo=$(printf '%s' "$_vpc_create_seg" \
              | sed -nE 's/.*[[:space:]]--repo=([^[:space:]]+).*/\1/p' | head -1)
          fi
          if [ -z "$_vpc_first_repo" ]; then
            _vpc_first_repo=$(printf '%s' "$_vpc_create_seg" \
              | sed -nE 's/.*[[:space:]]-R[[:space:]]+([^[:space:]]+).*/\1/p' | head -1)
          fi
          if [ -z "$_vpc_first_repo" ]; then
            _vpc_first_repo=$(printf '%s' "$_vpc_create_seg" \
              | sed -nE 's/.*[[:space:]]-R=([^[:space:]]+).*/\1/p' | head -1)
          fi
        fi
        _vpc_first_repo_lc=$(_vpc_normalize_repo_slug "$_vpc_first_repo")
        # Must equal the CLI target. A body-only --repo makes CMD_REPO non-empty
        # while the create segment has none (or a different flag) — refuse.
        if [ -z "$_vpc_first_repo_lc" ] || [ "$_vpc_first_repo_lc" != "$_vpc_repo_lc" ]; then
          _vpc_ambiguous="1"
        fi
      fi
    fi
  fi

  if [ -z "$_vpc_ambiguous" ]; then
    # The registry WINS, and the check must cover every registry shape the
    # framework supports: `repo: x`, a block `repos:` list, an inline
    # `repos: [a, b]`, and any of those with a trailing comment (#1451 B2).
    # A hand-rolled grep missed the inline and commented forms, so reuse the
    # registry parser instead — its field 6 lists every repo for an entry.
    # Compare normalised owner/name slugs (#1451 B2-b).
    _vpc_governed=""
    if [ -f "$HOOK_DIR/_lib-portfolio-paths.sh" ]; then
      # shellcheck disable=SC1090,SC1091
      . "$HOOK_DIR/_lib-portfolio-paths.sh"
    fi
    if [ -f "$HOOK_DIR/_lib-multi-repo-trace.sh" ]; then
      # shellcheck disable=SC1090,SC1091
      . "$HOOK_DIR/_lib-multi-repo-trace.sh"
    fi
    if command -v _mrt_parse_registry >/dev/null 2>&1; then
      _vpc_all_repos=""
      while IFS= read -r _vpc_reg_raw; do
        [ -n "$_vpc_reg_raw" ] || continue
        _vpc_reg_raw=$(printf '%s' "$_vpc_reg_raw" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        _vpc_reg_lc=$(_vpc_normalize_repo_slug "$_vpc_reg_raw")
        if [ -z "$_vpc_reg_lc" ]; then
          echo "NOTE: validate-pr-create.sh: ignoring registry repo entry '$_vpc_reg_raw' (not owner/name after normalisation)." >&2
          continue
        fi
        _vpc_all_repos=$(printf '%s\n%s' "$_vpc_all_repos" "$_vpc_reg_lc")
      done <<EOF
$(_mrt_parse_registry 2>/dev/null | cut -d'|' -f6 | tr ',' '\n')
EOF
      case "
$_vpc_all_repos
" in
        *"
$_vpc_repo_lc
"*) _vpc_governed="1" ;;
      esac
    else
      # No parser available: fail closed rather than exempt on a registry we
      # could not read (#1451 B2, suggested). An unreadable registry must not
      # be indistinguishable from an empty one.
      _vpc_governed="1"
    fi

    if [ -z "$_vpc_governed" ]; then
      # A-2: listing this checkout's own origin must not disable the local
      # title check. Resolve origin once; ignore matching list entries.
      _vpc_origin_lc=""
      if command -v git_origin_repo >/dev/null 2>&1; then
        _vpc_origin_lc=$(_vpc_normalize_repo_slug "$(git_origin_repo "$PWD" 2>/dev/null || true)")
      fi
      while IFS= read -r _vpc_listed; do
        [ -n "$_vpc_listed" ] || continue
        _vpc_listed_lc=$(_vpc_normalize_repo_slug "$_vpc_listed")
        if [ -z "$_vpc_listed_lc" ]; then
          echo "NOTE: validate-pr-create.sh: ignoring external_contributions entry '$_vpc_listed' (not owner/name after normalisation)." >&2
          continue
        fi
        if [ -n "$_vpc_origin_lc" ] && [ "$_vpc_listed_lc" = "$_vpc_origin_lc" ]; then
          echo "NOTE: validate-pr-create.sh: ignoring external_contributions entry '$_vpc_listed' (matches this checkout's origin; cannot disable the local title check)." >&2
          continue
        fi
        if [ "$_vpc_listed_lc" = "$_vpc_repo_lc" ]; then
          EXTERNAL_TARGET="1"
          break
        fi
      done <<EOF
$(config_get '.external_contributions[]' 2>/dev/null)
EOF
    fi
  fi
  unset _vpc_repo_lc _vpc_ambiguous _vpc_first_line _vpc_first_unquoted \
        _vpc_create_seg _vpc_repo_tokens _vpc_first_repo _vpc_first_repo_lc \
        _vpc_governed _vpc_all_repos _vpc_reg_raw _vpc_reg_lc _vpc_listed \
        _vpc_listed_lc _vpc_origin_lc
fi

TICKET_REF=""
if [ -n "$EXTERNAL_TARGET" ]; then
  echo "NOTE: validate-pr-create.sh: ${CMD_REPO} is listed in .external_contributions — this framework's PR-title convention is not applied. Follow that project's own CONTRIBUTING.md." >&2
elif [ -n "$TITLE" ]; then
  if ! echo "$TITLE" | grep -qE "^(${PR_TYPES})\(([A-Z]{2,10}-[0-9]+|#[0-9]+)\)!?:"; then
    ERRORS="${ERRORS}PR title '$TITLE' doesn't match format: type(TICKET-ID): description\n"
    ERRORS="${ERRORS}Accepted types (from .claude/project-config.*.json → .pr.title_type_whitelist): ${PR_TYPES//|/, }\n"
  else
    # Extract the ticket reference so we can verify it exists
    TICKET_REF=$(echo "$TITLE" | sed -nE 's/^[a-z]+\(([^)]+)\):.*/\1/p')
  fi
fi

# Verify the ticket in the title actually exists in the tracker
# (backstop for ticket-vocabulary.md — catches fabricated #N in PR titles).
#
# Tracker-aware: uses `_lib-tracker.sh` for the existence check. Default
# config (tracker.kind = gh) preserves today's behaviour exactly: dispatches
# to `gh issue view --repo <owner/repo>`, with the upstream-fallback step
# for fork → upstream PRs (#207). When the adopter has configured Linear /
# Jira / Asana / custom, the tracker lib calls THAT CLI instead; for those
# kinds the `--repo` and upstream concepts may not apply, so the upstream
# fallback is skipped. `tracker.kind = none` short-circuits the existence
# check (caller falls back to shape-only via `tracker_id_pattern`).
if [ -n "$TICKET_REF" ]; then
  # Extract digits from the ref (works for both #N and PREFIX-N)
  TICKET_NUM=$(echo "$TICKET_REF" | grep -oE '[0-9]+$')

  # Resolve tracker repo FIRST (before the kind lookup): prefer --repo flag,
  # then ops-fork-rooted project-config.json (.tracker_repo), then origin
  # remote of the current cwd's git checkout. The ops-fork-rooted read matters
  # when the operator is inside workspace/<project>/ — the project clone's git
  # root is NOT where the framework config lives. Resolved up front so the kind
  # lookup below can key off the target repo for a per-project override (#670).
  TRACKER_REPO=""
  if [ -n "$CMD_REPO" ]; then
    TRACKER_REPO="$CMD_REPO"
  elif [ -n "$CONFIG_ROOT" ] && [ -f "${CONFIG_ROOT}/.claude/project-config.json" ]; then
    TRACKER_REPO=$(jq -r '.tracker_repo // empty' "${CONFIG_ROOT}/.claude/project-config.json" 2>/dev/null)
  fi
  if [ -z "$TRACKER_REPO" ]; then
    # Parse owner/repo from origin remote
    ORIGIN_URL=$(git remote get-url origin 2>/dev/null)
    TRACKER_REPO=$(echo "$ORIGIN_URL" | sed -nE 's|.*[:/]([^/:]+/[^/]+)\.git$|\1|p; s|.*[:/]([^/:]+/[^/]+)$|\1|p' | head -1)
  fi

  # Load the tracker library (kind / view command / id pattern).
  # Source from HOOK_DIR so we don't depend on cwd-relative resolution
  # (inside workspace/<project>/ the lib still lives at the ops fork). The
  # lib itself reads config via _lib-read-config.sh which now resolves
  # from the ops fork too (me2resh/apexyard#310). The kind is resolved for
  # TRACKER_REPO so a per-project override wins over the global block (#670).
  TRACKER_KIND="gh"
  if [ -f "$HOOK_DIR/_lib-tracker.sh" ]; then
    # shellcheck disable=SC1090,SC1091
    . "$HOOK_DIR/_lib-tracker.sh"
    TRACKER_KIND=$(tracker_kind "$TRACKER_REPO")
  fi

  # Short-circuit: existence verification disabled.
  if [ "$TRACKER_KIND" = "none" ]; then
    # Shape-only validation already happened above (PR title regex). Nothing
    # more to do for this branch.
    TICKET_NUM=""
  fi

  # Optional upstream fallback (me2resh/apexyard#207). When the primary
  # tracker resolution returns nothing for #N, recheck against the `upstream`
  # remote if one is configured. Lets a fork's `fix(#N)` validate when the
  # ticket lives on upstream and the PR targets upstream — and avoids the
  # cross-repo workaround (`fix(owner/repo#N)`) that passes the hook but
  # breaks GitHub's bare-#N auto-close on merge.
  #
  # The upstream fallback only makes sense for the gh kind — Linear / Jira /
  # Asana don't have a fork-of-a-tracker concept.
  #
  # Cross-repo guard (me2resh/apexyard#464): when `--repo` is set and the PR
  # targets a repo that is NOT a fork of the current git tree's upstream, the
  # fallback would resolve to an UNRELATED repo (e.g. session pinned to the
  # ops-fork; --repo points at a sibling repo; upstream remote of the ops-fork
  # returns me2resh/apexyard, which has no relation to the sibling PR). Suppress
  # the upstream fallback in that case by checking whether TRACKER_REPO shares
  # the upstream lineage (either it IS the upstream, or the upstream IS a fork
  # of it). If TRACKER_REPO matches neither origin nor upstream → cross-repo
  # context → no fallback.
  UPSTREAM_REPO=""
  if [ "$TRACKER_KIND" = "gh" ] && git remote get-url upstream >/dev/null 2>&1; then
    UPSTREAM_URL=$(git remote get-url upstream 2>/dev/null)
    UPSTREAM_REPO=$(echo "$UPSTREAM_URL" | sed -nE 's|.*[:/]([^/:]+/[^/]+)\.git$|\1|p; s|.*[:/]([^/:]+/[^/]+)$|\1|p' | head -1)
    # Skip the redundant check when upstream resolves to the same repo as
    # the primary tracker (running inside the framework itself, or when
    # --repo on the gh command points at upstream directly).
    if [ "$UPSTREAM_REPO" = "$TRACKER_REPO" ]; then
      UPSTREAM_REPO=""
    fi
    # Cross-repo guard (#464): if the primary TRACKER_REPO was set via the
    # --repo flag (CMD_REPO is non-empty), it means the operator explicitly
    # named the target repo. Only allow the upstream fallback when the
    # explicitly-named target is "related" to this git tree's remotes —
    # i.e. TRACKER_REPO equals the current origin slug OR equals the
    # upstream slug. When it matches neither, the `upstream` remote of the
    # current working tree belongs to a completely different project lineage
    # and must not be consulted as a ticket-existence fallback.
    if [ -n "$CMD_REPO" ] && [ -n "$UPSTREAM_REPO" ]; then
      ORIGIN_SLUG_VAL=""
      if [ -f "$HOOK_DIR/_lib-pr-repo.sh" ]; then
        # shellcheck source=/dev/null
        . "$HOOK_DIR/_lib-pr-repo.sh"
        ORIGIN_SLUG_VAL=$(git_origin_repo "$REPO_ROOT")
      else
        # _lib-pr-repo.sh is missing (partial checkout or manual hook copy
        # without the lib). Fall back to inline slug extraction. This is a
        # degraded state — emit a visible warning so the operator knows the
        # cross-repo guard is running without its purpose-built library
        # (me2resh/apexyard#464). The inline fallback preserves the guard
        # logic, so the protection is not silently lost.
        echo "WARN: validate-pr-create.sh: _lib-pr-repo.sh not found at $HOOK_DIR — cross-repo guard running with inline fallback. Ensure _lib-pr-repo.sh is present alongside this hook for full coverage." >&2
        _RAW_ORIGIN=$(git remote get-url origin 2>/dev/null)
        ORIGIN_SLUG_VAL=$(echo "$_RAW_ORIGIN" | sed -nE 's|.*[:/]([^/:]+/[^/]+)\.git$|\1|p; s|.*[:/]([^/:]+/[^/]+)$|\1|p' | head -1)
      fi
      # Normalise to lowercase for comparison (GitHub repos are case-insensitive).
      CMD_REPO_LC=$(printf '%s' "$CMD_REPO" | tr '[:upper:]' '[:lower:]')
      ORIGIN_LC=$(printf '%s' "$ORIGIN_SLUG_VAL" | tr '[:upper:]' '[:lower:]')
      UPSTREAM_LC=$(printf '%s' "$UPSTREAM_REPO" | tr '[:upper:]' '[:lower:]')
      # Allow fallback only when the PR targets the origin or its upstream.
      if [ "$CMD_REPO_LC" != "$ORIGIN_LC" ] && [ "$CMD_REPO_LC" != "$UPSTREAM_LC" ]; then
        # The PR is targeting a completely different repo lineage.
        # Suppress the upstream fallback to avoid cross-repo false lookups.
        UPSTREAM_REPO=""
      fi
    fi
  fi

  if [ -n "$TICKET_NUM" ] && { [ "$TRACKER_KIND" != "gh" ] || [ -n "$TRACKER_REPO" ]; }; then
    # Capture the tracker CLI's own stderr instead of discarding it, so the
    # paths below that block or warn can name the real cause (#1336). The
    # upstream lookup overwrites the file, so what survives is the LAST failed
    # lookup — the quieter of the two options, and the one the two-step lookup
    # (#207) needs: an ordinary fork-then-upstream miss resolves successfully
    # and never reaches a branch that reads the file.
    # Redirect to /dev/null when mktemp fails, rather than to an empty path,
    # which bash reports as an ambiguous redirect on every lookup. The trap is
    # set ONLY when mktemp succeeded: an unconditional trap would run
    # `rm -f /dev/null`, which under root removes the device node and turns
    # every later redirect to /dev/null on that host into a regular file.
    if TRACKER_ERR=$(mktemp); then
      trap 'rm -f "$TRACKER_ERR"' EXIT
    else
      TRACKER_ERR=/dev/null
    fi
    # Dispatch via the tracker lib. For non-gh kinds the {owner_repo}
    # placeholder is supplied but the template may not reference it.
    ISSUE_JSON=$(tracker_view "$TICKET_NUM" "$TRACKER_REPO" 2>"$TRACKER_ERR")
    # Short-circuit: only consult upstream (gh only) when primary missed.
    # Records which tracker actually matched so the CLOSED-state error names
    # the right repo.
    MATCHED_REPO="$TRACKER_REPO"
    if [ -z "$ISSUE_JSON" ] && [ -n "$UPSTREAM_REPO" ]; then
      ISSUE_JSON=$(tracker_view "$TICKET_NUM" "$UPSTREAM_REPO" 2>"$TRACKER_ERR")
      if [ -n "$ISSUE_JSON" ]; then
        MATCHED_REPO="$UPSTREAM_REPO"
      fi
    fi
    if [ -z "$ISSUE_JSON" ] && [ "$TRACKER_KIND" != "gh" ]; then
      # Non-gh tracker (Linear / Jira / Asana / custom) returned nothing — the
      # tracker CLI is absent, unauthenticated, or not queryable from this
      # environment (#501). Do NOT block: the title already passed the shape
      # check against tracker_id_pattern, which is all we can assert without a
      # working CLI. Blocking here would make it impossible to open a PR that
      # references a real, valid non-GitHub ticket. Hard existence enforcement
      # is retained ONLY for tracker.kind == gh (the block below).
      echo "WARN: validate-pr-create.sh: tracker '${TRACKER_KIND}' not queryable here — ${TICKET_REF} accepted on shape only (no existence check)." >&2
      if [ -s "$TRACKER_ERR" ]; then
        echo "Tracker CLI said:" >&2
        sed 's/^/  /' "$TRACKER_ERR" >&2
      fi
      ISSUE_JSON=""
      TICKET_NUM=""
    elif [ -z "$ISSUE_JSON" ]; then
      # Name both trackers in the error when an upstream fallback was tried,
      # so the operator sees exactly where the lookup was attempted.
      if [ -n "$UPSTREAM_REPO" ]; then
        NOT_FOUND_LOC="${TRACKER_REPO} or upstream ${UPSTREAM_REPO}"
      else
        NOT_FOUND_LOC="${TRACKER_REPO}"
      fi
      cat >&2 <<MSG
BLOCKED: PR title references ${TICKET_REF} but issue #${TICKET_NUM} does not
exist in ${NOT_FOUND_LOC}.

This is the failure mode the ticket-vocabulary rule exists to prevent — do NOT
use tracker notation (#N) for plan items that have no real issue behind them.
See .claude/rules/ticket-vocabulary.md § "The rule".

If you intended to create the PR for a real ticket, verify the number.
If you were about to file work that has no ticket yet, create one first:
  gh issue create --repo ${TRACKER_REPO} --title "..."
and use the returned number in your PR title.
MSG
      if [ -s "$TRACKER_ERR" ]; then
        echo "Tracker CLI said:" >&2
        sed 's/^/  /' "$TRACKER_ERR" >&2
      fi
      exit 2
    fi

    ISSUE_STATE=$(echo "$ISSUE_JSON" | jq -r '.state // empty' 2>/dev/null)
    # Closed-state recognition is tracker-specific. gh: "CLOSED". Asana: "Closed".
    # Linear / Jira: "Done", "Closed", "Cancelled", "Resolved" etc. — list the
    # common closed states so non-gh adopters get the same gate as gh adopters.
    ISSUE_STATE_LC=$(echo "$ISSUE_STATE" | tr '[:upper:]' '[:lower:]')
    case "$ISSUE_STATE_LC" in
      closed|done|cancelled|canceled|resolved|completed)
        IS_CLOSED=1 ;;
      *)
        IS_CLOSED=0 ;;
    esac
    if [ "$IS_CLOSED" = "1" ]; then
      cat >&2 <<MSG
BLOCKED: PR title references ${TICKET_REF} but issue #${TICKET_NUM} in
${MATCHED_REPO} is CLOSED.

Every PR needs its own OPEN ticket. Referencing a closed issue means the PR
has no live acceptance criteria, no QA handoff, and no tracker row to move
through the SDLC states — the ticket is already Done.

Common causes:
  - The work is a follow-up to the closed issue → create a NEW ticket that
    describes the follow-up, link back to the closed one in the body, and
    use the new number in the PR title.
  - The closed issue was auto-closed by a prior PR that didn't fully finish
    the work → re-open it (gh issue reopen ${TICKET_NUM} --repo ${MATCHED_REPO})
    or create a new ticket for the remaining work.
  - The number is a typo → fix the PR title.

See .claude/rules/ticket-vocabulary.md and the "every PR needs its own open
ticket" feedback in memory.
MSG
      exit 2
    fi
  fi
fi

# Check PR body for required sections.
#
# Summary, Testing, Glossary, and a Closes or Refs line are fixed.
# `.pr.required_sections` may add headings. The shipped list repeats
# Testing and Glossary for compatibility with existing fork configuration.
#
# Supports both --body "..." (inline) and --body-file <path> (file).
#
BODY_CONTENT=""
# Extract --body-file path. Handles --body-file and the -F short form.
# After continuation normalization (above) the command is one logical line.
# me2resh/apexyard#1058 (residual of #1048): "I could not read the body file"
# and "the body file has no required sections" are DIFFERENT outcomes, and
# conflating them is what made this hook report sections as missing from a
# file it had just warned it could not read — sending the author to edit a
# body that was never the problem. Set when a --body-file was named but its
# content could not be recovered; consumed at the section check below.
#
# Hakim / PR #1500: never read --body-file / -F from inside an inline or
# heredoc --body/-b value. A body that merely mentions `grep -F pattern` or
# `--body-file notes.md` used to set BODY_FILE to a fake path and fail with
# "PR body file could not be read". Strip body payloads first, then extract.
BODY_FILE_UNREADABLE=0
_cmd_for_bodyfile=$(printf '%s' "$COMMAND" | awk -v SQ="'" '
  { buf = (NR == 1 ? $0 : buf "\n" $0) }
  END {
    s = buf
    # Heredoc body consumes the rest of the command text.
    if (match(s, /(^|[[:space:]])(--body|-b)[[:space:]]+("\$\(cat|'\''\$\(cat|\$\(cat)[[:space:]]*<</)) {
      s = substr(s, 1, RSTART - 1)
      print s
      exit
    }
    # Double-quoted --body / -b value (first closing quote).
    if (match(s, /(^|[[:space:]])(--body|-b)[[:space:]]+"/)) {
      prefix = substr(s, 1, RSTART - 1)
      rest = substr(s, RSTART + RLENGTH)
      if (match(rest, /"/)) {
        s = prefix substr(rest, RSTART + 1)
      } else {
        s = prefix
      }
    }
    # Single-quoted --body / -b value.
    if (match(s, "(^|[[:space:]])(--body|-b)[[:space:]]+" SQ)) {
      prefix = substr(s, 1, RSTART - 1)
      rest = substr(s, RSTART + RLENGTH)
      if (match(rest, SQ)) {
        s = prefix substr(rest, RSTART + 1)
      } else {
        s = prefix
      }
    }
    # Unquoted single-token --body / -b value.
    if (match(s, /(^|[[:space:]])(--body|-b)[[:space:]]+[^[:space:]]+/)) {
      s = substr(s, 1, RSTART - 1) substr(s, RSTART + RLENGTH)
    }
    print s
  }
')
BODY_FILE=$(printf '%s' "$_cmd_for_bodyfile" | sed -nE 's/.*--body-file[[:space:]]+([^[:space:]]+).*/\1/p' | head -1)
if [ -z "$BODY_FILE" ]; then
  BODY_FILE=$(printf '%s' "$_cmd_for_bodyfile" | sed -nE 's/.*[[:space:]]-F[[:space:]]+([^[:space:]]+).*/\1/p' | head -1)
fi
unset _cmd_for_bodyfile
# #1038 — strip ONE matched surrounding quote pair.
#
# The `[^[:space:]]+` token grab above is quote-blind, so `--body-file
# "/p/body.md"` yielded the value WITH its quotes: `"/p/body.md"`. The
# `-f` test below was then false, BODY_CONTENT stayed empty, and the hook
# blocked the PR reporting `## Testing` / `## Glossary` as missing when both
# were present in the file — an error message that points at the PR author
# rather than at the parser. Quoting a path is correct shell practice, so
# this fired on ordinary usage.
#
# Only a MATCHED pair is stripped: a file literally named `"x.md"` (quotes
# in the filename) must keep resolving to the same path gh will read, not a
# different one.
case "$BODY_FILE" in
  '"'*'"') BODY_FILE=${BODY_FILE#\"}; BODY_FILE=${BODY_FILE%\"} ;;
  "'"*"'") BODY_FILE=${BODY_FILE#\'}; BODY_FILE=${BODY_FILE%\'} ;;
esac
# `--body-file -` reads the body from stdin (usually a heredoc in the same
# command). There is no file to read: check the command text instead.
[ "$BODY_FILE" = "-" ] && BODY_FILE=""
# An inline body flag after `pr create` (--body, --body=, -b). The body-file
# extraction above cannot parse every quoting shape (escaped quotes, the
# --body= form), so a fake path can come out of an inline body. The CLI
# refuses --body together with --body-file, so when an inline body is
# present and the named file cannot be read, check the command text as
# `dev` did instead of reporting an unreadable file.
_pr_create_tail=$(printf '%s' "$COMMAND" | sed -n '/pr[[:space:]][[:space:]]*create/,$p' | sed '1s/.*pr[[:space:]][[:space:]]*create//')
HAS_INLINE_BODY=0
if printf '%s' "$_pr_create_tail" | grep -qE '(^|[[:space:]])(--body(=|[[:space:]])|-b[[:space:]])'; then
  HAS_INLINE_BODY=1
fi
unset _pr_create_tail
if [ -n "$BODY_FILE" ]; then
  # Resolve relative paths against the command's cd-target (if any), so
  # 'cd /project && gh pr create --body-file body.md' finds the file at
  # /project/body.md rather than testing against the hook's own CWD.
  # Fixes apexyard#743 Bug 1 for the relative-path variant.
  if [[ "$BODY_FILE" != /* ]] && [ -n "$CD_TARGET" ]; then
    BODY_FILE="${CD_TARGET}/${BODY_FILE}"
  fi
  if [ -f "$BODY_FILE" ]; then
    BODY_CONTENT=$(cat "$BODY_FILE")
    # Readable-but-unslurpable (permissions, race): treat as unreadable rather
    # than as an empty body, mirroring block-private-refs-in-public-repos.sh.
    if [ -z "$BODY_CONTENT" ] && [ -s "$BODY_FILE" ]; then
      BODY_FILE_UNREADABLE=1
    fi
  elif [ "$HAS_INLINE_BODY" -eq 1 ]; then
    # Not a real body file: the path came out of an inline body. Check the
    # command text, which holds the inline body.
    BODY_FILE=""
  else
    echo "WARN: validate-pr-create.sh: --body-file '${BODY_FILE}' not readable from hook context; section check may miss content." >&2
    BODY_FILE_UNREADABLE=1
  fi
fi

if echo "$COMMAND" | grep -qE '\-\-body(-file)?\b|[[:space:]]-F[[:space:]]'; then
  # Combined haystack — scan both the file content (if --body-file) and the
  # raw command (so inline --body "..." also matches).
  HAYSTACK=$(printf '%s\n%s\n' "$BODY_CONTENT" "$COMMAND")

  # Load additional required sections from project config (shared reader).
  # Source via HOOK_DIR so this works regardless of cwd (inside a workspace
  # clone, REPO_ROOT would point at the project — _lib-read-config.sh itself
  # resolves the config files relative to the ops fork).
  # shellcheck disable=SC1090,SC1091
  REQUIRED_SECTIONS=""
  if [ -f "$HOOK_DIR/_lib-read-config.sh" ]; then
    . "$HOOK_DIR/_lib-read-config.sh"
    REQUIRED_SECTIONS=$(config_get '.pr.required_sections[]' 2>/dev/null)
  fi
  # Fallbacks for bare checkouts predating the config schema.
  if [ -z "$REQUIRED_SECTIONS" ]; then
    REQUIRED_SECTIONS=$(printf 'Testing\nGlossary')
  fi
  # The AgDR-0161 validator is shared with Rex and Tariq. Do not treat
  # an unreadable body as evidence that any section is missing.
  # shellcheck source=/dev/null
  if ! . "$HOOK_DIR/_lib-review-markers.sh"; then
    echo "validate-pr-create.sh: review validator unavailable" >&2
    exit 2
  fi
  if [ "$BODY_FILE_UNREADABLE" -eq 1 ]; then
    _unchecked=$(printf '%s\nSummary\nTesting\nGlossary\n' "$REQUIRED_SECTIONS" | sed '/^$/d' | sed 's/^/## /' | paste -sd, - | sed 's/,/, /g')
    ERRORS="${ERRORS}PR body file could not be read: ${BODY_FILE}\n"
    ERRORS="${ERRORS}  The required-section check was NOT run, so these are UNVERIFIED, not missing: ${_unchecked}; Closes or Refs line.\n"
    ERRORS="${ERRORS}  Fix the path (check for a typo, or make it absolute) and retry.\n"
  else
    if [ -n "$BODY_FILE" ]; then
      review_validate_body pr "$BODY_FILE" "$REQUIRED_SECTIONS" 2>/dev/null
    else
      # review_validate_body requires a regular file (-f). A process-substitution
      # fd is not a regular file on Linux, so materialise HAYSTACK via mktemp.
      _pr_body_temp=$(mktemp) || {
        echo "validate-pr-create.sh: could not create body check file" >&2
        exit 2
      }
      printf '%s\n' "$HAYSTACK" > "$_pr_body_temp"
      review_validate_body pr "$_pr_body_temp" "$REQUIRED_SECTIONS" 2>/dev/null
      rm -f "$_pr_body_temp"
    fi
    if [ "$REVIEW_VALIDATION_RESULT" != complete ]; then
      if [ -z "$REVIEW_VALIDATION_MISSING" ]; then
        ERRORS="${ERRORS}PR body failed completeness validation.\n"
      else
        while IFS= read -r section; do
          [ -z "$section" ] && continue
          if [ "$section" = 'Closes or Refs line' ]; then
            ERRORS="${ERRORS}PR body missing required Closes or Refs line.\n"
          else
            ERRORS="${ERRORS}PR body missing required '## ${section}' section.\n"
          fi
        done <<EOF
${REVIEW_VALIDATION_MISSING}
EOF
      fi
    fi
  fi

  # -------------------------------------------------------------------
  # Single-Closes-keyword check — enforce "one ticket per PR" in the body.
  #
  # Counts distinct issue numbers targeted by GitHub's auto-closing keywords
  # (close / closes / closed / fix / fixes / fixed / resolve / resolves /
  # resolved, plus the `#NN` form). The title validator already caps the
  # title's ticket reference at one; this closes the loophole where the
  # body has `Closes #1 Closes #2 Closes #3` and GitHub auto-closes all
  # three on merge.
  #
  # Config:
  #   .pr.allow_multiple_closes (default false) — teams that batch
  #     umbrella PRs (rollbacks, dependency bumps) can opt in.
  #   .pr.multi_close_skip_marker (default `<!-- multi-close: approved -->`)
  #     — per-PR escape hatch that leaves a grep-able trace.
  #
  # Scans only the body content (not the command line), so a `--title`
  # reference doesn't accidentally count.
  ALLOW_MULTI_CLOSES="false"
  MULTI_CLOSE_SKIP="<!-- multi-close: approved -->"
  # Source via HOOK_DIR — see note above on cwd-relative resolution.
  # shellcheck disable=SC1090,SC1091
  if [ -f "$HOOK_DIR/_lib-read-config.sh" ]; then
    . "$HOOK_DIR/_lib-read-config.sh"
    CFG_ALLOW=$(config_get_or '.pr.allow_multiple_closes' 'false' 2>/dev/null)
    if [ "$CFG_ALLOW" = "true" ]; then ALLOW_MULTI_CLOSES="true"; fi
    CFG_MARKER=$(config_get_or '.pr.multi_close_skip_marker' "$MULTI_CLOSE_SKIP" 2>/dev/null)
    if [ -n "$CFG_MARKER" ] && [ "$CFG_MARKER" != "null" ]; then
      MULTI_CLOSE_SKIP="$CFG_MARKER"
    fi
  fi

  if [ "$ALLOW_MULTI_CLOSES" != "true" ]; then
    # Strip code regions so closing keywords used as DOCUMENTATION (inside
    # code examples) don't count as real closes:
    #   - triple-backtick fences       (```...```)
    #   - tilde fences                 (~~~...~~~)
    #   - inline backticks             (`...`)
    #
    # Also strip inline-backticked skip markers so a PR that documents the
    # marker doesn't accidentally bypass its own check.
    STRIPPED_BODY=$(printf '%s\n' "$BODY_CONTENT" | awk '
      BEGIN { in_fence = 0; fence_char = "" }
      {
        line = $0
        if (in_fence == 0) {
          if (line ~ /^```/) { in_fence = 1; fence_char = "`"; next }
          if (line ~ /^~~~/) { in_fence = 1; fence_char = "~"; next }
          # Strip inline-backtick spans on non-fence lines.
          gsub(/`[^`]*`/, "", line)
          print line
        } else {
          if (fence_char == "`" && line ~ /^```/) { in_fence = 0; fence_char = ""; next }
          if (fence_char == "~" && line ~ /^~~~/) { in_fence = 0; fence_char = ""; next }
          # inside fence — drop
        }
      }
    ')

    # Extract distinct issue numbers referenced by a closing keyword + #NN.
    # Pattern: word-boundary, closing keyword (case-insensitive), whitespace,
    # optional repo-qualifier (owner/name), literal `#`, digits, word-boundary.
    CLOSE_NUMS=$(printf '%s\n' "$STRIPPED_BODY" | \
      grep -oiE '\b(close[sd]?|fix(e[sd])?|resolve[sd]?)[[:space:]]+([A-Za-z0-9._-]+/[A-Za-z0-9._-]+)?#[0-9]+' | \
      grep -oE '#[0-9]+' | \
      sort -u)

    CLOSE_COUNT=$(printf '%s\n' "$CLOSE_NUMS" | grep -c '^#')

    if [ "$CLOSE_COUNT" -gt 1 ]; then
      # Skip marker check runs against the STRIPPED body too — a marker used
      # as documentation inside backticks should not trigger a real bypass.
      if printf '%s\n' "$STRIPPED_BODY" | grep -qF -- "$MULTI_CLOSE_SKIP"; then
        echo "WARN: multi-close check bypassed by skip marker ($MULTI_CLOSE_SKIP) in PR body." >&2
      else
        NUMS_LIST=$(printf '%s ' $CLOSE_NUMS)
        ERRORS="${ERRORS}PR body has $CLOSE_COUNT distinct closing references (${NUMS_LIST}) — one ticket per PR (see CLAUDE.md). If this really is an umbrella PR, add the skip marker: $MULTI_CLOSE_SKIP\n"
      fi
    fi
  fi
fi

# Validate branch name has ticket ID.
#
# Read the branch from the `--head` flag when present, so this hook is
# safe to run from a different worktree's $PWD (Agent fan-out workers
# `cd` into their own worktree before running `gh pr create`, but the
# harness $PWD may still be a sibling worktree's directory). Falls back
# to local HEAD when `--head` isn't passed — preserves today's behaviour
# for anyone using the implicit-branch shape. See me2resh/apexyard#194.
#
# The local-HEAD fallback MUST resolve against the repo the command actually
# runs in — not the hook's own cwd. The harness fires this PreToolUse hook
# BEFORE the shell executes the command, so a `cd <repo> && gh pr create …`
# prefix has NOT yet changed the working dir: the hook's cwd is still the ops
# fork (on, e.g., `dev`). Without re-rooting, the fallback reads the ops-fork's
# branch and false-blocks a PR for a *different* managed repo (e.g. "Branch
# 'dev' missing ticket ID"). Same class as #669/#687 for the merge gates +
# arch-PR hook. See me2resh/apexyard#693.
#
# Re-root via pr_cmd_cd_target (from _lib-pr-repo.sh, already sourced above as
# $CMD_REPO is parsed): if the command begins with `cd <path> && …`, resolve
# the fallback branch with `git -C <path>`. With no leading `cd` (or <path>
# not a git tree), this is a no-op and the fallback stays byte-for-byte
# equivalent to the pre-#693 behaviour. The `--head` path is unaffected, and
# the PR-title check above is independent of cwd.
# CD_TARGET was extracted early (near top of script) for --body-file path
# resolution; reuse it here for the branch-name fallback below.
BRANCH_DIR=""
if [ -n "$CD_TARGET" ]; then
  CD_TOPLEVEL=$(git -C "$CD_TARGET" rev-parse --show-toplevel 2>/dev/null)
  if [ -n "$CD_TOPLEVEL" ]; then
    BRANCH_DIR="$CD_TOPLEVEL"
  fi
fi
HEAD_FLAG=$(echo "$COMMAND" | sed -nE 's/.*--head[[:space:]]+([^[:space:]]+).*/\1/p' | head -1)
if [ -n "$HEAD_FLAG" ]; then
  CURRENT_BRANCH="$HEAD_FLAG"
elif [ -n "$BRANCH_DIR" ]; then
  CURRENT_BRANCH=$(git -C "$BRANCH_DIR" branch --show-current 2>/dev/null)
else
  CURRENT_BRANCH=$(git branch --show-current 2>/dev/null)
fi
if [ -n "$CURRENT_BRANCH" ] && [ "$CURRENT_BRANCH" != "main" ] && [ "$CURRENT_BRANCH" != "master" ]; then
  # Release-cut branches are exempt — same recognition `validate-branch-name.sh`
  # added in me2resh/apexyard#168 / #169. Release branches don't carry a
  # ticket-id because the release itself is the ticket. The /release-sync
  # branch `sync/main-to-dev-after-vN.N.N` is exempt for the same reason
  # (the release being synced is the ticket) — see apexyard#458 and the
  # /release-sync skill. The PR title still references a live ticket via
  # `sync(#N):`, which the title check above validates.
  if echo "$CURRENT_BRANCH" | grep -qE '^release/v[0-9]+\.[0-9]+\.[0-9]+(-rc[0-9]+)?$|^sync/main-to-dev-after-v[0-9]+\.[0-9]+\.[0-9]+$'; then
    :  # release-cut or release-sync branch, exempt — fall through to the rest of the validator
  elif [ -n "$EXTERNAL_TARGET" ]; then
    :  # External contribution (#1448/#1451 B3): the branch belongs to the
       # contributor's own fork and the destination project has its own
       # naming conventions, so a framework ticket ID is not required here.
  elif ! echo "$CURRENT_BRANCH" | grep -qE '[A-Z]{2,10}-[0-9]+|GH-[0-9]+|#[0-9]+'; then
    ERRORS="${ERRORS}Branch '$CURRENT_BRANCH' missing ticket ID.\n"
  fi
fi

if [ -n "$ERRORS" ]; then
  echo "PR VALIDATION BLOCKED:" >&2
  # '%b' — NOT `printf "$ERRORS"`. The bare form treats accumulated error text
  # as a FORMAT STRING, so any '%' inside it is consumed as a conversion spec.
  # That was latent until #1058 started interpolating a user-supplied path into
  # a message: `--body-file /tmp/nope%s-100%.md` printed a different path and
  # silently swallowed the guidance lines that followed. '%b' keeps the '\n'
  # expansion every existing message relies on while making '%' literal.
  printf '%b' "$ERRORS" >&2
  echo "" >&2
  echo "Fix the issues above before creating the PR." >&2
  echo "See .claude/rules/git-conventions.md and .claude/rules/pr-quality.md." >&2
  exit 2
fi

exit 0
