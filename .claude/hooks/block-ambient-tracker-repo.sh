#!/bin/bash
# CLASS: CONTROL — require an explicit repository for tracker commands when
# the active ticket belongs to a different repository than the current
# checkout (me2resh/apexyard#1268).

INPUT=$(cat)
COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
[ -n "$COMMAND" ] || exit 0

# The shared allowlist keeps executable command words visible. If it cannot
# classify the command, the scanner returns raw text and the gate fails closed.
HOOK_DIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd) || exit 0
SCAN_COMMAND=$COMMAND
if [ -r "$HOOK_DIR/_lib-command-scrub.sh" ]; then
  # shellcheck source=/dev/null
  . "$HOOK_DIR/_lib-command-scrub.sh"
  SCAN_COMMAND=$(scrub_bash_command "$COMMAND")
fi
# Bash removes a backslash-newline continuation before it parses words and
# flags, so `gh pr list \<newline> --repo x` names its repository (#1492).
# Model continuations outside quotes only when the backslash is not escaped.
# Bash also joins inside double quotes. Treat that case as unmodelled so
# quoted text cannot supply a repository flag. `\\<newline>` is a backslash and a
# real newline, so the next line is a new command and must stay separate.
# The join models only plain words, quotes and backslashes. It leaves a
# command unjoined when it holds syntax that changes where a line ends:
# a comment (`#`), a heredoc (`<<`), command substitution (`$(` or a
# backtick), parameter expansion (`${`, whose nested quotes the join does
# not model, #1503), or ANSI-C quoting (`$'`). A backslash in a comment, for
# example, is not a continuation, so a join there would pull the next
# command into the comment. It also skips a command over 2048 bytes, so
# the per-character loop stays fast. A command the join does not model gets
# no flag-based allowance below (#1503).
_batr_join_continuations() {
  local s="$1" out="" c quote="" bs=0 i n
  n=${#s}
  for ((i = 0; i < n; i++)); do
    c="${s:i:1}"
    if [ -n "$quote" ]; then
      if [ "$quote" = '"' ] && [ "$c" = $'\n' ] && [ $((bs % 2)) -eq 1 ]; then
        return 1
      fi
      [ "$c" = "$quote" ] && [ $((bs % 2)) -eq 0 ] && quote=""
      if [ "$quote" = '"' ] && [ "$c" = '\' ]; then bs=$((bs + 1)); else bs=0; fi
      out="$out$c"
      continue
    fi
    if [ "$c" = $'\n' ] && [ $((bs % 2)) -eq 1 ]; then
      out="${out%\\}"
      bs=0
      continue
    fi
    if [ "$c" = '\' ]; then
      bs=$((bs + 1))
    else
      { [ "$c" = "'" ] || [ "$c" = '"' ]; } && [ $((bs % 2)) -eq 0 ] && quote="$c"
      bs=0
    fi
    out="$out$c"
  done
  printf '%s' "$out"
}
# JOIN_UNMODELLED=1 when the command keeps a backslash-newline that the join
# did not model: a double-quoted continuation, a skip token above, or size.
JOIN_UNMODELLED=0
case "$SCAN_COMMAND" in
  *$'\\\n'*)
    if [ "${#SCAN_COMMAND}" -gt 2048 ]; then
      JOIN_UNMODELLED=1
    else
      case "$SCAN_COMMAND" in
        *'#'* | *'<<'* | *'$('* | *'${'* | *'`'* | *"\$'"*) JOIN_UNMODELLED=1 ;;
        *)
          if joined=$(_batr_join_continuations "$SCAN_COMMAND"); then
            SCAN_COMMAND=$joined
          else
            JOIN_UNMODELLED=1
          fi
          ;;
      esac
    fi
    ;;
esac

# This guard covers GitHub issue and pull-request commands. Commands that
# already name --repo/-R are explicit by definition and may intentionally cross
# repository boundaries.
# A shell command can prefix, group, or conditionally execute the tracker
# invocation. Match `gh issue` / `gh pr` after any non-word shell delimiter so
# wrappers such as `timeout`, `command`, subshells, and `if` cannot bypass the
# repository check. The raw fallback also catches quoted or escaped tracker
# words that the syntax view would otherwise blank.
TRACKER_PATTERN="(^|[^[:alnum:]_])['\"\\\\]*g['\"\\\\]*h['\"\\\\]*[[:space:]]+['\"\\\\]*(issue|pr)['\"\\\\]*[[:space:]]+"
if ! printf '%s' "$SCAN_COMMAND" | LC_ALL=C grep -qE "$TRACKER_PATTERN"; then
  # An unmodelled continuation can split a tracker command across lines
  # (`x=${y} gh \<newline> issue view 42`), so also look with every
  # backslash-newline removed before deciding there is no tracker command.
  # Join with awk, not ${var//pattern/}: under bash 3.2 that substitution
  # grows super-linearly with the number of continuations, and a large
  # command could stall this dispatcher and every gate after it (Hakim, PR
  # #1511). The awk join is linear. LC_ALL=C keeps awk from aborting on a
  # byte that is not valid UTF-8, which would print nothing and hide a match.
  # Use the same byte locale for every tracker-pattern grep.
  # Also preserve line endings after possible comments (#1521). Joining
  # `# note x\<newline>g\<newline>h issue` hides the tracker behind x.
  # Keep both views: a # inside quotes might not start a comment.
  if [ "$JOIN_UNMODELLED" -eq 0 ] \
    || { ! printf '%s\n' "$SCAN_COMMAND" \
      | LC_ALL=C awk '{ if (sub(/\\$/, "")) printf "%s", $0; else print }' \
      | LC_ALL=C grep -qE "$TRACKER_PATTERN" \
      && ! printf '%s\n' "$SCAN_COMMAND" \
        | LC_ALL=C awk '/#/ { print; next } { if (sub(/\\$/, "")) printf "%s", $0; else print }' \
        | LC_ALL=C grep -qE "$TRACKER_PATTERN"; }; then
    exit 0
  fi
fi
# Check each shell command segment independently. A repository flag in a
# comment or a separate command must not authorize an unqualified tracker
# invocation. Splitting on shell control characters is intentionally
# conservative. A segment that cannot be classified remains blocked.
# A segment with an explicit repository is safe. If every tracker segment had
# one, no unqualified segment remains to check.
#
# When JOIN_UNMODELLED=1, the gate cannot tell which lines Bash joins: a join
# can add a tracker command, remove one, or move a quoted `--repo` into a
# segment. No flag can be trusted there, so any tracker command counts as
# unqualified (#1503, review of PR #1511). Put such a command on one line,
# or remove the skip token, to pass with an explicit repository.
unqualified=0
if [ "$JOIN_UNMODELLED" -eq 1 ]; then
  unqualified=1
else
  while IFS= read -r segment; do
    segment="${segment%%#*}"
    # A standalone `--` ends GitHub CLI option parsing. Ignore any repo-like
    # token after it; only flags before that boundary can authorize the call.
    options="$(printf '%s' "$segment" | sed -E 's/[[:space:]]--([[:space:]].*)?$//')"
    if printf '%s' "$segment" | LC_ALL=C grep -qE "$TRACKER_PATTERN" \
      && ! printf '%s' "$options" | grep -qE '(^|[[:space:]])(--repo|-R)(=|[[:space:]])'; then
      unqualified=1
      break
    fi
  done < <(printf '%s\n' "$SCAN_COMMAND" | tr ';|&()' '\n')
fi
[ "$unqualified" -eq 1 ] || exit 0

if [ -f "$HOOK_DIR/_lib-ops-root.sh" ]; then
  # shellcheck source=/dev/null
  . "$HOOK_DIR/_lib-ops-root.sh"
else
  exit 0
fi

OPS_ROOT=$(resolve_ops_root "$PWD")
[ -n "$OPS_ROOT" ] || exit 0

# Read the repo pins from active ticket markers. A marker without repo= is the
# legacy/framework fallback and cannot establish a managed-project target.
MARKER_DIR="$OPS_ROOT/.claude/session"
REPOS=""
for marker in "$MARKER_DIR/current-ticket" "$MARKER_DIR/tickets"/* "$MARKER_DIR/tickets"/*/*; do
  [ -f "$marker" ] || continue
  repo=$(sed -n 's/^repo=//p' "$marker" | head -1)
  [ -n "$repo" ] && REPOS="${REPOS}${repo}\n"
done
[ -n "$REPOS" ] || exit 0

UNIQUE_REPOS=$(printf '%b' "$REPOS" | sed '/^$/d' | sort -u)
COUNT=$(printf '%s\n' "$UNIQUE_REPOS" | sed '/^$/d' | wc -l | tr -d ' ')

# If exactly one active target matches the checkout's origin, ambient gh is
# safe. Otherwise require the caller to state the repository explicitly.
ORIGIN_URL=$(git remote get-url origin 2>/dev/null || true)
ORIGIN_REPO=$(printf '%s' "$ORIGIN_URL" | sed -nE 's|.*[:/]([^/:]+/[^/]+)\.git$|\1|p; s|.*[:/]([^/:]+/[^/]+)$|\1|p' | head -1)
if [ "$COUNT" -eq 1 ] && [ "$(printf '%s' "$UNIQUE_REPOS" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$ORIGIN_REPO" | tr '[:upper:]' '[:lower:]')" ]; then
  exit 0
fi

if [ "$COUNT" -eq 1 ]; then
  TARGET=$(printf '%s' "$UNIQUE_REPOS" | head -1)
  echo "BLOCKED: tracker command has no explicit repository, but the active ticket targets $TARGET while this checkout resolves to ${ORIGIN_REPO:-no origin}. Add --repo $TARGET (or -R $TARGET)." >&2
else
  echo "BLOCKED: tracker command has no explicit repository, and active tickets target multiple repositories. Add --repo <owner/repo> (or -R <owner/repo>)." >&2
fi
exit 2
