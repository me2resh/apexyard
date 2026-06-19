#!/usr/bin/env bash
# Regression test for me2resh/apexyard#629.
#
# `config_get` must keep returning project-config overrides even when the merged
# config contains a JSON value with a backslash escape (e.g. the shipped
# `pre_push` markdownlint command contains `tr '\n' '\0'` → JSON `\\n` / `\\0`).
#
# The original bug: config_get did `echo "$_CONFIG_CACHE" | jq`. Under a shell
# whose `echo` interprets backslash escapes (XSI / POSIX `echo`, or bash with
# `xpg_echo`), `echo` collapses the valid JSON `\\0` into an invalid `\0`, jq
# aborts on the whole document, and config_get returns empty for EVERY key —
# silently dropping all overrides (incl. split-portfolio `portfolio.*` paths).
# The fix uses `printf '%s'`, which never mangles its argument.
#
# This test forces the escape-interpreting behaviour with `shopt -s xpg_echo`
# so it reproduces the bug on the old code and passes on the fixed code. Under a
# plain bash `echo` (no xpg_echo) the bug is latent, so the guard would be
# meaningless without forcing the mode.

set -u
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/.claude"
: > "$TMP/.apexyard-fork"

cat > "$TMP/.claude/project-config.defaults.json" <<'JSON'
{ "portfolio": { "ideas_backlog": "./projects/ideas-backlog.md" } }
JSON

# Override carries (a) a portfolio override to assert, and (b) a value with a
# JSON backslash escape (`\\n` / `\\0`) — the exact shape that broke jq via echo.
cat > "$TMP/.claude/project-config.json" <<'JSON'
{
  "portfolio": { "ideas_backlog": "../portfolio/projects/ideas-backlog.md" },
  "pre_push": { "commands": [ { "name": "x", "run": "printf '%s' \"$f\" | tr '\\n' '\\0'" } ] }
}
JSON

pass=0; fail=0
ok() { echo "  ok: $1"; pass=$((pass + 1)); }
no() { echo "  FAIL: $1"; fail=$((fail + 1)); }

result="$(
  cd "$TMP" || exit 1
  export APEXYARD_OPS_DISABLE_PIN=1
  unset _CONFIG_CACHE _CONFIG_ROOT_CACHE 2>/dev/null || true
  shopt -s xpg_echo 2>/dev/null || true   # force the escape-interpreting echo that triggered #629
  # shellcheck source=/dev/null
  . "$HOOK_DIR/_lib-read-config.sh"
  got="$(config_get '.portfolio.ideas_backlog')"
  if [ "$got" = "../portfolio/projects/ideas-backlog.md" ]; then echo "PASS"; else echo "GOT:[$got]"; fi
)"

case "$result" in
  *PASS*) ok "config_get returns the override despite a backslash-escaped config value" ;;
  *)      no "config_get dropped the override under xpg_echo ($result)" ;;
esac

# Sanity: an unrelated key still resolves too (the whole document must parse).
result2="$(
  cd "$TMP" || exit 1
  export APEXYARD_OPS_DISABLE_PIN=1
  unset _CONFIG_CACHE _CONFIG_ROOT_CACHE 2>/dev/null || true
  shopt -s xpg_echo 2>/dev/null || true
  # shellcheck source=/dev/null
  . "$HOOK_DIR/_lib-read-config.sh"
  config_get '.pre_push.commands[0].name'
)"
[ "$result2" = "x" ] && ok "unrelated key resolves (document parses cleanly)" || no "unrelated key failed (got: [$result2])"

echo ""
if [ "$fail" -eq 0 ]; then
  echo "All $pass test(s) passed."
  exit 0
else
  echo "$fail test(s) failed."
  exit 1
fi
