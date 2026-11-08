#!/bin/bash
# Check token precautions for the 13 Nov bypass self-test.
set +x
ROOT=$(cd "$(dirname "$0")/.." && pwd)
fail=0
result() {
  if [ "$1" -eq 0 ]; then printf 'PASS %s\n' "$2"; else printf 'FAIL %s\n' "$2"; fail=1; fi
}
for rule in 'Read(//**/.env)' 'Read(//**/.env.*)' \
  'Bash(gh auth token)' 'Bash(gh auth token:*)' 'Bash(printenv)' \
  'Bash(printenv:*)' 'Bash(env)' 'Read(//**/*.private-key.pem)' \
  'Read(//**/.config/apexyard/reviewer.pem)' 'Read(//**/.mcp.json)'; do
  jq -e --arg rule "$rule" '.permissions.deny | index($rule) != null' "$ROOT/.claude/settings.json" >/dev/null 2>&1
  result "$?" "deny $rule"
done
jq -e '.permissions.deny | index("Bash(env:*)") == null' "$ROOT/.claude/settings.json" >/dev/null 2>&1
result "$?" 'env arguments stay allowed'
tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/repo" "$tmp/bin"
git -C "$tmp/repo" init -q
key_name=$(printf 'api_%s' key)
# The value shares no 4-character piece with the file name or the message.
secret=$(printf 'qzx%s%s' 927461 830572)
printf '%s = "%s"\n' "$key_name" "$secret" > "$tmp/repo/sample.cfg"
git -C "$tmp/repo" add sample.cfg
payload=$(jq -nc --arg cwd "$tmp/repo" '{cwd:$cwd,tool_input:{command:"git commit -m probe"}}')
printf '%s' "$payload" | bash "$ROOT/.claude/hooks/check-secrets.sh" > "$tmp/scan" 2>&1
rc=$?
scan_ok=0
[ "$rc" -eq 2 ] && grep -q 'hardcoded secrets' "$tmp/scan" || scan_ok=1
# Check each four-character fragment, including either end of the value.
i=0
while [ "$i" -le "$((${#secret} - 4))" ]; do
  grep -Fq "${secret:$i:4}" "$tmp/scan" && scan_ok=1
  i=$((i + 1))
done
result "$scan_ok" 'secret scan hides the value'
cat > "$tmp/bin/gh" <<'FAKE'
#!/bin/bash
if [ "$1" = auth ] && [ "$2" = token ]; then
  printf '%s\n' "$SELFTEST_TOKEN"
else
  printf '%s' "$GH_TOKEN" > "$SELFTEST_RECORD"
fi
FAKE
chmod +x "$tmp/bin/gh"
export SELFTEST_TOKEN="$secret" SELFTEST_RECORD="$tmp/record"
wrapper_ok=0
if [ -x "$ROOT/bin/apexyard-gh-as" ]; then
  PATH="$tmp/bin:$PATH" "$ROOT/bin/apexyard-gh-as" probe api user > "$tmp/wrapper" 2>&1 || wrapper_ok=1
  [ -f "$tmp/record" ] && [ "$(cat "$tmp/record")" = "$secret" ] || wrapper_ok=1
  grep -Fq "$secret" "$tmp/wrapper" && wrapper_ok=1
else
  wrapper_ok=1
fi
result "$wrapper_ok" 'wrapper keeps its token private'
echo 'Cockpit run environment: checked in apexyard-premium, not here.'
exit "$fail"
