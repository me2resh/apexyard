#!/bin/bash
# test_status_live_writes_nothing.sh — /orbit status prints progress and the
# commits since the snapshot commit, and writes no record (AgDR-0225, ac8-4).

set -u
# shellcheck source=./_lib-fixtures.sh
. "$(dirname "$0")/_lib-fixtures.sh"
fail=0
real_root="$(cd "$(dirname "$0")/../../../.." && pwd)"
script="$real_root/.claude/skills/orbit/lib/status-live.sh"

sb=$(make_sandbox)
repo="$sb/repo"
mkdir -p "$repo" && git -C "$repo" init -q -b main
git -C "$repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "first"
c1=$(git -C "$repo" rev-parse HEAD)
git -C "$repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "second after snapshot"
orbit_root=$(fixtures_write_orbit_root "$repo")
jq --arg c "$c1" '.repositories[0].commit = $c | .repositories[0].branch = "main"' \
  "$orbit_root/snapshots/snapshot-demo-widget-1.json" > "$sb/s.json" && mv "$sb/s.json" "$orbit_root/snapshots/snapshot-demo-widget-1.json"
mkdir -p "$sb/bin"
printf '#!/bin/bash\necho "mock progress for $*"\n' > "$sb/bin/orbit"; chmod +x "$sb/bin/orbit"
ORBIT_BIN="$sb/bin/orbit"; export ORBIT_BIN

before=$(cd "$orbit_root" && find . -type f -exec cksum {} + | sort)
out=$("$script" --orbit-root "$orbit_root" --plan plan-demo-widget 2>&1); rc=$?
after=$(cd "$orbit_root" && find . -type f -exec cksum {} + | sort)

[ "$rc" -eq 0 ] || { echo "FAIL: exit $rc: $out"; fail=1; }
case "$out" in *"mock progress for progress --root"*) ;; *) echo "FAIL: no progress output: $out"; fail=1 ;; esac
case "$out" in *"second after snapshot"*) ;; *) echo "FAIL: missing the commit after the snapshot: $out"; fail=1 ;; esac
case "$out" in *"first"*) echo "FAIL: listed the snapshot commit itself: $out"; fail=1 ;; esac
[ "$before" = "$after" ] || { echo "FAIL: status wrote or changed a record"; fail=1; }

rm -rf "$sb"
[ "$fail" -eq 0 ] && echo "PASS: status shows progress and new commits, writes nothing"
exit "$fail"
