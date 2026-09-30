#!/bin/bash
# #1504: a session pin written with a different letter case names the real
# fork on a case-insensitive filesystem, so it must get install advice.
#
# This case needs a case-insensitive filesystem (default macOS). On a
# case-sensitive filesystem, such as the Linux CI runner, it prints a SKIP
# line. bin/run-hook-tests.sh quarantines this file for that reason, in the
# same way as test_portfolio_paths_case_insensitive_fs.sh (#1104).

set -u

HOOK_SRC="${PRE_PUSH_GATE_HOOK_SRC:-$(cd "$(dirname "$0")/.." && pwd)/pre-push-gate.sh}"
if [ ! -x "$HOOK_SRC" ]; then
  echo "FAIL: hook not found or not executable at $HOOK_SRC" >&2
  exit 1
fi

PASS=0
FAIL=0
FAILED_CASES=""

push_json() {
  cat <<EOF
{"tool_input":{"command":"git push origin HEAD"}}
EOF
}

make_pin() {
  local root="$1" sid="$2" pin_dir
  pin_dir=$(mktemp -d)
  printf '%s\n' "$root" > "$pin_dir/ops-root-${sid}"
  printf '%s' "$pin_dir"
}

run_pinned_hook() {
  local sb="$1" pin_dir="$2" sid="$3" hook_path="${4:-.claude/hooks/pre-push-gate.sh}"
  (
    cd "$sb" || exit 1
    # Capture stderr while discarding stdout.
    # shellcheck disable=SC2069
    push_json | env -u APEXYARD_OPS_DISABLE_PIN \
      CLAUDE_CODE_SESSION_ID="$sid" APEXYARD_OPS_PIN_DIR="$pin_dir" \
      bash "$hook_path" 2>&1 1>/dev/null
  )
}

# ---- #1504: a case-variant pin on a case-insensitive filesystem gets advice ----
case_case_variant_pin_gets_install_advice() {
  local probe; probe=$(mktemp -d)
  mkdir -p "$probe/CaseProbeXYZ"
  if [ ! "$probe/CaseProbeXYZ" -ef "$probe/caseprobexyz" ]; then
    echo "SKIP [case-variant-pin-gets-install-advice]: filesystem is case-sensitive"
    rm -rf "$probe"
    return
  fi
  rm -rf "$probe"

  # Build the fork under a lettered directory so a case flip changes the string.
  # A bare mktemp path often has no letters to fold.
  local base fork_real
  base=$(mktemp -d)
  fork_real="$base/OpsFork"
  mkdir -p "$fork_real"
  if ! (
    export GIT_CEILING_DIRECTORIES="$base"
    cd "$fork_real" || exit 1
    git init -q || exit 1
    git config user.email "test@example.com"
    git config user.name "test"
    touch onboarding.yaml .apexyard-fork
    git add onboarding.yaml .apexyard-fork
    git commit -q -m "init"
  ); then
    echo "FAIL: git init failed for case-variant sandbox at $fork_real — stop" >&2
    rm -rf "$base"
    kill $$ >/dev/null 2>&1
    exit 1
  fi
  mkdir -p "$fork_real/.claude/hooks"
  cp "$HOOK_SRC" "$fork_real/.claude/hooks/pre-push-gate.sh"
  chmod +x "$fork_real/.claude/hooks/pre-push-gate.sh"
  if [ -f "$(cd "$(dirname "$0")/../../.." && pwd)/.claude/hooks/_lib-ops-root.sh" ]; then
    cp "$(cd "$(dirname "$0")/../../.." && pwd)/.claude/hooks/_lib-ops-root.sh" \
      "$fork_real/.claude/hooks/_lib-ops-root.sh"
  fi
  fork_real=$(cd "$fork_real" && pwd -P)

  local sb_variant sid="test-session-case-pin" pin_dir out rc
  sb_variant=$(printf '%s' "$fork_real" | tr '[:lower:][:upper:]' '[:upper:][:lower:]')
  if [ "$sb_variant" = "$fork_real" ] || [ ! "$fork_real" -ef "$sb_variant" ]; then
    echo "SKIP [case-variant-pin-gets-install-advice]: no case-foldable path segment"
    rm -rf "$base"
    return
  fi

  pin_dir=$(make_pin "$sb_variant" "$sid")
  out=$(run_pinned_hook "$fork_real" "$pin_dir" "$sid")
  rc=$?
  if [ "$rc" = "0" ] && echo "$out" | grep -qF "core.hooksPath" &&
    ! echo "$out" | grep -qF "not an ApexYard fork"; then
    echo "PASS [case-variant-pin-gets-install-advice]"
    PASS=$((PASS+1))
  else
    echo "FAIL [case-variant-pin-gets-install-advice]: rc=$rc stderr=$out" >&2
    FAIL=$((FAIL+1))
    FAILED_CASES="${FAILED_CASES}case-variant-pin-gets-install-advice "
  fi
  rm -rf "$base" "$pin_dir"
}

case_case_variant_pin_gets_install_advice

echo ""
echo "==================================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "==================================="
if [ "$FAIL" -gt 0 ]; then
  echo "Failed: $FAILED_CASES" >&2
  exit 1
fi
exit 0
