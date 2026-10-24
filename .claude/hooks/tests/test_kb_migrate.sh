#!/bin/bash
# Tests for bin/kb-migrate.
set -u

# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
MIGRATE="$REPO_ROOT/bin/kb-migrate"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1 — $2"; }

FX=$(mktemp -d)
trap 'rm -rf "$FX"' EXIT

git -C "$FX" init -q
mkdir -p "$FX/handbooks/architecture" "$FX/handbooks/domain/emu"

# Plain handbook (no FM, no ENFORCEMENT).
cat > "$FX/handbooks/architecture/plain.md" <<'MD'
# Handbook: Plain Rule

Body text.
MD

# Blocking handbook (ENFORCEMENT first).
cat > "$FX/handbooks/architecture/blocking.md" <<'MD'
ENFORCEMENT: blocking

# Handbook: Blocking Rule

Body.
MD

# Domain handbook with paths: front matter.
cat > "$FX/handbooks/domain/emu/safety.md" <<'MD'
---
paths:
  - "scripts/emu/**"
  - "**/emu-*.ts"
---

# Handbook: EMU safety

Body.
MD

# README must not be a default target, but we can migrate it by path if asked.
cat > "$FX/handbooks/README.md" <<'MD'
# Handbooks README
MD

git -C "$FX" add handbooks
GIT_AUTHOR_DATE='2024-01-15T12:00:00' GIT_COMMITTER_DATE='2024-01-15T12:00:00' \
  git -C "$FX" -c user.name='Alice Author' -c user.email='alice@example.com' \
  commit -q -m 'add handbooks'

# --- defaults ---
out=$("$MIGRATE" --root "$FX" 2>&1) || true
echo "$out" | grep -q 'updated handbooks/architecture/plain.md' && pass "migrate updates plain" || fail "migrate updates plain" "$out"

fm=$(awk 'NR==1 && /^---$/ {f=1;next} f && /^---$/ {exit} f' "$FX/handbooks/architecture/plain.md")
echo "$fm" | grep -q '^owner: Alice Author$' && pass "owner from author" || fail "owner from author" "$fm"
echo "$fm" | grep -q '^verified_by: Alice Author$' && pass "verified_by from author" || fail "verified_by from author" "$fm"
echo "$fm" | grep -q '^verified_on: 2024-01-15$' && pass "verified_on from commit date" || fail "verified_on from commit date" "$fm"
echo "$fm" | grep -q '^stale_after: 2024-07-13$' && pass "stale_after +180d" || fail "stale_after +180d" "$fm"
echo "$fm" | grep -q '^sources: \[\]$' && pass "sources default" || fail "sources default" "$fm"
echo "$fm" | grep -q '^version: 1$' && pass "version default" || fail "version default" "$fm"
echo "$fm" | grep -q '^status: active$' && pass "status default" || fail "status default" "$fm"

# --- ENFORCEMENT kept after block ---
first=$(head -n 1 "$FX/handbooks/architecture/blocking.md")
[ "$first" = "---" ] && pass "blocking starts with ---" || fail "blocking starts with ---" "$first"
# First non-empty line after closing ---
after=$(awk 'BEGIN{c=0} /^---$/{c++; next} c>=2 && NF{print; exit}' "$FX/handbooks/architecture/blocking.md")
[ "$after" = "ENFORCEMENT: blocking" ] && pass "ENFORCEMENT after FM" || fail "ENFORCEMENT after FM" "$after"

# --- paths: kept byte for byte ---
paths_block=$(awk '
  BEGIN { take=0 }
  /^paths:/ { take=1; print; next }
  take && /^[^[:space:]-]/ { exit }
  take { print }
' "$FX/handbooks/domain/emu/safety.md")
want=$(printf '%s\n' 'paths:' '  - "scripts/emu/**"' '  - "**/emu-*.ts"')
[ "$paths_block" = "$want" ] && pass "paths kept byte for byte" || fail "paths kept byte for byte" "got=[$paths_block]"

# Schema keys added beside paths
fm_d=$(awk 'NR==1 && /^---$/ {f=1;next} f && /^---$/ {exit} f' "$FX/handbooks/domain/emu/safety.md")
echo "$fm_d" | grep -q '^owner: Alice Author$' && pass "domain got owner" || fail "domain got owner" "$fm_d"

kb_hash() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

# --- second run unchanged ---
before_plain=$(kb_hash "$FX/handbooks/architecture/plain.md")
before_block=$(kb_hash "$FX/handbooks/architecture/blocking.md")
before_domain=$(kb_hash "$FX/handbooks/domain/emu/safety.md")
out2=$("$MIGRATE" --root "$FX" 2>&1) || true
echo "$out2" | grep -q 'unchanged handbooks/architecture/plain.md' && pass "second run unchanged plain" || fail "second run unchanged plain" "$out2"
echo "$out2" | grep -vq 'updated ' && pass "second run no updates" || fail "second run no updates" "$out2"
[ "$(kb_hash "$FX/handbooks/architecture/plain.md")" = "$before_plain" ] && pass "plain bytes identical" || fail "plain bytes identical" ""
[ "$(kb_hash "$FX/handbooks/architecture/blocking.md")" = "$before_block" ] && pass "blocking bytes identical" || fail "blocking bytes identical" ""
[ "$(kb_hash "$FX/handbooks/domain/emu/safety.md")" = "$before_domain" ] && pass "domain bytes identical" || fail "domain bytes identical" ""

# --- dry-run writes nothing ---
mkdir -p "$FX/handbooks/general"
cat > "$FX/handbooks/general/new.md" <<'MD'
# Handbook: New

Body.
MD
git -C "$FX" add handbooks/general/new.md
GIT_AUTHOR_DATE='2024-01-15T12:00:00' GIT_COMMITTER_DATE='2024-01-15T12:00:00' \
  git -C "$FX" -c user.name='Alice Author' -c user.email='alice@example.com' \
  commit -q -m 'add new'
h_before=$(kb_hash "$FX/handbooks/general/new.md")
out3=$("$MIGRATE" --root "$FX" --dry-run handbooks/general/new.md 2>&1) || true
echo "$out3" | grep -q 'would-update' && pass "dry-run would-update" || fail "dry-run would-update" "$out3"
[ "$(kb_hash "$FX/handbooks/general/new.md")" = "$h_before" ] && pass "dry-run writes nothing" || fail "dry-run writes nothing" ""
if grep -q '^owner:' "$FX/handbooks/README.md" 2>/dev/null; then
  fail "README not default target" "README got front matter"
else
  pass "README not default target"
fi


echo
echo "Total: $((PASS + FAIL))  Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
