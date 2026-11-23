#!/usr/bin/env bash
# Offline GitHub API fixture tests.
set -euo pipefail
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"
root=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export FIXTURES="$root/.claude/hooks/tests/fixtures/install-counts"
mkdir "$work/bin"
cat > "$work/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -eu
[ "${FAIL_API:-}" != true ] || exit 1
case "$*" in
  *traffic/clones*) [ "${GH_TOKEN:-}" = fixture-token ]; cat "$FIXTURES/clones.json" ;;
  *releases*) [ "${GH_TOKEN:-}" = repo-token ]; cat "$FIXTURES/releases.json" ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$work/bin/gh"
export PATH="$work/bin:$PATH" GH_TOKEN=repo-token
TAP_TRAFFIC_TOKEN=fixture-token bash "$root/bin/install-counts-collect.sh" > "$work/snapshots"
jq -e '.releases | length == 2' "$work/snapshots" >/dev/null
jq -e '.releases[0].asset.download_count == 42 and .releases[1].asset == null and .tap.uniques == 8' "$work/snapshots" >/dev/null
echo 'ok: pagination, matching asset, missing asset, draft exclusion, token isolation'
# The next observation repeats an API week with updated counters.
jq -c '.collected_at = "2099-11-23T00:00:00Z" | .releases[0].asset.download_count = 50 | .tap.clones[1].count = 9' "$work/snapshots" >> "$work/later"
cat "$work/later" >> "$work/snapshots"
bash "$root/bin/install-counts-report.sh" "$work/snapshots" > "$work/report"
grep -Fxq $'v5.10.0\t50\t101' "$work/report"
grep -Fxq $'v5.9.0\tunavailable\tunavailable' "$work/report"
grep -Fxq $'2026-11-09T00:00:00Z\t5\t3' "$work/report"
grep -Fxq $'2026-11-16T00:00:00Z\t9\t5' "$work/report"
[ "$(grep -c '^2026-11-16' "$work/report")" -eq 1 ]
echo 'ok: latest cumulative downloads and weekly clones without duplicate weeks'
TAP_TRAFFIC_TOKEN='' bash "$root/bin/install-counts-collect.sh" > "$work/skipped" 2> "$work/notice"
jq -e '.tap == null' "$work/skipped" >/dev/null
grep -q '^::notice::' "$work/notice"
bash "$root/bin/install-counts-report.sh" "$work/skipped" | grep -q 'Tap traffic unavailable'
echo 'ok: absent tap token records unavailable traffic and emits notice'
if FAIL_API=true bash "$root/bin/install-counts-collect.sh" > "$work/failed" 2>/dev/null; then
  echo 'FAIL: API failure accepted' >&2
  exit 1
fi
[ ! -s "$work/failed" ]
echo 'ok: API failure produces no partial snapshot'
: > "$work/empty.jsonl"
bash "$root/bin/install-counts-report.sh" "$work/empty.jsonl" >/dev/null
printf 'invalid json\n' > "$work/invalid"
if bash "$root/bin/install-counts-report.sh" "$work/invalid" >/dev/null 2>&1; then
  echo 'FAIL: malformed data accepted' >&2
  exit 1
fi
if bash "$root/bin/install-counts-report.sh" >/dev/null 2>&1; then
  echo 'FAIL: missing argument accepted' >&2
  exit 1
fi
echo 'ok: empty history, malformed data, and usage'
