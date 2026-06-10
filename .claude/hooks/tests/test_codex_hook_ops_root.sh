#!/bin/bash
# Regression test for generated Codex hook command root resolution.
#
# Codex runs tool hooks from the tool cwd. Inside workspace/<project>, that cwd
# can be a nested managed-project git repo. The generated hook command must
# still walk up to the ApexYard ops fork before execing .codex/hooks/<script>.

set -u

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HOOKS_JSON="$ROOT/.codex/hooks.json"

[ -f "$HOOKS_JSON" ] || { echo "FAIL: missing $HOOKS_JSON" >&2; exit 1; }

COMMAND=$(jq -r '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[0].command' "$HOOKS_JSON")
[ -n "$COMMAND" ] && [ "$COMMAND" != "null" ] || { echo "FAIL: could not extract Codex Bash hook command" >&2; exit 1; }

PASS=0
FAIL=0

green() { printf '\033[32m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*"; }

mark_pass() { PASS=$((PASS + 1)); green "PASS: $1"; }
mark_fail() {
  FAIL=$((FAIL + 1))
  red "FAIL: $1"
  [ -n "${2:-}" ] && echo "  detail: $2"
}

run_case() {
  local name="$1"
  local anchor="$2"
  local sb marker input_capture output status

  sb=$(mktemp -d)
  marker="$sb/hook-ran"
  input_capture="$sb/input.json"

  mkdir -p "$sb/ops/.codex/hooks" "$sb/ops/workspace/project"

  case "$anchor" in
    marker)
      touch "$sb/ops/.apexyard-fork"
      ;;
    legacy)
      touch "$sb/ops/onboarding.yaml"
      cat > "$sb/ops/apexyard.projects.yaml" <<'YAML'
version: 1
projects: []
YAML
      ;;
    *)
      mark_fail "$name" "unknown anchor $anchor"
      rm -rf "$sb"
      return
      ;;
  esac

  cat > "$sb/ops/.codex/hooks/codex-pre-bash.sh" <<'HOOK'
#!/bin/bash
printf 'ran from %s\n' "$PWD" > "$MARKER"
cat > "$INPUT_CAPTURE"
HOOK
  chmod +x "$sb/ops/.codex/hooks/codex-pre-bash.sh"

  (cd "$sb/ops/workspace/project" && git init -q)

  output=$(
    cd "$sb/ops/workspace/project" || exit 1
    printf '{"tool_name":"Bash","tool_input":{"command":"git status"}}' \
      | MARKER="$marker" INPUT_CAPTURE="$input_capture" bash -lc "$COMMAND" 2>&1
  )
  status=$?

  if [ "$status" = "0" ] \
     && [ -f "$marker" ] \
     && grep -q '"tool_name":"Bash"' "$input_capture" 2>/dev/null; then
    mark_pass "$name"
  else
    mark_fail "$name" "status=$status marker=$(test -f "$marker" && echo yes || echo no) output=[$output]"
  fi

  rm -rf "$sb"
}

run_case "Codex hook command finds v2 .apexyard-fork from nested managed-project git repo" marker
run_case "Codex hook command finds legacy onboarding.yaml + apexyard.projects.yaml from nested managed-project git repo" legacy

echo
echo "===== test_codex_hook_ops_root.sh ====="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[ "$FAIL" -eq 0 ]
