#!/bin/bash
# Tests that bin/kb-compile makes no network call unless --push and both env vars are set.
set -u

# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
COMPILE="$REPO_ROOT/bin/kb-compile"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1 — $2"; }

FX=$(mktemp -d)
FAKEBIN=$(mktemp -d)
MARKER=$(mktemp)
trap 'rm -rf "$FX" "$FAKEBIN"; rm -f "$MARKER"' EXIT

git -C "$FX" init -q
mkdir -p "$FX/handbooks/architecture"
cat > "$FX/handbooks/architecture/a.md" <<'MD'
# Handbook: A

Body.
MD
git -C "$FX" add handbooks
git -C "$FX" -c user.name='N' -c user.email='n@example.com' commit -q -m 'a'

# Fake curl that writes a marker when called.
cat > "$FAKEBIN/curl" <<'EOF'
#!/usr/bin/env bash
printf 'called\n' >> "${KB_CURL_MARKER}"
# Swallow args; pretend success.
exit 0
EOF
chmod +x "$FAKEBIN/curl"
export KB_CURL_MARKER="$MARKER"
export PATH="$FAKEBIN:$PATH"

: > "$MARKER"
out=$("$COMPILE" --root "$FX" --out "$FX/kb" 2>&1)
err=0
echo "$out" | grep -q 'secret-token-value' && err=1
if [ ! -s "$MARKER" ]; then
  pass "no curl without --push"
else
  fail "no curl without --push" "marker written"
fi
[ "$err" -eq 0 ] && pass "no token in output (no push)" || fail "no token in output (no push)" "$out"

: > "$MARKER"
unset APEXYARD_TOKEN APEXYARD_KB_ENDPOINT
export APEXYARD_TOKEN='secret-token-value'
out=$("$COMPILE" --root "$FX" --out "$FX/kb" --push 2>&1)
rc=$?
echo "$out" | grep -q 'push skipped' && pass "push skipped one var" || fail "push skipped one var" "$out"
[ "$rc" -eq 0 ] && pass "push skip exit 0" || fail "push skip exit 0" "rc=$rc"
if [ ! -s "$MARKER" ]; then
  pass "no curl with only TOKEN"
else
  fail "no curl with only TOKEN" "marker written"
fi
echo "$out" | grep -q 'secret-token-value' && fail "token not printed (TOKEN only)" "$out" || pass "token not printed (TOKEN only)"

: > "$MARKER"
unset APEXYARD_TOKEN
export APEXYARD_KB_ENDPOINT='https://example.test/kb'
out=$("$COMPILE" --root "$FX" --out "$FX/kb" --push 2>&1)
echo "$out" | grep -q 'push skipped' && pass "push skipped endpoint only" || fail "push skipped endpoint only" "$out"
if [ ! -s "$MARKER" ]; then
  pass "no curl with only ENDPOINT"
else
  fail "no curl with only ENDPOINT" "marker written"
fi

: > "$MARKER"
export APEXYARD_TOKEN='secret-token-value'
export APEXYARD_KB_ENDPOINT='https://example.test/kb'
out=$("$COMPILE" --root "$FX" --out "$FX/kb" --push 2>&1)
if [ -s "$MARKER" ]; then
  pass "curl with --push and both vars"
else
  fail "curl with --push and both vars" "no marker: $out"
fi
echo "$out" | grep -q 'secret-token-value' && fail "token not printed (both set)" "$out" || pass "token not printed (both set)"

echo
echo "Total: $((PASS + FAIL))  Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
