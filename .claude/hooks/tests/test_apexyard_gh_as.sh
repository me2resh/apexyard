#!/bin/bash
# Check the wrapper and the self-test without a real gh call.
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT
fail=0
count=0
check() {
  count=$((count + 1))
  if "$@"; then echo "PASS $count"; else echo "FAIL $count"; fail=1; fi
}
mkdir "$tmp/bin"
cat > "$tmp/bin/gh" <<'FAKE'
#!/bin/bash
if [ "$1" = auth ] && [ "$2" = token ]; then
  [ "$4" != missing ] || { echo "$FAKE_TOKEN" >&2; exit 1; }
  [ "$4" != empty ] || exit 0
  printf '%s\n' "$FAKE_TOKEN"
else
  # Like the real gh: these arguments make it print GH_TOKEN.
  for arg in "$@"; do
    case "$arg" in auth|-t|--show-token*|--jq|--jq=*|-q) printf '%s\n' "$GH_TOKEN" ;; esac
  done
  # Like the real gh: an inherited pager or browser command runs with GH_TOKEN.
  for hook in "${GH_PAGER:-}" "${PAGER:-}" "${GH_BROWSER:-}" "${BROWSER:-}"; do
    [ -z "$hook" ] || [ "$hook" = cat ] || [ "$hook" = true ] || printf '%s\n' "$GH_TOKEN"
  done
  printf '%s|%s|%s|%s\n' "${GH_PAGER:-}" "${GH_BROWSER:-}" "${GH_EDITOR:-}" "${PAGER:-}${BROWSER:-}${EDITOR:-}${VISUAL:-}${GH_FORCE_TTY:-}" > "$RECORD.hooks"
  printf '%s' "$GH_TOKEN" > "$RECORD.env"
  printf '%s\n' "$@" > "$RECORD.args"
  exit "${FAKE_STATUS:-0}"
fi
FAKE
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH" RECORD="$tmp/record"
FAKE_TOKEN=$(printf 'fake%s' 7392851064)
export FAKE_TOKEN
"$ROOT/bin/apexyard-gh-as" owner api 'two words' '*' > "$tmp/out" 2>&1
check test "$?" -eq 0
check test "$(cat "$RECORD.env")" = "$FAKE_TOKEN"
printf '%s\n' api 'two words' '*' > "$tmp/expected"
check cmp -s "$tmp/expected" "$RECORD.args"
check test ! -s "$tmp/out"
for user in missing empty; do
  "$ROOT/bin/apexyard-gh-as" "$user" api > "$tmp/out" 2>&1
  check test "$?" -eq 2
  check grep -q 'no login' "$tmp/out"
  if grep -Fq "$FAKE_TOKEN" "$tmp/out"; then check false; else check true; fi
done
"$ROOT/bin/apexyard-gh-as" owner > "$tmp/out" 2>&1
check test "$?" -eq 2
# Commands that make gh print GH_TOKEN are refused before any token read.
# shellcheck disable=SC2016 # $ENV is jq syntax, passed literally.
for refused in 'auth token' 'auth status --show-token' 'api user --show-token' 'auth status --show-token=true' \
  '--hostname github.com auth token' '--hostname=github.com auth token' 'pr list auth' 'api user -t' \
  'config get oauth_token' 'extension exec x' 'alias set x !env' \
  'api user --jq $ENV.GH_TOKEN' 'api user --jq=env.GH_TOKEN' 'pr list --json url -q env.GH_TOKEN'; do
  rm -f "$RECORD.env"
  # shellcheck disable=SC2086
  "$ROOT/bin/apexyard-gh-as" owner $refused > "$tmp/out" 2>&1
  check test "$?" -eq 2
  check test ! -e "$RECORD.env"
  if grep -Fq "$FAKE_TOKEN" "$tmp/out"; then check false; else check true; fi
done
# An inherited pager, browser or editor must not reach gh.
GH_FORCE_TTY=1 GH_PAGER='printenv GH_TOKEN' PAGER='printenv GH_TOKEN' BROWSER=x EDITOR=x VISUAL=x \
  "$ROOT/bin/apexyard-gh-as" owner api user > "$tmp/out" 2>&1
check test "$?" -eq 0
if grep -Fq "$FAKE_TOKEN" "$tmp/out"; then check false; else check true; fi
check test "$(cat "$RECORD.hooks")" = 'cat|true|true|'
FAKE_STATUS=7 "$ROOT/bin/apexyard-gh-as" owner api > "$tmp/out" 2>&1
check test "$?" -eq 7
bash "$ROOT/bin/secrets-selftest.sh" > "$tmp/selftest" 2>&1
check test "$?" -eq 0
check grep -Fxq 'PASS secret scan hides the value' "$tmp/selftest"
check test "$(grep -c '^PASS ' "$tmp/selftest")" -eq 13
check grep -Fxq 'Cockpit run environment: checked in apexyard-premium, not here.' "$tmp/selftest"
# Use a copy to verify a missing rule and a leaking wrapper each fail.
mkdir -p "$tmp/tree/bin" "$tmp/tree/.claude/hooks"
cp "$ROOT/bin/secrets-selftest.sh" "$tmp/tree/bin/"
cp "$ROOT/bin/apexyard-gh-as" "$tmp/tree/bin/"
cp "$ROOT/.claude/hooks/"*.sh "$tmp/tree/.claude/hooks/"
jq 'del(.permissions.deny[0])' "$ROOT/.claude/settings.json" > "$tmp/tree/.claude/settings.json"
bash "$tmp/tree/bin/secrets-selftest.sh" > "$tmp/selftest" 2>&1
check test "$?" -eq 1
check grep -Fq 'FAIL deny Read(//**/.env)' "$tmp/selftest"
cp "$ROOT/.claude/settings.json" "$tmp/tree/.claude/settings.json"
# shellcheck disable=SC2016
printf '#!/bin/bash\ngh auth token --user "$1"\n' > "$tmp/tree/bin/apexyard-gh-as"
bash "$tmp/tree/bin/secrets-selftest.sh" > "$tmp/selftest" 2>&1
check test "$?" -eq 1
check grep -Fq 'FAIL wrapper keeps its token private' "$tmp/selftest"
# A safe scanner fixture proves the self-test can also pass all checks.
cp "$ROOT/bin/apexyard-gh-as" "$tmp/tree/bin/apexyard-gh-as"
printf '#!/bin/bash\necho "hardcoded secrets" >&2\nexit 2\n' > "$tmp/tree/.claude/hooks/check-secrets.sh"
bash "$tmp/tree/bin/secrets-selftest.sh" > "$tmp/selftest" 2>&1
check test "$?" -eq 0
check test "$(grep -c '^PASS ' "$tmp/selftest")" -eq 13
echo "Tests: $count; failures: $fail"
exit "$fail"
