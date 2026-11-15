#!/bin/bash
# Tests for .claude/skills/status/disk-usage.sh and its line in briefing.sh
# (me2resh/apexyard#2070, step 5). All cases run in a temp sandbox with a gh shim.

set -u
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HELPER="$SRC_ROOT/.claude/skills/status/disk-usage.sh"
BRIEF="$SRC_ROOT/.claude/skills/status/briefing.sh"
PASS=0; FAIL=0

ok() { echo "PASS [$1]"; PASS=$((PASS+1)); }
bad() { echo "FAIL [$1]: $2" >&2; FAIL=$((FAIL+1)); }

mk_sandbox() {
  local sb
  sb=$(mktemp -d); sb=$(cd "$sb" && pwd -P)
  mkdir -p "$sb/.claude/hooks" "$sb/.claude/session" "$sb/workspace"
  for lib in _lib-read-config.sh _lib-portfolio-paths.sh; do
    [ -f "$SRC_ROOT/.claude/hooks/$lib" ] && cp "$SRC_ROOT/.claude/hooks/$lib" "$sb/.claude/hooks/$lib"
  done
  cp "$SRC_ROOT/.claude/project-config.defaults.json" "$sb/.claude/project-config.defaults.json"
  : > "$sb/onboarding.yaml"; : > "$sb/apexyard.projects.yaml"
  git init -q "$sb"
  echo "$sb"
}

mk_gh() { # $1 = PR state the shim prints
  local f; f=$(mktemp); cat > "$f" <<SHIM
#!/bin/bash
echo "$1"
SHIM
  chmod +x "$f"; echo "$f"
}

run_helper() { # $1 sandbox, $2 gh
  APEXYARD_OPS_ROOT="$1" APEXYARD_GH="$2" TMPDIR="$1/tmp" bash "$HELPER"
}

# --- 1. empty sandbox: 0 KB used, 0 KB reclaimable, one line.
sb=$(mk_sandbox); mkdir -p "$sb/tmp"; gh=$(mk_gh MERGED)
out=$(run_helper "$sb" "$gh")
case "$out" in
  "ApexYard is using "*"; 0 KB can be reclaimed") ok empty-sandbox ;;
  *) bad empty-sandbox "$out" ;;
esac
[ "$(printf '%s\n' "$out" | grep -c '^')" = 1 ] && ok one-line || bad one-line "$out"

# --- 2. an old, clean, pushed worktree with a merged PR is reclaimable.
remote="$sb/remote.git"; git init -q --bare "$remote"
git -C "$sb" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$sb" remote add origin "$remote"
git -C "$sb" push -q origin HEAD:refs/heads/base 2>/dev/null
mkdir -p "$sb/workspace/proj.worktrees"
git -C "$sb" worktree add -q -b feature/old "$sb/workspace/proj.worktrees/old" 2>/dev/null
git -C "$sb/workspace/proj.worktrees/old" push -q -u origin feature/old 2>/dev/null
dd if=/dev/zero of="$sb/workspace/proj.worktrees/old/blob" bs=1024 count=3072 2>/dev/null
git -C "$sb/workspace/proj.worktrees/old" add blob
git -C "$sb/workspace/proj.worktrees/old" -c user.email=t@t -c user.name=t commit -q -m blob
git -C "$sb/workspace/proj.worktrees/old" push -q 2>/dev/null
touch -t 202001010000 "$sb/workspace/proj.worktrees/old"
out=$(run_helper "$sb" "$gh")
case "$out" in
  *"; "*" MB can be reclaimed"|*"; "*" GB can be reclaimed") ok merged-old-reclaimable ;;
  *) bad merged-old-reclaimable "$out" ;;
esac

# --- 3. an open PR is not reclaimable.
ghopen=$(mk_gh OPEN)
out=$(run_helper "$sb" "$ghopen")
case "$out" in
  *"; 0 KB can be reclaimed") ok open-pr-kept ;;
  *) bad open-pr-kept "$out" ;;
esac

# --- 4. uncommitted work is never reclaimable.
echo change >> "$sb/workspace/proj.worktrees/old/blob"
out=$(run_helper "$sb" "$gh")
case "$out" in
  *"; 0 KB can be reclaimed") ok dirty-kept ;;
  *) bad dirty-kept "$out" ;;
esac
git -C "$sb/workspace/proj.worktrees/old" checkout -q -- blob
touch -t 202001010000 "$sb/workspace/proj.worktrees/old"

# --- 5. gh missing: the size is unknown, not a guess.
out=$(APEXYARD_OPS_ROOT="$sb" APEXYARD_GH="/nonexistent/gh" TMPDIR="$sb/tmp" bash "$HELPER")
case "$out" in
  *"; reclaimable size unknown") ok gh-missing-unknown ;;
  *) bad gh-missing-unknown "$out" ;;
esac

# --- 6. budget from config: a 0 GB budget marks the line over budget.
printf '{"disk_budget":{"max_gb":0}}\n' > "$sb/.claude/project-config.json"
out=$(run_helper "$sb" "$gh")
case "$out" in
  *"(over the 0 GB budget)") ok config-budget ;;
  *) bad config-budget "$out" ;;
esac
rm -f "$sb/.claude/project-config.json"

# --- 7. nothing is removed by a run.
[ -d "$sb/workspace/proj.worktrees/old" ] && ok read-only || bad read-only "worktree gone"

# --- 8. a zero time box ends fast and never blocks.
start=$SECONDS
APEXYARD_DISK_TIMEBOX=0 APEXYARD_OPS_ROOT="$sb" APEXYARD_GH="$gh" TMPDIR="$sb/tmp" bash "$HELPER" >/dev/null
[ $((SECONDS - start)) -le 5 ] && ok timebox || bad timebox "took $((SECONDS - start))s"

# --- 9. briefing gains the line when the helper is next to it.
mkdir -p "$sb/.claude/skills/status"
cp "$BRIEF" "$HELPER" "$sb/.claude/skills/status/"
out=$(APEXYARD_OPS_ROOT="$sb" APEXYARD_CWD="$sb" APEXYARD_GH="" TMPDIR="$sb/tmp" bash "$sb/.claude/skills/status/briefing.sh")
last=$(printf '%s\n' "$out" | tail -1)
case "$last" in
  "ApexYard is using "*) ok briefing-line ;;
  *) bad briefing-line "$out" ;;
esac

rm -rf "$sb" "$gh" "$ghopen"
echo "Total: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
