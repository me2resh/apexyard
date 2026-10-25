#!/usr/bin/env bash
# Test path ownership and the manifest check.
set -u
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"
SRC_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
# shellcheck source=bin/_lib-ownership.sh
. "$SRC_ROOT/bin/_lib-ownership.sh"
PASS=0
FAIL=0
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
assert_eq() {
  local label="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then
    echo "PASS [$label]"; PASS=$((PASS + 1))
  else
    echo "FAIL [$label]: want '$want', got '$got'" >&2; FAIL=$((FAIL + 1))
  fi
}
check_class() {
  local path="$1" want="$2" got status=0
  got=$(ownership_class "$path" 2>"$fixture/error") || status=$?
  assert_eq "class $path" "$want" "$got"
  if [ -n "$want" ]; then
    assert_eq "status $path" 0 "$status"
  else
    assert_eq "status $path" 1 "$status"
  fi
}
export OWNERSHIP_MANIFEST="$fixture/manifest"
cat > "$OWNERSHIP_MANIFEST" <<'YAML'
version: 1
paths:
  - glob: narrow/x
    owner: adopter
    security: true
  - glob: narrow/**
    owner: shared
    security: false
  - glob: deep**end
    owner: framework
  - glob: one/*
    owner: framework
  - glob: char/?
    owner: framework
  - glob: a.b
    owner: framework
  - glob: '**/lead'
    owner: framework
  - glob: "mid/**/end"
    owner: framework
  - glob: tail/**
    owner: framework
  - glob: bare # Ignore this comment.
    owner: framework
YAML
check_class narrow/x adopter
check_class narrow/y shared
check_class deep/a/b/end framework
check_class one/x framework
check_class one/x/y ''
check_class char/a framework
check_class char/aa ''
check_class a.b framework
check_class aXb ''
check_class lead framework
check_class a/b/lead framework
check_class mid/end framework
check_class mid/a/b/end framework
check_class tail ''
check_class tail/a framework
check_class ././bare framework
for spec in 'narrow/x:0' 'narrow/y:1' 'bare:1' 'unknown:1'; do
  status=0; ownership_is_security "${spec%:*}" || status=$?
  assert_eq "security $spec" "${spec##*:}" "$status"
done
for path in '' ./ .//absolute /absolute ../x a/../b a/.. ./../x; do
  for fn in ownership_class ownership_is_security; do
    status=0; output=$($fn "$path" 2>"$fixture/error") || status=$?
    assert_eq "$fn rejects $path" 2 "$status"
    assert_eq "$fn has no output for $path" '' "$output"
  done
done
cp "$OWNERSHIP_MANIFEST" "$fixture/valid"
for shape in unknown missing-version wrong-version missing-glob bad-owner missing-owner bad-security missing-paths; do
  case "$shape" in
    unknown) printf 'version: 1\npaths:\n  other: x\n' ;;
    missing-version) printf 'paths:\n' ;;
    wrong-version) printf 'version: 2\npaths:\n' ;;
    missing-glob) printf 'version: 1\npaths:\n  - owner: framework\n' ;;
    bad-owner) printf 'version: 1\npaths:\n  - glob: x\n    owner: other\n' ;;
    missing-owner) printf 'version: 1\npaths:\n  - glob: x\n' ;;
    bad-security) printf 'version: 1\npaths:\n  - glob: x\n    owner: framework\n    security: yes\n' ;;
    missing-paths) printf 'version: 1\n' ;;
  esac > "$OWNERSHIP_MANIFEST"
  for fn in ownership_validate_manifest ownership_class ownership_classify_stream; do
    status=0; output=$(printf 'x\n' | $fn x 2>"$fixture/error") || status=$?
    # The validator takes a file argument.
    if [ "$fn" = ownership_validate_manifest ]; then
      status=0; output=$(ownership_validate_manifest 2>"$fixture/error") || status=$?
    fi
    assert_eq "$shape $fn status" 2 "$status"
    assert_eq "$shape $fn stdout" '' "$output"
    if grep -q 'line [0-9]' "$fixture/error"; then got=yes; else got=no; fi
    assert_eq "$shape $fn line" yes "$got"
  done
done
rm "$OWNERSHIP_MANIFEST"
for fn in ownership_validate_manifest ownership_class ownership_classify_stream; do
  status=0; output=$(printf 'x\n' | $fn 2>"$fixture/error") || status=$?
  # Supply a valid path to test the missing file.
  if [ "$fn" = ownership_class ]; then
    status=0; output=$(ownership_class x 2>"$fixture/error") || status=$?
  fi
  assert_eq "missing file $fn" 2 "$status"
done
for quoted in '"x"' "'x'" 'x # Comment' '"x" # Comment' "'x'  # Comment"; do
  printf 'version: 1\npaths:\n  - glob: %s\n    owner: framework\n' "$quoted" > "$OWNERSHIP_MANIFEST"
  check_class x framework
done
printf 'version: 1\npaths:\n  - glob: "x" junk\n    owner: framework\n' > "$OWNERSHIP_MANIFEST"
status=0; ownership_validate_manifest 2>"$fixture/error" || status=$?
assert_eq 'text after a closing quote' 2 "$status"
printf 'version: 1\npaths:\n  - glob: "**"\n    owner: framework\n' > "$OWNERSHIP_MANIFEST"
check_class a/b/c framework
awk 'BEGIN { for (i=1;i<=2000;i++) print "path/" i }' > "$fixture/paths"
count=$(ownership_classify_stream < "$fixture/paths" | awk 'END { print NR }')
assert_eq '2000 paths' 2000 "$count"
cp "$fixture/valid" "$OWNERSHIP_MANIFEST"
printf 'bare\nnarrow/x\nnarrow/y\n' > "$fixture/paths"
status=0; output=$(bash "$SRC_ROOT/bin/check-ownership-manifest.sh" --paths "$fixture/paths") || status=$?
assert_eq 'checker success' 0 "$status"
assert_eq 'checker counts' 'ownership manifest: 3 paths classified (framework 1, adopter 1, shared 1)' "$output"
printf 'unknown\n' >> "$fixture/paths"
status=0; bash "$SRC_ROOT/bin/check-ownership-manifest.sh" --paths "$fixture/paths" >"$fixture/out" 2>"$fixture/error" || status=$?
assert_eq 'checker unmatched' 1 "$status"
assert_eq 'checker names path' 'unmatched: unknown' "$(sed -n '1p' "$fixture/error")"
printf 'version: 2\n' > "$OWNERSHIP_MANIFEST"
status=0; bash "$SRC_ROOT/bin/check-ownership-manifest.sh" --paths "$fixture/paths" >"$fixture/out" 2>"$fixture/error" || status=$?
assert_eq 'checker invalid' 2 "$status"
OWNERSHIP_MANIFEST="$SRC_ROOT/.claude/ownership-manifest.yaml"
for path in apexyard.projects.yaml onboarding.yaml projects/acme/README.md custom-handbooks/general/x.md custom-skills/foo/SKILL.md .claude/project-config.json .claude/settings.local.json; do
  check_class "$path" adopter
done
for path in projects/README.md .claude/skills/update/SKILL.md .claude/rules/git-conventions.md .claude/agents/code-reviewer.md .claude/hooks/tests/test_x.sh .claude/hooks/block-unreviewed-merge.sh .githooks/pre-push; do
  check_class "$path" framework
done
check_class handbooks/general/x.md shared
check_class .claude/settings.json shared
for spec in '.claude/hooks/tests/test_x.sh:1' '.claude/hooks/block-unreviewed-merge.sh:0' '.githooks/pre-push:0' '.claude/settings.json:0'; do
  status=0; ownership_is_security "${spec%:*}" || status=$?
  assert_eq "real security $spec" "${spec##*:}" "$status"
done
if git -C "$SRC_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  status=0; bash "$SRC_ROOT/bin/check-ownership-manifest.sh" || status=$?
  assert_eq 'real repo' 0 "$status"
else
  echo 'NOTE: real-repo check needs a git work tree'
  assert_eq 'real repo needs git' 0 0
fi
echo '===== test_ownership_manifest.sh ====='
echo "Passed: $PASS"
echo "Failed: $FAIL"
[ "$FAIL" -eq 0 ]
