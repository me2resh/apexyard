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

# Nonzero bytes avoid sparse files and zero-block filesystem optimizations.
write_fixture() {
  LC_ALL=C tr '\0' 'x' < /dev/zero | head -c "$2" > "$1"
}

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
  # Size assertions need complete measurements, including on slower CI runners.
  APEXYARD_DISK_TIMEBOX=60 APEXYARD_OPS_ROOT="$1" APEXYARD_GH="$2" TMPDIR="$1/tmp" APEXYARD_REVIEW_COPY_ROOT="$1/copies" bash "$HELPER" "${@:3}"
}

# --- 1. empty sandbox: 0 KB used, 0 KB reclaimable, one line.
sb=$(mk_sandbox); mkdir -p "$sb/tmp"; gh=$(mk_gh MERGED)
out=$(run_helper "$sb" "$gh")
case "$out" in
  "ApexYard is using "*"; 0 KB can be reclaimed") ok empty-sandbox ;;
  *) bad empty-sandbox "$out" ;;
esac
[ "$(printf '%s\n' "$out" | grep -c '^')" = 1 ] && ok one-line || bad one-line "$out"

# An unreadable entry makes du fail but preserves the sizes it can measure.
mkdir "$sb/.claude/session/unreadable"
write_fixture "$sb/.claude/session/readable" 2097152
chmod 000 "$sb/.claude/session/unreadable"
if du -sk "$sb/.claude/session" >/dev/null 2>&1; then
  bad unreadable-fixture "du must fail on the unreadable entry"
fi
out=$(run_helper "$sb" "$gh")
chmod 700 "$sb/.claude/session/unreadable"
case "$out" in
  *"timed out"*) bad unreadable-total "$out" ;;
  'ApexYard is using 2 MB;'*) ok unreadable-total ;;
  *) bad unreadable-total "$out" ;;
esac
rm -rf "$sb/.claude/session/unreadable" "$sb/.claude/session/readable"

# --- 2. an old, clean, pushed worktree with a merged PR is reclaimable.
remote="$sb/remote.git"; git init -q --bare "$remote"
git -C "$sb" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$sb" remote add origin "$remote"
git -C "$sb" push -q origin HEAD:refs/heads/base 2>/dev/null
mkdir -p "$sb/workspace/proj.worktrees"
git -C "$sb" worktree add -q -b feature/old "$sb/workspace/proj.worktrees/old" 2>/dev/null
git -C "$sb/workspace/proj.worktrees/old" push -q -u origin feature/old 2>/dev/null
write_fixture "$sb/workspace/proj.worktrees/old/blob" 3145728
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

# --- 4b. an untracked file keeps the worktree.
echo new > "$sb/workspace/proj.worktrees/old/untracked.txt"
touch -t 202001010000 "$sb/workspace/proj.worktrees/old"
out=$(run_helper "$sb" "$gh")
case "$out" in
  *"; 0 KB can be reclaimed") ok untracked-kept ;;
  *) bad untracked-kept "$out" ;;
esac
rm -f "$sb/workspace/proj.worktrees/old/untracked.txt"
touch -t 202001010000 "$sb/workspace/proj.worktrees/old"

# --- 5. gh missing: the check is blocked, so the figure is a lower bound.
out=$(APEXYARD_DISK_TIMEBOX=60 APEXYARD_OPS_ROOT="$sb" APEXYARD_GH="/nonexistent/gh" TMPDIR="$sb/tmp" APEXYARD_REVIEW_COPY_ROOT="$sb/copies" bash "$HELPER")
case "$out" in
  *"; at least "*" can be reclaimed") ok gh-missing-lower-bound ;;
  *) bad gh-missing-lower-bound "$out" ;;
esac

json=$(run_helper "$sb" /nonexistent/gh --json)
if jq -e '.schema == "apexyard.disk-usage/1" and .reclaimable_is_lower_bound == true and .timed_out == false and (.used_bytes | type == "number") and (.reclaimable_bytes | type == "number") and .max_owned_bytes == 10737418240' <<< "$json" >/dev/null; then
  ok json-lower-bound-fields
else bad json-lower-bound-fields "$json"; fi

# --- 5b. a review copy older than the age limit with a merged PR is reclaimable.
copy="$sb/copies/o__r-pr7"
git init -q "$copy"
write_fixture "$copy/blob" 2097152
git -C "$copy" add blob
git -C "$copy" -c user.email=t@t -c user.name=t commit -qm blob
sha=$(git -C "$copy" rev-parse HEAD)
record() {
  jq -n --arg repo "$1" --arg sha "$sha" --arg path "$copy" \
    '{repo:$repo,pr:7,head_sha:$sha,session:"test",created_at:"2020-01-01T00:00:00Z",path:$path}' > "$copy/.git/apexyard-review-copy.json"
}
record o/r
rm -rf "$sb/workspace/proj.worktrees/old"
git -C "$sb" worktree prune
# Assert both the record repo and PR reach gh unchanged.
cat > "$gh" <<'SHIM'
#!/bin/bash
case "$*" in
  'pr view 7 --repo o/r --json state,headRefOid --jq '*) echo 'MERGED|' ;;
  *) exit 1 ;;
esac
SHIM
expect_copy() {
  local label=$1 expected=$2 result
  result=$(run_helper "$sb" "$gh")
  case "$result" in
    *"; $expected can be reclaimed") ok "$label" ;;
    *) bad "$label" "$result" ;;
  esac
}
# Allow allocation and display rounding, while distinguishing one, two, or three copies.
expect_copy_size() {
  local label=$1 min_kb=$2 max_kb=$3 result
  result=$(run_helper "$sb" "$gh")
  if printf '%s\n' "$result" | awk -F '; ' -v min="$min_kb" -v max="$max_kb" '
    NF == 2 && $2 ~ /^[0-9]+([.][0-9]+)? (KB|MB|GB) can be reclaimed$/ {
      split($2, size, " ")
      kb = size[1] * (size[2] == "GB" ? 1048576 : size[2] == "MB" ? 1024 : 1)
      if (kb >= min && kb <= max) valid = 1
    }
    END { exit !valid }
  '; then
    ok "$label"
  else
    bad "$label" "expected ${min_kb}-${max_kb} KB reclaimable: $result"
  fi
}
expect_copy_size review-copy-reclaimable 1536 3072
record r
expect_copy ownerless-record-kept '0 KB'
record o/r
out=$(run_helper "$sb" "$ghopen")
case "$out" in *'; 0 KB can be reclaimed') ok review-copy-open-kept ;; *) bad review-copy-open-kept "$out" ;; esac

echo changed >> "$copy/blob"
expect_copy dirty-copy-kept '0 KB'
git -C "$copy" checkout -q -- blob
echo new > "$copy/untracked"
expect_copy untracked-copy-kept '0 KB'
rm "$copy/untracked"
echo stash >> "$copy/blob"
git -C "$copy" -c user.email=t@t -c user.name=t stash -q
expect_copy stashed-copy-kept '0 KB'
git -C "$copy" stash drop -q
git -C "$copy" -c user.email=t@t -c user.name=t commit -q --allow-empty -m local
expect_copy unpushed-copy-kept '0 KB'
git -C "$copy" branch saved-local
git -C "$copy" reset -q --hard "$sha"
git -C "$copy" checkout -q --detach "$sha"
expect_copy unpushed-other-branch-kept '0 KB'
git -C "$copy" branch -D saved-local >/dev/null
git -C "$copy" worktree add -q --detach "$sb/extra-wt" "$sha"
expect_copy extra-worktree-kept '0 KB'
git -C "$copy" worktree remove "$sb/extra-wt"
expect_copy_size clean-copy-reclaimable 1536 3072

# Configured roots add to the step-3 root and physical duplicates count once.
mkdir -p "$sb/additional"
cp -R "$copy" "$sb/additional/o__r-pr7"
printf '{"disk_budget":{"review_copy_roots":["additional","copies"]}}\n' > "$sb/.claude/project-config.json"
expect_copy_size additive-deduplicated-roots 3584 5120
# Leading ~/ resolves against HOME.
printf '{"disk_budget":{"review_copy_roots":["~/additional"]}}\n' > "$sb/.claude/project-config.json"
old_home=$HOME
export HOME="$sb"
expect_copy_size home-root 3584 5120
export HOME="$old_home"
rm "$sb/.claude/project-config.json"

# Unsafe roots are excluded from measurement as well as reclaimability.
check_unsafe_root() {
  local label=$1 result
  result=$(run_helper "$sb" "$gh")
  case "$result" in
    'ApexYard is using '*'; 0 KB can be reclaimed')
      case "$result" in *' MB;'*|*' GB;'*) bad "$label" "$result" ;; *) ok "$label" ;; esac ;;
    *) bad "$label" "$result" ;;
  esac
}
mv "$sb/copies" "$sb/real-copies"
ln -s "$sb/real-copies" "$sb/copies"
check_unsafe_root symlink-root-excluded
rm "$sb/copies"
mv "$sb/real-copies" "$sb/copies"
for mode in 770 707; do
  chmod "$mode" "$sb/copies"
  check_unsafe_root "writable-root-$mode-excluded"
done
chmod 700 "$sb/copies"
# Simulate foreign ownership without requiring chown privileges.
mkdir "$sb/shims"
real_stat=$(command -v stat)
cat > "$sb/shims/stat" <<SHIM
#!/bin/bash
case "\$*" in *"$sb/copies"*) echo '999999 700' ;; *) exec "$real_stat" "\$@" ;; esac
SHIM
chmod +x "$sb/shims/stat"
old_path=$PATH
export PATH="$sb/shims:$PATH"
check_unsafe_root foreign-owned-root-excluded
export PATH="$old_path"
expect_copy_size safe-root-restored 1536 3072
mkdir -p "$sb/workspace/proj.worktrees/old"

# --- 6. budget from config: a 0 GB budget marks the line over budget.
printf '{"disk_budget":{"max_owned_gb":0}}\n' > "$sb/.claude/project-config.json"
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
out=$(APEXYARD_DISK_TIMEBOX=0 APEXYARD_OPS_ROOT="$sb" APEXYARD_GH="$gh" TMPDIR="$sb/tmp" bash "$HELPER")
[ $((SECONDS - start)) -le 5 ] && ok timebox || bad timebox "took $((SECONDS - start))s"
case "$out" in
  'ApexYard disk use is unknown (measurement timed out)') ok timeout-message ;;
  *) bad timeout-message "$out" ;;
esac

json=$(APEXYARD_DISK_TIMEBOX=0 APEXYARD_OPS_ROOT="$sb" bash "$HELPER" --json)
if jq -e '.timed_out == true and .used_bytes == null and .reclaimable_bytes == null and .reclaimable_is_lower_bound == false' <<< "$json" >/dev/null; then
  ok json-timeout
else bad json-timeout "$json"; fi
json=$(APEXYARD_OPS_ROOT="$sb/missing" bash "$HELPER" --json)
if jq -e '.used_bytes == null and .reclaimable_bytes == null and .timed_out == false' <<< "$json" >/dev/null; then
  ok json-no-root
else bad json-no-root "$json"; fi
json=$(run_helper "$sb" "$gh" --json)
if jq -e '.reclaimable_is_lower_bound == false and .timed_out == false and (.used_bytes | floor == .)' <<< "$json" >/dev/null; then
  ok json-complete
else bad json-complete "$json"; fi

# --- 9. the briefing stays at 4 lines and has no disk line.
mkdir -p "$sb/.claude/skills/status"
cp "$BRIEF" "$HELPER" "$sb/.claude/skills/status/"
out=$(APEXYARD_OPS_ROOT="$sb" APEXYARD_CWD="$sb" APEXYARD_GH="" TMPDIR="$sb/tmp" bash "$sb/.claude/skills/status/briefing.sh")
if [ "$(printf '%s\n' "$out" | grep -c '^')" = 4 ] && ! printf '%s' "$out" | grep -q "ApexYard is using"; then
  ok briefing-unchanged
else
  bad briefing-unchanged "$out"
fi

rm -rf "$sb" "$gh" "$ghopen"
echo "Total: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
