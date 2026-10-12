#!/bin/bash
# test_reviewer_github_app.sh — opt-in GitHub App identity for gh reviews (#1538).
#
# review_identity.kind=operator (the default) posts with the operator gh login.
# kind=github_app mints an installation token and sets GH_TOKEN for that one
# gh pr review command. The token is not exported, logged, or written to disk.
# A private key inside a git work tree or under .claude/ is refused.
# Mint failure fails closed unless fallback=comment, which posts a comment
# with the operator login. tracker_pr_merge never uses the app token.
#
# Mocks stand in for openssl, curl, and gh. No real review is posted.

set -u

# Isolate from live Claude Code session pin/cache (me2resh/apexyard#1549).
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"

unset APEXYARD_OPS_PIN_DIR CLAUDE_CODE_SESSION_ID 2>/dev/null || true
unset GH_HOST GITHUB_API_URL GH_ENTERPRISE_TOKEN 2>/dev/null || true

HOOK_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TRACKER_LIB="$HOOK_DIR/_lib-tracker.sh"
CONFIG_LIB="$HOOK_DIR/_lib-read-config.sh"
PORTFOLIO_LIB="$HOOK_DIR/_lib-portfolio-paths.sh"
OPSROOT_LIB="$HOOK_DIR/_lib-ops-root.sh"
RUNTIME_SCANNER="$HOOK_DIR/check-private-refs-runtime.sh"
DEFAULTS_JSON="$(cd "$HOOK_DIR/.." && pwd)/project-config.defaults.json"

PASS=0
FAIL=0
FAILED=""
pass() { PASS=$((PASS+1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL+1)); FAILED="$FAILED\n  - $1"; echo "FAIL: $1"; echo "    expected: [$2]"; echo "    actual:   [$3]"; }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "$2" "$3"; fi; }
assert_contains() {
  if grep -F -q -e "$2" "$3"; then pass "$1"; else fail "$1" "present" "absent"; fi
}

KEY_MARKER="FAKEKEYMATERIAL1538"
MOCK_OPERATOR_TOKEN="gho_OperatorToken1538"
MOCK_INSTALL_TOKEN="ghs_AppInstallToken1538"
export MOCK_OPERATOR_TOKEN MOCK_INSTALL_TOKEN
export GH_TOKEN="$MOCK_OPERATOR_TOKEN"

if ! command -v jq >/dev/null 2>&1; then
  echo "FAIL: jq is required"
  exit 1
fi

# Default config is operator and does not name a key.
kind_default=$(jq -r '.review_identity.kind' "$DEFAULTS_JSON")
app_default=$(jq -r '.review_identity.app_id' "$DEFAULTS_JSON")
fb_default=$(jq -r '.review_identity.fallback' "$DEFAULTS_JSON")
assert_eq "default review_identity.kind is operator" "operator" "$kind_default"
assert_eq "default review_identity.app_id is empty" "" "$app_default"
assert_eq "default review_identity.fallback is empty" "" "$fb_default"
if jq empty "$DEFAULTS_JSON" >/dev/null 2>&1; then
  pass "project-config.defaults.json is valid JSON"
else
  fail "project-config.defaults.json is valid JSON" "valid" "jq empty failed"
fi

# Pin the JWT window in the library source. The openssl mock does not check it.
assert_eq "jwt iat is 60 seconds before now" "1" "$(grep -c 'now - 60' "$TRACKER_LIB")"
assert_eq "jwt exp is 9 minutes after now" "1" "$(grep -c 'now + 540' "$TRACKER_LIB")"
assert_eq "jwt is RS256 via openssl dgst -sha256 -sign" "1" "$(grep -c 'dgst -sha256 -sign' "$TRACKER_LIB")"

make_sandbox() {
  local sb
  sb=$(mktemp -d)
  sb=$(cd "$sb" && pwd -P)
  mkdir -p "$sb/.claude/hooks" "$sb/bin" "$sb/secrets"
  touch "$sb/onboarding.yaml"
  cp "$TRACKER_LIB" "$sb/.claude/hooks/_lib-tracker.sh"
  cp "$CONFIG_LIB" "$sb/.claude/hooks/_lib-read-config.sh"
  cp "$PORTFOLIO_LIB" "$sb/.claude/hooks/_lib-portfolio-paths.sh"
  cp "$RUNTIME_SCANNER" "$sb/.claude/hooks/check-private-refs-runtime.sh"
  chmod +x "$sb/.claude/hooks/check-private-refs-runtime.sh"
  [ -f "$OPSROOT_LIB" ] && cp "$OPSROOT_LIB" "$sb/.claude/hooks/_lib-ops-root.sh"
  printf '%s\n' '{ "tracker": { "kind": "gh" } }' > "$sb/.claude/project-config.defaults.json"
  printf 'version: 1\nprojects: []\n' > "$sb/apexyard.projects.yaml"
  : > "$sb/authorized-key-files"
  echo "$sb"
}

install_mocks() {
  local sb="$1"
  cat > "$sb/bin/openssl" <<'EOF'
#!/bin/bash
if [ -n "${OPENSSL_LOG:-}" ]; then
  printf '%s\n' "$*" >> "$OPENSSL_LOG"
fi
cat >/dev/null
if [ "${OPENSSL_RC:-0}" != "0" ]; then
  echo "openssl failed" >&2
  exit "${OPENSSL_RC}"
fi
case "${1:-}" in
  base64|dgst) printf 'e30' ;;
  *) echo "unexpected openssl" >&2; exit 1 ;;
esac
EOF
  cat > "$sb/bin/curl" <<'EOF'
#!/bin/bash
in=$(cat)
if [ "${1:-}" != "-q" ]; then
  # Model a hostile curlrc exposing the request and response.
  if [ -f "${CURL_HOME:-}/.curlrc" ]; then
    printf '%s\n' "$in" >&2
    printf '%s\n' "$in" "$MOCK_INSTALL_TOKEN" > "$CURL_HOME/trace.txt"
  fi
  echo "curl stub: -q must be the first argument" >&2
  exit 1
fi
if [ -n "${CURL_LOG:-}" ]; then
  {
    printf '%s\n' "$in"
    if [ -n "${MOCK_INSTALL_TOKEN:-}" ] && [ "${GH_TOKEN:-}" = "${MOCK_INSTALL_TOKEN}" ]; then
      printf '%s\n' "LEAKED_APP_TOKEN"
    fi
  } >> "$CURL_LOG"
fi
if [ "${CURL_RC:-0}" != "0" ]; then
  echo "curl failed" >&2
  exit "${CURL_RC}"
fi
printf '{"token":"%s","expires_at":"2099-01-01T00:00:00Z"}' "${MOCK_INSTALL_TOKEN}"
EOF
  cat > "$sb/bin/gh" <<'EOF'
#!/bin/bash
if [ -n "${GH_LOG:-}" ]; then
  {
    printf '%s\n' "cmd:$*"
    if [ -n "${MOCK_INSTALL_TOKEN:-}" ] && [ "${GH_TOKEN:-}" = "${MOCK_INSTALL_TOKEN}" ]; then
      printf '%s\n' "auth:app"
    elif [ -n "${MOCK_OPERATOR_TOKEN:-}" ] && [ "${GH_TOKEN:-}" = "${MOCK_OPERATOR_TOKEN}" ]; then
      printf '%s\n' "auth:operator"
    elif [ -z "${GH_TOKEN:-}" ]; then
      printf '%s\n' "auth:unset"
    else
      printf '%s\n' "auth:unexpected"
    fi
  } >> "$GH_LOG"
fi
if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
  printf '%s\n' "deadbeef00000000000000000000000000000000"
  exit 0
fi
if [ "${GH_RC:-0}" != "0" ] && [ -n "${MOCK_INSTALL_TOKEN:-}" ] && [ "${GH_TOKEN:-}" = "${MOCK_INSTALL_TOKEN}" ]; then
  echo "gh app review failed" >&2
  exit "${GH_RC}"
fi
exit 0
EOF
  chmod +x "$sb/bin/openssl" "$sb/bin/curl" "$sb/bin/gh"
}

write_key() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "-----BEGIN RSA PRIVATE KEY-----" "$KEY_MARKER" "-----END RSA PRIVATE KEY-----" > "$path"
  printf '%s\n' "$path" >> "$SB/authorized-key-files"
}

write_config() {
  local kind="$1" key="$2" fallback="$3" app_id="${4:-123}" inst="${5:-456}"
  cat > "$SB/.claude/project-config.defaults.json" <<EOF
{
  "tracker": { "kind": "gh" },
  "review_identity": {
    "kind": "$kind",
    "app_id": "$app_id",
    "installation_id": "$inst",
    "private_key_path": "$key",
    "fallback": "$fallback"
  }
}
EOF
}

reset_logs() {
  : > "$SB/openssl.log"
  : > "$SB/curl.log"
  : > "$SB/gh.log"
  OPENSSL_RC=0
  CURL_RC=0
  GH_RC=0
  export OPENSSL_RC CURL_RC GH_RC
  export OPENSSL_LOG="$SB/openssl.log" CURL_LOG="$SB/curl.log" GH_LOG="$SB/gh.log"
}

# Run a review under xtrace. The token must not show up in the trace.
run_review() {
  local verdict="$1"
  : > "$SB/out"
  : > "$SB/err"
  (
    set -x
    tracker_review_submit "o/r" 42 "$verdict" "$BODY"
    echo "rc:$?"
  ) >"$SB/out" 2>"$SB/err"
  sed -n 's/^rc://p' "$SB/out" | tail -n 1
}

assert_no_needle() {
  local label="$1" needle="$2" allow="$3"
  local hits="" f="" bad=0
  hits=$(grep -R -F -l -e "$needle" "$SB" 2>/dev/null || true)
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if [ -n "$allow" ] && [ -f "$allow" ] && grep -F -x -q -e "$f" "$allow"; then
      continue
    fi
    bad=1
    break
  done <<EOF
$hits
EOF
  if [ "$bad" -eq 0 ]; then
    pass "$label"
  else
    fail "$label" "absent" "present"
  fi
}

assert_secret_clean() {
  local label="$1"
  assert_no_needle "$label token absent" "$MOCK_INSTALL_TOKEN" ""
  assert_no_needle "$label key absent" "$KEY_MARKER" "$SB/authorized-key-files"
  if grep -F -q -e "LEAKED_APP_TOKEN" "$SB/curl.log" "$SB/openssl.log" "$SB/gh.log" 2>/dev/null; then
    fail "$label app token not attached to curl or openssl" "absent" "present"
  else
    pass "$label app token not attached to curl or openssl"
  fi
}

# ---------------------------------------------------------------------------
SB=$(make_sandbox)
install_mocks "$SB"
case "$SB" in
  */.claude|*/.claude/*)
    echo "FAIL: sandbox path is under .claude: $SB"
    exit 1
    ;;
esac
inside=$(env -u GIT_DIR -u GIT_WORK_TREE git -C "$SB" rev-parse --is-inside-work-tree 2>/dev/null || true)
if [ "$inside" = "true" ]; then
  echo "FAIL: sandbox is inside a git work tree: $SB"
  exit 1
fi

cd "$SB" || { echo "FAIL: cd sandbox"; exit 1; }
# shellcheck source=/dev/null
. "$SB/.claude/hooks/_lib-tracker.sh"
export PATH="$SB/bin:$PATH"
BODY="$SB/rev.md"
printf 'Approved review body.\n' > "$BODY"
write_key "$SB/secrets/app.pem"

# Case 1 — operator kind ignores app fields and does not mint.
reset_logs
write_config "operator" "$SB/secrets/app.pem" ""
tracker_clear_cache
rc=$(run_review approve)
assert_eq "operator mode → exit 0" "0" "$rc"
assert_eq "operator mode → no openssl call" "0" "$(grep -c . "$SB/openssl.log" || true)"
assert_eq "operator mode → no curl call" "0" "$(grep -c . "$SB/curl.log" || true)"
assert_eq "operator mode → --approve" "1" "$(grep -c -- '--approve' "$SB/gh.log")"
assert_eq "operator mode → operator token" "1" "$(grep -c 'auth:operator' "$SB/gh.log")"
assert_eq "operator mode → app token not used" "0" "$(grep -c 'auth:app' "$SB/gh.log")"
assert_eq "operator mode → GH_TOKEN unchanged" "$MOCK_OPERATOR_TOKEN" "$GH_TOKEN"
assert_secret_clean "operator mode"

# Case 2 — missing review_identity matches operator mode.
reset_logs
printf '%s\n' '{ "tracker": { "kind": "gh" } }' > "$SB/.claude/project-config.defaults.json"
tracker_clear_cache
rc=$(run_review approve)
assert_eq "absent identity → exit 0" "0" "$rc"
assert_eq "absent identity → no openssl call" "0" "$(grep -c . "$SB/openssl.log" || true)"
assert_eq "absent identity → --approve" "1" "$(grep -c -- '--approve' "$SB/gh.log")"
assert_eq "absent identity → operator token" "1" "$(grep -c 'auth:operator' "$SB/gh.log")"
assert_eq "absent identity → GH_TOKEN unchanged" "$MOCK_OPERATOR_TOKEN" "$GH_TOKEN"

# Case 3 — app mode mints a token and scopes GH_TOKEN to the review command.
reset_logs
write_config "github_app" "$SB/secrets/app.pem" ""
tracker_clear_cache
rc=$(run_review approve)
assert_eq "app mode → exit 0" "0" "$rc"
assert_eq "app mode → openssl signed the key path" "1" "$(grep -c -F -e "-sign $SB/secrets/app.pem" "$SB/openssl.log")"
assert_eq "app mode → curl posts the installation token URL" "1" "$(grep -c -F -e "/app/installations/456/access_tokens" "$SB/curl.log")"
assert_eq "app mode → one app-authenticated gh call" "1" "$(grep -c 'auth:app' "$SB/gh.log")"
assert_eq "app mode → review uses --approve" "1" "$(grep -c -- '--approve' "$SB/gh.log")"
assert_eq "app mode → GH_TOKEN unchanged after return" "$MOCK_OPERATOR_TOKEN" "$GH_TOKEN"
# A later gh command must not inherit the installation token.
gh pr view 99 >/dev/null
assert_eq "app mode → later gh uses the operator token" "1" "$(grep -c 'auth:operator' "$SB/gh.log")"
assert_eq "app mode → still exactly one app-authenticated call" "1" "$(grep -c 'auth:app' "$SB/gh.log")"
assert_secret_clean "app mode"

# Hostile curlrc must not expose the JWT or installation token.
reset_logs
mkdir -p "$SB/curl-home"
printf 'verbose\ntrace-ascii = "%s/trace.txt"\n' "$SB/curl-home" > "$SB/curl-home/.curlrc"
export CURL_HOME="$SB/curl-home"
# Existing request logging intentionally records the JWT. Disable it here.
unset CURL_LOG
tracker_clear_cache
rc=$(run_review comment)
assert_eq "hostile curlrc → -q first and review succeeds" "0" "$rc"
assert_no_needle "hostile curlrc → JWT absent from stderr and files" "e30.e30.e30" ""
assert_secret_clean "hostile curlrc"
assert_eq "hostile curlrc → no trace file" "no" "$([ -e "$CURL_HOME/trace.txt" ] && echo yes || echo no)"
unset CURL_HOME

# Config failure warns once and preserves the operator review exit status.
reset_logs
rc=$(
  _tracker_config_get_or() { return 1; }
  run_review comment
)
assert_eq "config read failure → exit 0" "0" "$rc"
assert_eq "config read failure → one fallback warning" "1" "$(grep -c '^reviewer identity: config read failed; fell back to operator$' "$SB/err")"
assert_eq "config read failure → operator token" "1" "$(grep -c 'auth:operator' "$SB/gh.log")"

# Relative paths are refused even when the key exists outside git.
reset_logs
write_config "github_app" "secrets/app.pem" ""
tracker_clear_cache
rc=$(run_review comment)
assert_eq "relative key path → non-zero" "1" "$rc"
assert_contains "relative key path → clear error" "private_key_path must be absolute" "$SB/err"
assert_eq "relative key path → no openssl call" "0" "$(grep -c . "$SB/openssl.log" || true)"
assert_eq "relative key path → no curl call" "0" "$(grep -c . "$SB/curl.log" || true)"
assert_eq "relative key path → no gh call" "0" "$(grep -c . "$SB/gh.log" || true)"

# Case 4 — key inside a git work tree is refused before openssl.
reset_logs
git init -q "$SB/repo"
write_key "$SB/repo/app.pem"
write_config "github_app" "$SB/repo/app.pem" ""
tracker_clear_cache
rc=$(run_review approve)
assert_eq "key inside work tree → non-zero" "1" "$rc"
assert_eq "key inside work tree → error names the work tree" "1" "$(grep -c 'private key path is inside a git work tree' "$SB/err")"
assert_contains "key inside work tree → review was not posted" "review was not posted" "$SB/err"
assert_eq "key inside work tree → no openssl call" "0" "$(grep -c . "$SB/openssl.log" || true)"
assert_eq "key inside work tree → no gh call" "0" "$(grep -c . "$SB/gh.log" || true)"
assert_secret_clean "key inside work tree"

# Case 4b — symlink inside the work tree that points at an outside key.
reset_logs
ln -sf "$SB/secrets/app.pem" "$SB/repo/linked.pem"
printf '%s\n' "$SB/repo/linked.pem" >> "$SB/authorized-key-files"
write_config "github_app" "$SB/repo/linked.pem" ""
tracker_clear_cache
rc=$(run_review approve)
assert_eq "symlink inside work tree → non-zero" "1" "$rc"
assert_eq "symlink inside work tree → refused" "1" "$(grep -c 'inside a git work tree' "$SB/err")"
assert_eq "symlink inside work tree → no openssl call" "0" "$(grep -c . "$SB/openssl.log" || true)"

# Case 4c — outside symlink whose target is inside the work tree.
reset_logs
ln -sf "$SB/repo/app.pem" "$SB/secrets/linked.pem"
printf '%s\n' "$SB/secrets/linked.pem" >> "$SB/authorized-key-files"
write_config "github_app" "$SB/secrets/linked.pem" ""
tracker_clear_cache
rc=$(run_review approve)
assert_eq "symlink into work tree → non-zero" "1" "$rc"
assert_eq "symlink into work tree → refused" "1" "$(grep -c 'inside a git work tree' "$SB/err")"
assert_eq "symlink into work tree → no openssl call" "0" "$(grep -c . "$SB/openssl.log" || true)"

# Case 4d — path refusal still does not approve when comment fallback is set.
reset_logs
write_config "github_app" "$SB/repo/app.pem" "comment"
tracker_clear_cache
rc=$(run_review approve)
assert_eq "work tree plus comment fallback → exit 0" "0" "$rc"
assert_eq "work tree plus comment fallback → no openssl call" "0" "$(grep -c . "$SB/openssl.log" || true)"
assert_eq "work tree plus comment fallback → --comment" "1" "$(grep -c -- '--comment' "$SB/gh.log")"
assert_eq "work tree plus comment fallback → no --approve" "0" "$(grep -c -- '--approve' "$SB/gh.log")"
assert_eq "work tree plus comment fallback → operator token" "1" "$(grep -c 'auth:operator' "$SB/gh.log")"
assert_eq "work tree plus comment fallback → app token not used" "0" "$(grep -c 'auth:app' "$SB/gh.log")"

# Case 5 — a path under .claude/ is refused.
reset_logs
write_key "$SB/.claude/reviewer.pem"
write_config "github_app" "$SB/.claude/reviewer.pem" ""
tracker_clear_cache
rc=$(run_review approve)
assert_eq "key under .claude → non-zero" "1" "$rc"
assert_eq "key under .claude → error names .claude" "1" "$(grep -c 'private key path is under .claude/' "$SB/err")"
assert_eq "key under .claude → no openssl call" "0" "$(grep -c . "$SB/openssl.log" || true)"
assert_eq "key under .claude → no gh call" "0" "$(grep -c . "$SB/gh.log" || true)"
assert_secret_clean "key under .claude"

# Case 6 — mint failure fails closed.
reset_logs
write_config "github_app" "$SB/secrets/app.pem" ""
CURL_RC=22
export CURL_RC
tracker_clear_cache
rc=$(run_review approve)
assert_eq "mint failure → non-zero" "1" "$rc"
assert_eq "mint failure → names the token request" "1" "$(grep -c 'could not mint an installation token' "$SB/err")"
assert_contains "mint failure → review was not posted" "review was not posted" "$SB/err"
assert_eq "mint failure → no gh call" "0" "$(grep -c . "$SB/gh.log" || true)"
assert_eq "mint failure → GH_TOKEN unchanged" "$MOCK_OPERATOR_TOKEN" "$GH_TOKEN"
assert_secret_clean "mint failure"

# Case 6b — a fallback value other than comment also fails closed.
reset_logs
write_config "github_app" "$SB/secrets/app.pem" "approve"
CURL_RC=22
export CURL_RC
tracker_clear_cache
rc=$(run_review approve)
assert_eq "fallback=approve → non-zero" "1" "$rc"
assert_eq "fallback=approve → no gh call" "0" "$(grep -c . "$SB/gh.log" || true)"
assert_eq "fallback=approve → does not approve" "0" "$(grep -c -- '--approve' "$SB/gh.log")"

# Case 7 — mint failure with fallback=comment posts an operator comment.
reset_logs
write_config "github_app" "$SB/secrets/app.pem" "comment"
CURL_RC=22
export CURL_RC
tracker_clear_cache
rc=$(run_review approve)
assert_eq "comment fallback → exit 0" "0" "$rc"
assert_eq "comment fallback → --comment" "1" "$(grep -c -- '--comment' "$SB/gh.log")"
assert_eq "comment fallback → no --approve" "0" "$(grep -c -- '--approve' "$SB/gh.log")"
assert_eq "comment fallback → operator token" "1" "$(grep -c 'auth:operator' "$SB/gh.log")"
assert_eq "comment fallback → app token not used" "0" "$(grep -c 'auth:app' "$SB/gh.log")"
assert_contains "comment fallback → names the downgrade" "posting the review as a comment with the operator login" "$SB/err"
assert_eq "comment fallback → GH_TOKEN unchanged" "$MOCK_OPERATOR_TOKEN" "$GH_TOKEN"
assert_secret_clean "comment fallback"

# Case 7b — the app review command fails, then comment fallback uses the operator.
reset_logs
write_config "github_app" "$SB/secrets/app.pem" "comment"
GH_RC=1
export GH_RC
tracker_clear_cache
rc=$(run_review approve)
assert_eq "app post failure → exit 0 after comment" "0" "$rc"
assert_eq "app post failure → first call used the app token" "1" "$(grep -c 'auth:app' "$SB/gh.log")"
assert_eq "app post failure → fallback used the operator token" "1" "$(grep -c 'auth:operator' "$SB/gh.log")"
assert_eq "app post failure → fallback is --comment" "1" "$(grep -c -- '--comment' "$SB/gh.log")"
assert_eq "app post failure → GH_TOKEN unchanged" "$MOCK_OPERATOR_TOKEN" "$GH_TOKEN"
assert_secret_clean "app post failure"

# Case 8 — a non-numeric app id never reaches openssl or curl.
reset_logs
write_config "github_app" "$SB/secrets/app.pem" "" "12;touch-pwned" "456"
tracker_clear_cache
rc=$(run_review approve)
assert_eq "bad app_id → non-zero" "1" "$rc"
assert_eq "bad app_id → names the id check" "1" "$(grep -c 'app_id or installation_id is missing or not numeric' "$SB/err")"
assert_eq "bad app_id → no openssl call" "0" "$(grep -c . "$SB/openssl.log" || true)"
assert_eq "bad app_id → no curl call" "0" "$(grep -c . "$SB/curl.log" || true)"
assert_eq "bad app_id → no gh call" "0" "$(grep -c . "$SB/gh.log" || true)"
assert_eq "bad app_id → no injected file" "no" "$([ -e "$SB/touch-pwned" ] && echo yes || echo no)"

# Case 9 — tracker_pr_merge never mints or attaches the app token.
reset_logs
write_config "github_app" "$SB/secrets/app.pem" "comment"
tracker_clear_cache
(
  set -x
  tracker_pr_merge "o/r" 42 squash true > "$SB/merge-out"
  echo "rc:$?"
) >"$SB/out" 2>"$SB/err"
rc=$(sed -n 's/^rc://p' "$SB/out" | tail -n 1)
assert_eq "merge → exit 0" "0" "$rc"
assert_eq "merge → pr merge was invoked" "1" "$(grep -c 'cmd:pr merge' "$SB/gh.log")"
assert_eq "merge → no app token" "0" "$(grep -c 'auth:app' "$SB/gh.log")"
assert_eq "merge → operator token" "2" "$(grep -c 'auth:operator' "$SB/gh.log")"
assert_eq "merge → no openssl call" "0" "$(grep -c . "$SB/openssl.log" || true)"
assert_eq "merge → no curl call" "0" "$(grep -c . "$SB/curl.log" || true)"
assert_eq "merge → GH_TOKEN unchanged" "$MOCK_OPERATOR_TOKEN" "$GH_TOKEN"
assert_secret_clean "merge"
if grep -F -q -e "$MOCK_INSTALL_TOKEN" "$SB/merge-out" "$SB/out" "$SB/err" 2>/dev/null; then
  fail "merge output has no app token" "absent" "present"
else
  pass "merge output has no app token"
fi

rm -rf "$SB"

echo "=========================================="
echo "PASS: $PASS  FAIL: $FAIL"
if [ "$FAIL" -gt 0 ]; then printf "Failed:%b\n" "$FAILED"; exit 1; fi
exit 0
