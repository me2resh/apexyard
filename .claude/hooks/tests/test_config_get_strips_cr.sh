#!/usr/bin/env bash
# Regression test for me2resh/apexyard#1019.
#
# `config_get` must return plain \n-delimited text with no embedded carriage
# returns, even when the underlying jq emits CRLF line endings.
#
# The bug: on Windows (Git Bash / MSYS2) the native jq.exe writes stdout through
# a text-mode CRT handle, silently rewriting every \n it emits into \r\n. A
# SINGLE-value filter is unharmed — command substitution strips the one trailing
# newline and takes the \r with it — but a MULTI-line filter (e.g.
# `.branch.type_whitelist[]`) leaves a \r baked into every line except the last.
# Callers that join with `paste -sd'|' -` then build a regex alternation
# containing stray carriage returns, which can never match a real branch name or
# PR title. Since validate-branch-name.sh and validate-pr-create.sh BLOCK on
# failure, Windows adopters could not create a compliant branch or PR at all.
# Ten hooks read multi-line config values, so the fix lives in config_get.
#
# macOS/Linux jq never emits CRLF, so the bug is latent here and a naive test
# would pass on the OLD code too — proving nothing. This test therefore forces
# the Windows behaviour with a stub `jq` earlier on PATH that appends \r to every
# line, exactly as jq.exe does. That reproduces the failure on the old code and
# passes only on the fixed code.

set -u
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
check() { # check <label> <expected> <actual>
  if [ "$2" = "$3" ]; then
    PASS=$((PASS + 1)); printf 'PASS [%s]\n' "$1"
  else
    FAIL=$((FAIL + 1)); printf 'FAIL [%s]\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"
  fi
}

mkdir -p "$TMP/.claude"
: > "$TMP/.apexyard-fork"

cat > "$TMP/.claude/project-config.defaults.json" <<'JSON'
{
  "branch": { "type_whitelist": ["feature", "fix", "chore"] },
  "tracker": { "kind": "gh" }
}
JSON

# --- Stub jq that mimics Windows jq.exe -------------------------------------
# Wraps the real jq and rewrites every emitted \n into \r\n. awk is used rather
# than `sed 's/$/\r/'` because BSD/macOS sed does not interpret a \r escape.
REAL_JQ="$(command -v jq 2>/dev/null)"
if [ -z "$REAL_JQ" ]; then
  echo "SKIP: jq not installed — cannot simulate the Windows CRLF path"
  exit 0
fi

mkdir -p "$TMP/bin"
cat > "$TMP/bin/jq" <<EOF
#!/usr/bin/env bash
"$REAL_JQ" "\$@" | awk '{ printf "%s\r\n", \$0 }'
EOF
chmod +x "$TMP/bin/jq"

PATH="$TMP/bin:$PATH"
export PATH

cd "$TMP" || exit 1
# APEXYARD_OPS_DISABLE_PIN: without this the session ops-root pin wins over the
# temp fixture and config_get reads the REAL repo config, so every assertion
# below would silently test the wrong file.
export APEXYARD_OPS_DISABLE_PIN=1
unset _CONFIG_CACHE _CONFIG_ROOT_CACHE 2>/dev/null || true
# shellcheck source=/dev/null
. "$HOOK_DIR/_lib-read-config.sh"

# --- 1. multi-line output carries no CR ---------------------------------------
raw="$(config_get '.branch.type_whitelist[]')"
cr_count="$(printf '%s' "$raw" | tr -dc '\r' | wc -c | tr -d ' ')"
check "multi-line config_get output contains no carriage return" "0" "$cr_count"

# --- 2. the joined alternation is usable --------------------------------------
# This is the shape validate-branch-name.sh and validate-pr-create.sh build.
types="$(config_get '.branch.type_whitelist[]' | paste -sd'|' -)"
check "joined alternation is clean" "feature|fix|chore" "$types"

# --- 3. the alternation actually matches a real branch name -------------------
# The user-visible symptom: with \r present this regex matched nothing, so the
# validators rejected every branch.
branch="feature/GH-1019-example"
if printf '%s' "$branch" | grep -qE "^(${types})/"; then
  matched="yes"
else
  matched="no"
fi
check "a valid branch name matches the built alternation" "yes" "$matched"

# --- 4. single-value lookups still work (no over-stripping) -------------------
check "single-value lookup unaffected" "gh" "$(config_get '.tracker.kind')"

# --- 5. a value containing an INTERNAL carriage return is preserved -----------
# The strip is deliberately anchored to end-of-line so it cannot corrupt a
# legitimate mid-string CR. A blanket `tr -d '\r'` would fail this case.
cat > "$TMP/.claude/project-config.json" <<'JSON'
{ "custom": { "value": "before\rafter" } }
JSON
# Assign empty rather than `unset` — the lib reads these under `set -u`, so
# unsetting them here makes it abort with "unbound variable" instead of reloading.
_CONFIG_CACHE=""
_CONFIG_ROOT_CACHE=""
inner="$(config_get '.custom.value' | tr -dc '\r' | wc -c | tr -d ' ')"
check "mid-string carriage return is preserved, not stripped" "1" "$inner"

echo
echo "==================================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "==================================="
[ "$FAIL" -eq 0 ]
