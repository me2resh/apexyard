#!/bin/bash
# Smoke tests for .claude/hooks/_lib-detect-deprecated-config.sh
#
# Each case:
#   - builds a tiny sandbox containing a defaults JSON + an override JSON
#   - sources the helper and asserts behaviour
#
# Exit 0 means all cases passed. Exit 1 on first failure.

set -u

LIB_SRC="$(cd "$(dirname "$0")/.." && pwd)/_lib-detect-deprecated-config.sh"

if [ ! -f "$LIB_SRC" ]; then
  echo "FAIL: helper not found at $LIB_SRC" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not installed; skipping deprecated-config detection tests."
  exit 0
fi

PASS=0
FAIL=0
FAILED_CASES=""

# ---------------------------------------------------------------------------
# make_sandbox: build a tmp dir and write defaults + override JSON content
# passed in $1 (defaults JSON literal) and $2 (override JSON literal).
# ---------------------------------------------------------------------------
make_sandbox() {
  local defaults_json="$1"
  local overrides_json="$2"
  local sb
  sb=$(mktemp -d)
  sb=$(cd "$sb" && pwd -P)
  printf '%s\n' "$defaults_json"  > "$sb/defaults.json"
  printf '%s\n' "$overrides_json" > "$sb/overrides.json"
  echo "$sb"
}

# ---------------------------------------------------------------------------
# run_case <name> <defaults> <overrides> <expected-newline-separated-keys>
# ---------------------------------------------------------------------------
run_case() {
  local name="$1"
  local defaults_json="$2"
  local overrides_json="$3"
  local expected="$4"

  local sb actual
  sb=$(make_sandbox "$defaults_json" "$overrides_json")

  # shellcheck source=/dev/null
  . "$LIB_SRC"
  actual=$(detect_deprecated_config_keys "$sb/defaults.json" "$sb/overrides.json")

  if [ "$actual" = "$expected" ]; then
    PASS=$((PASS + 1))
    echo "PASS: $name"
  else
    FAIL=$((FAIL + 1))
    FAILED_CASES="$FAILED_CASES\n  - $name"
    echo "FAIL: $name"
    echo "  expected: $(printf '%q' "$expected")"
    echo "  actual:   $(printf '%q' "$actual")"
  fi

  rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# Case 1: override has only a known-deprecated key (whole block removed
# upstream, e.g. voice_prompts after #157) → flagged
# ---------------------------------------------------------------------------
run_case "single deprecated key flagged" \
'{
  "ticket": {"prefix_whitelist": ["Feature"]},
  "branch": {"type_whitelist": ["feature"]}
}' \
'{
  "voice_prompts": {"on_pause": "ping"}
}' \
'voice_prompts'

# ---------------------------------------------------------------------------
# Case 2: override has a custom-extension key that isn't in defaults →
# surfaced (advisory). The detector's job is to flag *anything* not in
# defaults; the skill's y/n/s prompt is what makes it informational rather
# than destructive. So this case asserts the key IS surfaced — the
# operator decides whether to keep it on the [s]how branch.
# ---------------------------------------------------------------------------
run_case "custom extension key is surfaced (advisory)" \
'{
  "ticket": {"prefix_whitelist": ["Feature"]}
}' \
'{
  "ticket": {"prefix_whitelist": ["Feature", "Custom"]},
  "my_team_extension": {"foo": "bar"}
}' \
'my_team_extension'

# ---------------------------------------------------------------------------
# Case 3: override has metadata keys (_comment, _schema_version) → NOT flagged
# ---------------------------------------------------------------------------
run_case "leading-underscore metadata keys are whitelisted" \
'{
  "ticket": {"prefix_whitelist": ["Feature"]}
}' \
'{
  "_comment": "user notes about overrides",
  "_schema_version": 1,
  "_team_comment": "more notes",
  "ticket": {"prefix_whitelist": ["Feature"]}
}' \
''

# ---------------------------------------------------------------------------
# Case 4: override matches defaults' top-level shape → no offer
# ---------------------------------------------------------------------------
run_case "override aligned with defaults yields no flags" \
'{
  "ticket": {"prefix_whitelist": ["Feature"]},
  "branch": {"type_whitelist": ["feature"]},
  "pr": {"required_sections": ["Glossary"]}
}' \
'{
  "ticket": {"prefix_whitelist": ["Feature", "Bug"]},
  "branch": {"type_whitelist": ["feature", "fix"]}
}' \
''

# ---------------------------------------------------------------------------
# Case 5: multiple deprecated keys are emitted sorted (stable output)
# ---------------------------------------------------------------------------
run_case "multiple deprecated keys emitted sorted" \
'{
  "ticket": {"prefix_whitelist": ["Feature"]}
}' \
'{
  "voice_prompts": {"on_pause": "ping"},
  "abandoned_block": {"x": 1},
  "ticket": {"prefix_whitelist": ["Feature"]}
}' \
'abandoned_block
voice_prompts'

# ---------------------------------------------------------------------------
# Case 6: missing override file → empty (no flags, no error to caller)
# ---------------------------------------------------------------------------
echo
echo "Case 6: missing override file"
SB6=$(mktemp -d)
SB6=$(cd "$SB6" && pwd -P)
cat > "$SB6/defaults.json" <<'JSON'
{ "ticket": {"prefix_whitelist": ["Feature"]} }
JSON
# shellcheck source=/dev/null
. "$LIB_SRC"
out6=$(detect_deprecated_config_keys "$SB6/defaults.json" "$SB6/missing.json")
rc6=$?
if [ -z "$out6" ] && [ "$rc6" -eq 0 ]; then
  PASS=$((PASS + 1))
  echo "PASS: missing override file -> empty output, exit 0"
else
  FAIL=$((FAIL + 1))
  FAILED_CASES="$FAILED_CASES\n  - missing override file"
  echo "FAIL: missing override file (out='$out6', rc=$rc6)"
fi
rm -rf "$SB6"

# ---------------------------------------------------------------------------
# Case 7: remove_deprecated_config_keys actually deletes flagged keys
# ---------------------------------------------------------------------------
echo
echo "Case 7: remove_deprecated_config_keys"
SB7=$(mktemp -d)
SB7=$(cd "$SB7" && pwd -P)
cat > "$SB7/defaults.json" <<'JSON'
{ "ticket": {"prefix_whitelist": ["Feature"]} }
JSON
cat > "$SB7/overrides.json" <<'JSON'
{
  "_comment": "keep me",
  "voice_prompts": {"on_pause": "ping"},
  "abandoned_block": {"x": 1},
  "ticket": {"prefix_whitelist": ["Feature", "Bug"]}
}
JSON
# shellcheck source=/dev/null
. "$LIB_SRC"
removed=$(remove_deprecated_config_keys "$SB7/defaults.json" "$SB7/overrides.json")
remaining=$(jq -r 'keys | join(",")' "$SB7/overrides.json" 2>/dev/null)
if [ "$removed" = "2" ] && [ "$remaining" = "_comment,ticket" ]; then
  PASS=$((PASS + 1))
  echo "PASS: remove deletes deprecated keys, preserves whitelisted + active"
else
  FAIL=$((FAIL + 1))
  FAILED_CASES="$FAILED_CASES\n  - remove deletes flagged keys"
  echo "FAIL: removed=$removed remaining=$remaining"
fi
rm -rf "$SB7"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "=========================================="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo -e "Failed cases:$FAILED_CASES"
  exit 1
fi
exit 0
