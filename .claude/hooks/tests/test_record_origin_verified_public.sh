#!/bin/bash
# Tests for bin/record-origin-verified-public.sh (#1477 / AgDR-0190).
# Uses a stubbed `gh` on PATH. No network.

set -u

ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
SCRIPT="$ROOT/bin/record-origin-verified-public.sh"

PASS=0
FAIL=0

pass() { printf '  ok   %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL %s: %s\n' "$1" "$2" >&2; FAIL=$((FAIL + 1)); }

make_repo() {
  local sandbox origin_url
  sandbox=$(mktemp -d) || exit 1
  origin_url=${1:-https://github.com/acme/public-ops.git}
  (
    cd "$sandbox" || exit 1
    git init -q
    git config user.email test@example.com
    git config user.name Test
    printf 'x\n' > README.md
    git add README.md
    git commit -q -m baseline
    git remote add origin "$origin_url"
  )
  printf '%s\n' "$sandbox"
}

install_stub_gh() {
  local sandbox="$1" visibility="$2" fail_mode="${3:-}"
  mkdir -p "$sandbox/bin"
  cat > "$sandbox/bin/gh" <<SH
#!/bin/sh
if [ "$fail_mode" = "fail" ]; then
  echo "gh: simulated failure" >&2
  exit 1
fi
if [ "\$1" = "repo" ] && [ "\$2" = "view" ]; then
  printf '%s\\n' '{"visibility":"$visibility","isFork":false}'
  exit 0
fi
echo "unexpected gh args: \$*" >&2
exit 2
SH
  chmod +x "$sandbox/bin/gh"
}

echo '== record-origin-verified-public.sh =='

sandbox=$(make_repo)
install_stub_gh "$sandbox" PUBLIC
out=$(cd "$sandbox" && PATH="$sandbox/bin:$PATH" bash "$SCRIPT" --repo-dir "$sandbox" 2>&1)
rc=$?
if [ "$rc" -eq 0 ] \
  && printf '%s' "$out" | grep -qF 'origin_verified_public=acme/public-ops' \
  && [ "$(jq -r '.leak_protection.origin_verified_public' "$sandbox/.claude/project-config.json")" = "acme/public-ops" ]; then
  pass 'writes key when gh reports PUBLIC'
else
  fail 'writes key when gh reports PUBLIC' "rc=$rc out=$out"
fi
rm -rf "$sandbox"

sandbox=$(make_repo)
install_stub_gh "$sandbox" PRIVATE
out=$(cd "$sandbox" && PATH="$sandbox/bin:$PATH" bash "$SCRIPT" --repo-dir "$sandbox" 2>&1)
rc=$?
if [ "$rc" -eq 1 ] \
  && printf '%s' "$out" | grep -qF 'Origin exemption is OFF' \
  && [ ! -f "$sandbox/.claude/project-config.json" ]; then
  pass 'writes nothing when gh reports PRIVATE'
else
  fail 'writes nothing when gh reports PRIVATE' "rc=$rc out=$out exists=$( [ -f "$sandbox/.claude/project-config.json" ] && echo yes || echo no )"
fi
rm -rf "$sandbox"

sandbox=$(make_repo)
install_stub_gh "$sandbox" PUBLIC fail
out=$(cd "$sandbox" && PATH="$sandbox/bin:$PATH" bash "$SCRIPT" --repo-dir "$sandbox" 2>&1)
rc=$?
if [ "$rc" -eq 1 ] \
  && printf '%s' "$out" | grep -qF 'Origin exemption is OFF' \
  && [ ! -f "$sandbox/.claude/project-config.json" ]; then
  pass 'writes nothing when gh repo view fails'
else
  fail 'writes nothing when gh repo view fails' "rc=$rc out=$out"
fi
rm -rf "$sandbox"

# Preserve an existing unrelated override key when writing.
sandbox=$(make_repo)
install_stub_gh "$sandbox" PUBLIC
mkdir -p "$sandbox/.claude"
printf '%s\n' '{"tracker":{"kind":"gh"},"leak_protection":{"skip_marker":"<!-- x -->"}}' \
  > "$sandbox/.claude/project-config.json"
out=$(cd "$sandbox" && PATH="$sandbox/bin:$PATH" bash "$SCRIPT" --repo-dir "$sandbox" 2>&1)
rc=$?
kind=$(jq -r '.tracker.kind' "$sandbox/.claude/project-config.json")
marker=$(jq -r '.leak_protection.skip_marker' "$sandbox/.claude/project-config.json")
slug=$(jq -r '.leak_protection.origin_verified_public' "$sandbox/.claude/project-config.json")
if [ "$rc" -eq 0 ] && [ "$kind" = "gh" ] && [ "$marker" = "<!-- x -->" ] \
  && [ "$slug" = "acme/public-ops" ]; then
  pass 'merges key without wiping other project-config fields'
else
  fail 'merges key without wiping other project-config fields' \
    "rc=$rc kind=$kind marker=$marker slug=$slug out=$out"
fi
rm -rf "$sandbox"

printf 'Passed: %s  Failed: %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
