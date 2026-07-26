#!/bin/bash
# test_tracker_zsh_self_location.sh — regression test for #1025.
#
# tracker_review_submit posts the code reviewer's (Rex's) human-visible
# review to the PR. #1025: under zsh (the macOS default shell), the internal
# loader functions _tracker_load_portfolio_lib / _tracker_load_config_lib
# resolve their own directory via ${BASH_SOURCE[0]} — a bash-only parameter
# that is UNSET under zsh. A bare reference to it:
#   - hard-errors ("parameter not set") whenever the calling shell has
#     nounset active (a common defensive `set -u` header) — and
#     _tracker_load_portfolio_lib had NO git-rev-parse fallback at all (unlike
#     its sibling _tracker_load_config_lib), so it silently `return 0`'d
#     having loaded nothing;
#   - even WITHOUT nounset, an empty BASH_SOURCE[0] makes `dirname` resolve
#     to ".", i.e. the CALLER's cwd rather than the lib's real directory —
#     the same failure class as #950.
#
# The practical consequence: a per-project tracker.kind override (read via
# portfolio_registry) silently stopped resolving under zsh, and callers fell
# through to the global tracker.kind default with no signal anything had
# gone wrong — the "returns 0 without posting" shape #1025 reports.
#
# This test:
#   1. Skips gracefully if zsh isn't installed.
#   2. Proves _tracker_load_portfolio_lib actually loads under zsh (with
#      nounset active — the exact condition from the bug report).
#   3. Proves the PRACTICAL consequence is fixed: a per-project tracker.kind
#      override resolves correctly under zsh, not silently defaulting.
#   4. Proves tracker_review_submit's full call chain still reaches the
#      host CLI under zsh (a mock gh is actually invoked, not skipped).
#   5. Proves a CLI failure propagates as a real non-zero exit under zsh +
#      `set -euo pipefail` — the process must not die silently mid-call, and
#      must never report success without posting.
#   6. Regression pin: every self-locating library BASH_SOURCE[0] reference
#      audited under #1025 uses the `:-` safe-default form — so a future
#      revert of the fix fails loudly here instead of silently
#      reintroducing the bug (mirrors the #950 prior-art test's own pin).
#
# Run: bash .claude/hooks/tests/test_tracker_zsh_self_location.sh

set -u
unset APEXYARD_OPS_PIN_DIR CLAUDE_CODE_SESSION_ID 2>/dev/null || true

HOOK_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TRACKER_LIB="$HOOK_DIR/_lib-tracker.sh"
CONFIG_LIB="$HOOK_DIR/_lib-read-config.sh"
PORTFOLIO_LIB="$HOOK_DIR/_lib-portfolio-paths.sh"
OPSROOT_LIB="$HOOK_DIR/_lib-ops-root.sh"

PASS=0
FAIL=0
FAILED=""
pass() { PASS=$((PASS+1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL+1)); FAILED="$FAILED\n  - $1"; echo "FAIL: $1"; echo "    expected: [$2]"; echo "    actual:   [$3]"; }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "$2" "$3"; fi; }

HAVE_YAML=no
if command -v yq >/dev/null 2>&1 || python3 -c 'import yaml' >/dev/null 2>&1; then HAVE_YAML=yes; fi

if ! command -v zsh >/dev/null 2>&1; then
  echo "SKIP: zsh not installed, skipping the #1025 zsh-invocation regression suite"
  echo "=========================================="
  echo "PASS: 0  FAIL: 0"
  exit 0
fi

make_sandbox() {
  local sb registry_body="${1:-}"
  sb=$(mktemp -d); sb=$(cd "$sb" && pwd -P)
  mkdir -p "$sb/.claude/hooks" "$sb/bin"
  touch "$sb/onboarding.yaml"
  # A real (if minimal) git repo — the fix's fallback path resolves the lib
  # dir via `git rev-parse --show-toplevel`, which needs an actual repo to
  # answer. Real-world usage always runs this lib inside the ops fork or a
  # workspace clone (both real repos), so the sandbox must match that shape
  # or this test would fail on the fallback path for the wrong reason.
  ( cd "$sb" && git init -q ) 2>/dev/null || true
  cp "$TRACKER_LIB"   "$sb/.claude/hooks/_lib-tracker.sh"
  cp "$CONFIG_LIB"    "$sb/.claude/hooks/_lib-read-config.sh"
  cp "$PORTFOLIO_LIB" "$sb/.claude/hooks/_lib-portfolio-paths.sh"
  [ -f "$OPSROOT_LIB" ] && cp "$OPSROOT_LIB" "$sb/.claude/hooks/_lib-ops-root.sh"
  cat > "$sb/.claude/project-config.defaults.json" <<'JSON'
{ "tracker": { "kind": "gh" } }
JSON
  if [ -n "$registry_body" ]; then
    printf '%s\n' "$registry_body" > "$sb/apexyard.projects.yaml"
  else
    printf 'version: 1\nprojects: []\n' > "$sb/apexyard.projects.yaml"
  fi
  echo "$sb"
}

# ---------------------------------------------------------------------------
# Case 1 — _tracker_load_portfolio_lib actually loads under zsh WITH nounset
# active (the exact condition in the bug report's stderr line). Before the
# fix this silently returned 0 having loaded nothing; after the fix,
# portfolio_registry becomes available and the loader itself reports success.
# ---------------------------------------------------------------------------
SB1=$(make_sandbox)
cd "$SB1" || { echo "FAIL: cd sandbox 1"; exit 1; }
OUT1=$(zsh -c '
setopt NO_UNSET
source .claude/hooks/_lib-tracker.sh
_tracker_load_portfolio_lib
lib_rc=$?
have=no
command -v portfolio_registry >/dev/null 2>&1 && have=yes
printf "%s|%s\n" "$lib_rc" "$have"
' 2>"$SB1/stderr1")
IFS='|' read -r c1_rc c1_have <<< "$OUT1"
assert_eq "zsh+nounset: _tracker_load_portfolio_lib returns 0 (loaded)" "0" "$c1_rc"
assert_eq "zsh+nounset: portfolio_registry becomes available" "yes" "$c1_have"
assert_eq "zsh+nounset: no 'parameter not set' error on stderr" "0" "$(grep -c 'parameter not set' "$SB1/stderr1")"
cd - >/dev/null || true
rm -rf "$SB1"

# ---------------------------------------------------------------------------
# Case 2 — the PRACTICAL consequence: a per-project tracker.kind override
# (glab, differing from the global default of gh) resolves correctly under
# zsh. Before the fix, _tracker_load_portfolio_lib's silent no-op meant
# _tracker_project_value could never see the registry, and tracker_kind fell
# through to the global "gh" default — silently wrong for a non-GitHub
# project. Needs a YAML parser (yq or python3+PyYAML) to read the registry.
# ---------------------------------------------------------------------------
if [ "$HAVE_YAML" = yes ]; then
  SB2=$(make_sandbox "version: 1
projects:
  - name: gl
    repo: g/p
    tracker:
      kind: glab")
  cd "$SB2" || { echo "FAIL: cd sandbox 2"; exit 1; }
  kind_seen=$(zsh -c '
setopt NO_UNSET
source .claude/hooks/_lib-tracker.sh
tracker_kind "g/p"
' 2>/dev/null)
  assert_eq "zsh+nounset: per-project tracker.kind override resolves (glab, not global gh default)" "glab" "$kind_seen"
  cd - >/dev/null || true
  rm -rf "$SB2"
else
  echo "SKIP: per-project override case (no yq / python3+PyYAML)"
fi

# ---------------------------------------------------------------------------
# Case 3 — end-to-end: tracker_review_submit's full call chain still reaches
# the host CLI under zsh (a mock gh is actually invoked — argv captured).
# ---------------------------------------------------------------------------
SB3=$(make_sandbox)
cat > "$SB3/bin/gh" <<'EOF'
#!/bin/bash
[ -n "${GH_CAPTURE:-}" ] && printf '%s\n' "$@" > "$GH_CAPTURE"
exit 0
EOF
chmod +x "$SB3/bin/gh"
printf 'APPROVED — verdict in body.\n' > "$SB3/rev.md"
cd "$SB3" || { echo "FAIL: cd sandbox 3"; exit 1; }
rc3=$(PATH="$SB3/bin:$PATH" GH_CAPTURE="$SB3/cap3" zsh -c '
setopt NO_UNSET
source .claude/hooks/_lib-tracker.sh
tracker_review_submit "o/r" 42 comment "$1"
echo $?
' _ "$SB3/rev.md" 2>/dev/null | tail -1)
assert_eq "zsh: tracker_review_submit reaches gh and returns 0" "0" "$rc3"
assert_eq "zsh: gh mock was actually invoked (argv captured)" "yes" "$([ -f "$SB3/cap3" ] && echo yes || echo no)"
cd - >/dev/null || true
rm -rf "$SB3"

# ---------------------------------------------------------------------------
# Case 4 — a CLI failure propagates as a REAL non-zero exit under zsh +
# `set -euo pipefail`, and the process does not die silently mid-call before
# ever reaching the CLI (the pre-fix failure mode: the whole zsh process
# aborted at the BASH_SOURCE reference before gh was ever invoked). This is
# the literal "fails loudly rather than returning 0" acceptance criterion.
# ---------------------------------------------------------------------------
SB4=$(make_sandbox)
cat > "$SB4/bin/gh" <<'EOF'
#!/bin/bash
exit 1
EOF
chmod +x "$SB4/bin/gh"
printf 'body\n' > "$SB4/rev.md"
cd "$SB4" || { echo "FAIL: cd sandbox 4"; exit 1; }
OUT4=$(PATH="$SB4/bin:$PATH" zsh -c '
set -euo pipefail
source .claude/hooks/_lib-tracker.sh
echo "REACHED_BEFORE"
set +e
tracker_review_submit "o/r" 42 comment "$1"
rc=$?
set -e
echo "REACHED_AFTER:$rc"
' _ "$SB4/rev.md" 2>/dev/null)
assert_eq "zsh+errexit: reaches the call (lib load did not abort the process)" "yes" "$(printf '%s' "$OUT4" | grep -qc REACHED_BEFORE && echo yes || echo no)"
assert_eq "zsh+errexit: gh's real non-zero exit propagates, not silent 0" "REACHED_AFTER:1" "$(printf '%s' "$OUT4" | grep REACHED_AFTER)"
cd - >/dev/null || true
rm -rf "$SB4"

# ---------------------------------------------------------------------------
# Case 5 — regression pin: every BASH_SOURCE[0] self-location reference in
# the tracker lib uses the `:-` safe-default form. A future revert to the
# bare form fails loudly HERE instead of silently reintroducing #1025.
# ---------------------------------------------------------------------------
# Only CODE lines (strip full-line comments) count — the file's own prose
# explaining the hazard legitimately writes the bare form in a comment.
bare_refs=$(grep -v '^\s*#' "$TRACKER_LIB" | grep -oE '\$\{BASH_SOURCE\[0\][^}]*\}' | grep -vc ':-' || true)
assert_eq "no bare (unguarded) \${BASH_SOURCE[0]} references remain in _lib-tracker.sh code" "0" "${bare_refs:-0}"

echo "=========================================="
echo "PASS: $PASS  FAIL: $FAIL"
if [ "$FAIL" -gt 0 ]; then printf "Failed:%b\n" "$FAILED"; exit 1; fi
exit 0
