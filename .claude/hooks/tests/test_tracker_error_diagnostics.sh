#!/bin/bash
# Tests for tracker-CLI error diagnostics at hook call sites (me2resh/apexyard#1336).
#
# #1332 let the tracker library pass the CLI's stderr through. The shipped
# hooks then discarded it again at every call site, so a hook that blocked
# because a lookup failed reported "the issue does not exist" even when the
# real cause was an expired token, a network error, or a missing scope.
#
# The fix captures each lookup's stderr to a temporary file and prints it under
# "Tracker CLI said:" only on a path that blocks or warns. The maintainer chose
# the quieter of the two options offered on #1336: quote the LAST failed lookup
# after the upstream fallback, and stay silent when the fork-then-upstream
# lookup (#207) succeeds — printing every miss would add noise to every
# ordinary fork-to-upstream PR.
#
# Coverage:
#   - validate-pr-create.sh   : block path quotes the CLI error
#   - validate-pr-create.sh   : upstream fallback SUCCEEDS → stays silent
#   - verify-commit-refs.sh   : block path quotes the CLI error
#   - verify-commit-refs.sh   : upstream fallback SUCCEEDS → stays silent
#   - require-migration-ticket.sh : fail-closed block quotes the CLI error
#
# This file installs its own `gh` stub rather than extending _lib-mock-gh.sh,
# because the shared mock exits silently on a miss and every other test relies
# on that silence.

set -u

HOOKS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"

PASS=0
FAIL=0
FAILED_CASES=""

# The text the stub writes to stderr — shaped like a real gh auth failure.
CLI_ERROR="gh: To use GitHub CLI in a GitHub Actions workflow, set the GH_TOKEN environment variable."

# Build a sandbox fork with origin + upstream remotes and the hook under test.
# $1 = hook filename. Extra libs are copied so the hook resolves its config.
make_sandbox() {
  local hook="$1"
  local sb
  sb=$(mktemp -d)
  (
    cd "$sb" || exit 1
    git init -q
    git config user.email "test@example.com"
    git config user.name "test"
    git remote add origin git@github.com:fork-org/apexyard.git
    git remote add upstream git@github.com:me2resh/apexyard.git
    git checkout -q -B "fix/#1336-diag-test"
    # Both anchors, so the hooks resolve this sandbox as the ops root
    # regardless of which fork layout they probe for.
    touch onboarding.yaml apexyard.projects.yaml .apexyard-fork
    git add onboarding.yaml apexyard.projects.yaml .apexyard-fork
    git commit -q -m "init"
  )
  mkdir -p "$sb/.claude/hooks"
  cp "$HOOKS_DIR/$hook" "$sb/.claude/hooks/$hook"
  chmod +x "$sb/.claude/hooks/$hook"
  for lib in _lib-read-config.sh _lib-tracker.sh _lib-extract-pr.sh _lib-pr-repo.sh \
             _lib-active-ticket.sh _lib-ops-root.sh _lib-detect-bash-write.sh \
             _lib-portfolio-paths.sh; do
    if [ -f "$SRC_ROOT/.claude/hooks/$lib" ]; then
      cp "$SRC_ROOT/.claude/hooks/$lib" "$sb/.claude/hooks/$lib"
    fi
  done
  cp "$SRC_ROOT/.claude/project-config.defaults.json" "$sb/.claude/project-config.defaults.json"
  echo "$sb"
}

# Install a `gh` stub that fails WITH stderr unless the lookup matches
# $ok_repo, in which case it returns an OPEN issue. With no $ok_repo, every
# lookup fails — the block-path case. $ok_num further narrows success to a
# single issue number, so a run can mix a failing ref with a resolving one.
install_failing_gh() {
  local sb="$1" ok_repo="${2:-}" ok_num="${3:-}"
  mkdir -p "$sb/.bin"
  cat > "$sb/.bin/gh" <<STUB
#!/bin/bash
# Test stub: emulate a gh that fails with a diagnostic on stderr.
if [ "\$1" = "issue" ] && [ "\$2" = "view" ]; then
  num="\$3"; repo=""
  shift 3
  while [ \$# -gt 0 ]; do
    case "\$1" in
      --repo) repo="\$2"; shift 2 ;;
      --repo=*) repo="\${1#--repo=}"; shift ;;
      *) shift ;;
    esac
  done
  if [ -n "${ok_repo}" ] && [ "\$repo" = "${ok_repo}" ] \
     && { [ -z "${ok_num}" ] || [ "\$num" = "${ok_num}" ]; }; then
    printf '{"number":%s,"state":"OPEN","title":"t","url":"u","labels":[],"body":"b"}\n' "\$num"
    exit 0
  fi
  echo "${CLI_ERROR}" >&2
  exit 1
fi
exit 0
STUB
  chmod +x "$sb/.bin/gh"
}

# Run a hook with a tool_input command and return its stderr + rc.
run_hook() {
  local sb="$1" hook="$2" cmd="$3"
  local input
  input=$(jq -nc --arg c "$cmd" '{tool_input:{command:$c}}')
  ( cd "$sb" && PATH="$sb/.bin:$PATH" bash ".claude/hooks/$hook" <<<"$input" 2>&1 >/dev/null )
}

assert_case() {
  local label="$1" got="$2" mode="$3"   # mode: has | lacks
  if [ "$mode" = "has" ]; then
    if echo "$got" | grep -q "Tracker CLI said:" && echo "$got" | grep -qF "$CLI_ERROR"; then
      echo "PASS [$label]"; PASS=$((PASS+1)); return
    fi
    echo "FAIL [$label]: expected the CLI error to be quoted" >&2
    echo "    stderr: ${got:0:400}" >&2
  else
    if ! echo "$got" | grep -q "Tracker CLI said:"; then
      echo "PASS [$label]"; PASS=$((PASS+1)); return
    fi
    echo "FAIL [$label]: expected silence, but the CLI error was quoted" >&2
    echo "    stderr: ${got:0:400}" >&2
  fi
  FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}${label} "
}

BODY=$'## Summary\nx\n\n## Testing\ny\n\n## Glossary\n| t | d |'

# ---- validate-pr-create.sh ----------------------------------------------

# Both lookups fail with stderr → the block path must quote the last one.
sb=$(make_sandbox "validate-pr-create.sh")
install_failing_gh "$sb"
printf '%s' "$BODY" > "$sb/body.md"
got=$(run_hook "$sb" "validate-pr-create.sh" \
  "gh pr create --title \"fix(#4242): diag\" --body-file $sb/body.md --head fix/#1336-diag-test")
assert_case "pr-create: block path quotes the CLI error" "$got" has
rm -rf "$sb"

# Origin fails, upstream succeeds → the ordinary #207 path. Must stay silent:
# this is the case the maintainer explicitly did not want to be noisy.
sb=$(make_sandbox "validate-pr-create.sh")
install_failing_gh "$sb" "me2resh/apexyard"
printf '%s' "$BODY" > "$sb/body.md"
got=$(run_hook "$sb" "validate-pr-create.sh" \
  "gh pr create --title \"fix(#150): upstream only\" --body-file $sb/body.md --head fix/#1336-diag-test")
assert_case "pr-create: successful upstream fallback stays silent" "$got" lacks
rm -rf "$sb"

# ---- verify-commit-refs.sh ----------------------------------------------

sb=$(make_sandbox "verify-commit-refs.sh")
install_failing_gh "$sb"
got=$(run_hook "$sb" "verify-commit-refs.sh" \
  'git commit -m "fix: thing

Closes #4242"')
assert_case "commit-refs: block path quotes the CLI error" "$got" has
rm -rf "$sb"

sb=$(make_sandbox "verify-commit-refs.sh")
install_failing_gh "$sb" "me2resh/apexyard"
got=$(run_hook "$sb" "verify-commit-refs.sh" \
  'git commit -m "fix: thing

Closes #150"')
assert_case "commit-refs: successful upstream fallback stays silent" "$got" lacks
rm -rf "$sb"

# Multi-ref regression: this hook loops over every ref in the message, sharing
# one capture file. `2>` truncates on open, so a later ref's lookup — even a
# successful one that writes nothing — would wipe the error belonging to the ref
# that actually went missing. #100 fails everywhere; #999 resolves upstream; the
# refs are sorted, so #100 is processed first and the naive shared-file approach
# ends up printing nothing at all for the ref that blocks.
sb=$(make_sandbox "verify-commit-refs.sh")
install_failing_gh "$sb" "me2resh/apexyard" "999"
got=$(run_hook "$sb" "verify-commit-refs.sh" \
  'git commit -m "fix: thing

Closes #100
Refs #999"')
assert_case "commit-refs: failing ref keeps its error when a later ref resolves" "$got" has
rm -rf "$sb"

# ---- require-migration-ticket.sh ----------------------------------------
# The migration gate is fail-closed with a single lookup and no upstream
# fallback, so a failing CLI always reaches the block path.

sb=$(make_sandbox "require-migration-ticket.sh")
install_failing_gh "$sb"
mkdir -p "$sb/.claude/session"
printf 'repo=fork-org/apexyard\nnumber=4242\ntitle=t\nurl=u\n' > "$sb/.claude/session/current-ticket"
# This gate fires on Edit/Write, so the payload carries a file_path rather
# than a Bash command. The default patterns are anchored with a leading `*/`,
# so the target must be absolute for `db/migrate/*.rb` to match.
mig_input=$(jq -nc --arg p "$sb/db/migrate/20260101_add_column.rb" '{tool_name:"Edit",tool_input:{file_path:$p}}')
got=$( cd "$sb" && PATH="$sb/.bin:$PATH" bash .claude/hooks/require-migration-ticket.sh <<<"$mig_input" 2>&1 >/dev/null )
# Only assert when the gate actually reached its tracker lookup; an earlier
# guard (no migration path matched) is a different branch and not this test's
# subject.
if echo "$got" | grep -q "BLOCKED: Could not fetch"; then
  assert_case "migration gate: fail-closed block quotes the CLI error" "$got" has
else
  echo "SKIP [migration gate]: hook exited before the tracker lookup"
  echo "    stderr: ${got:0:300}"
fi
rm -rf "$sb"

# ---- Summary ------------------------------------------------------------

echo ""
echo "==================================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "==================================="
if [ "$FAIL" -gt 0 ]; then
  echo "Failed: $FAILED_CASES" >&2
  exit 1
fi
exit 0
