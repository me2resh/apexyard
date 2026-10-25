#!/usr/bin/env bash
# Test file updates with unrelated repository histories.
set -u
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"
SRC_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
engine="$SRC_ROOT/bin/update-files.sh"
PASS=0 FAIL=0
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
fw="$fixture/fw" ops="$fixture/ops"
assert_eq() {
  if [ "$2" = "$3" ]; then echo "PASS [$1]"; PASS=$((PASS + 1))
  else echo "FAIL [$1]: want '$2', got '$3'" >&2; FAIL=$((FAIL + 1)); fi
}
has() {
  local result=no
  grep -F -- "$2" "$fixture/out" >/dev/null && result=yes
  assert_eq "$1" yes "$result"
}
commit_fixture() {
  git -C "$1" add .
  git -C "$1" -c user.name=t -c user.email=t@t commit -qm fixture
}
mkdir -p "$fw/.claude/skills/foo" "$fw/.claude/hooks" "$fw/handbooks" "$fw/docs"
git -C "$fw" init -q
cat > "$fw/.claude/ownership-manifest.yaml" <<'YAML'
version: 1
paths:
  - glob: apexyard.projects.yaml
    owner: adopter
  - glob: .claude/framework-version
    owner: adopter
  - glob: .claude/hooks/**
    owner: framework
    security: true
  - glob: .claude/skills/**
    owner: framework
  - glob: handbooks/**
    owner: shared
  - glob: docs/**
    owner: framework
  - glob: .claude/agents/**
    owner: framework
YAML
printf 'base\n' > "$fw/apexyard.projects.yaml"
printf 'v1.0.0\n' > "$fw/.claude/framework-version"
# Separate regions permit a clean three-way merge.
for path in .claude/skills/foo/SKILL.md .claude/hooks/gate.sh .claude/hooks/static.sh handbooks/shared.md; do
  printf 'first\n2\n3\n4\n5\n6\n7\n8\nlast\n' > "$fw/$path"
done
printf 'old\n' > "$fw/docs/clean"
printf 'delete\n' > "$fw/docs/delete"
printf 'delete\n' > "$fw/docs/edited-delete"
mkdir -p "$fw/.claude/agents"
for agent in routed plain still; do
  printf -- '---\nname: %s\nmodel: sonnet\n---\nfirst\n2\n3\n4\n5\n6\n7\nlast\n' "$agent" > "$fw/.claude/agents/$agent.md"
done
commit_fixture "$fw"
git -C "$fw" tag v1.0.0
for path in .claude/skills/foo/SKILL.md .claude/hooks/gate.sh handbooks/shared.md .claude/agents/routed.md .claude/agents/plain.md; do
  sed 's/^last$/upstream/' "$fw/$path" > "$fixture/file"; cp "$fixture/file" "$fw/$path"
done
printf 'upstream\n' > "$fw/apexyard.projects.yaml"
printf 'new\n' > "$fw/docs/clean"
printf 'added\n' > "$fw/docs/new"
chmod +x "$fw/docs/new"
rm "$fw/docs/delete" "$fw/docs/edited-delete"
commit_fixture "$fw"
git -C "$fw" tag v1.1.0
reset_ops() {
  rm -rf "$ops"; mkdir "$ops"
  git -C "$ops" init -q
  git -C "$fw" archive v1.0.0 | tar -x -C "$ops"
  # Commit an extra file to make the history unrelated.
  echo adopter > "$ops/local-root"
  commit_fixture "$ops"
  git -C "$ops" fetch -q "$fw" --tags
}
run_engine() {
  code=0
  /bin/bash "$engine" "$@" --repo "$ops" --target v1.1.0 > "$fixture/out" 2>&1 </dev/null || code=$?
}
local_first() {
  sed 's/^first$/local/' "$ops/$1" > "$fixture/file"; cp "$fixture/file" "$ops/$1"
}
snapshot() {
  # Include names, bytes, modes, directories, and links. Do not follow links.
  (cd "$ops" && find . -name .git -prune -o -print | LC_ALL=C sort | while IFS= read -r p; do
    if [ -L "$p" ]; then printf 'link %s %s\n' "$p" "$(readlink "$p")"
    elif [ -f "$p" ]; then cksum "$p"; ls -ld "$p" | awk '{ print $1 }'
    else printf 'dir %s\n' "$p"; fi
  done)
}
reset_ops
printf 'local adopter\n' > "$ops/apexyard.projects.yaml"
cp "$ops/apexyard.projects.yaml" "$fixture/adopter"
run_engine --plan
has 'adopter plan' $'kept\tadopter\tapexyard.projects.yaml'
run_engine --apply
assert_eq 'adopter bytes' "$(cat "$fixture/adopter")" "$(cat "$ops/apexyard.projects.yaml")"
assert_eq 'clean framework content' new "$(cat "$ops/docs/clean")"
reset_ops
run_engine --plan
has 'clean framework plan' $'updated\tframework\tdocs/clean'
local_first .claude/skills/foo/SKILL.md
run_engine --plan
has 'framework merge plan' $'merged\tframework\t.claude/skills/foo/SKILL.md'
run_engine --apply
assert_eq 'framework merge exit' 0 "$code"
assert_eq 'framework local edit' local "$(head -n 1 "$ops/.claude/skills/foo/SKILL.md")"
assert_eq 'framework upstream edit' upstream "$(tail -n 1 "$ops/.claude/skills/foo/SKILL.md")"
patch=$(find "$ops/.claude/session/update-backup" -name '*.patch' -print)
assert_eq 'backup exists' yes "$([ -n "$patch" ] && echo yes)"
assert_eq 'backup holds edit' yes "$(grep -q '+local' "$patch" && echo yes)"
assert_eq 'release anchor' v1.1.0 "$(cat "$ops/.claude/framework-version")"
reset_ops
sed 's/^last$/local conflict/' "$ops/.claude/skills/foo/SKILL.md" > "$fixture/file"
cp "$fixture/file" "$ops/.claude/skills/foo/SKILL.md"
run_engine --plan
has 'framework conflict plan' $'conflict\tframework\t.claude/skills/foo/SKILL.md'
before=$(snapshot)
run_engine --apply
assert_eq 'conflict exit' 1 "$code"
assert_eq 'conflict writes nothing' "$before" "$(snapshot)"
has 'conflict local diff' '+local conflict'
has 'conflict custom skill suggestion' './custom-skills/foo/'
reset_ops
local_first handbooks/shared.md
run_engine --plan
has 'shared merge plan' $'merged\tshared\thandbooks/shared.md'
run_engine --apply
assert_eq 'shared local edit' local "$(head -n 1 "$ops/handbooks/shared.md")"
assert_eq 'shared upstream edit' upstream "$(tail -n 1 "$ops/handbooks/shared.md")"
reset_ops
local_first .claude/hooks/gate.sh
before=$(snapshot)
run_engine --apply
assert_eq 'security refuses non-tty' 3 "$code"
assert_eq 'security writes nothing' "$before" "$(snapshot)"
has 'security banner' 'SECURITY: local edits to gate files'
has 'security path' '.claude/hooks/gate.sh'
assert_eq 'security banner first' '!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!' "$(head -n 1 "$fixture/out")"
run_engine --apply --confirm-security
assert_eq 'security confirmed exit' 0 "$code"
assert_eq 'security local edit' local "$(head -n 1 "$ops/.claude/hooks/gate.sh")"
assert_eq 'security upstream edit' upstream "$(tail -n 1 "$ops/.claude/hooks/gate.sh")"
reset_ops
local_first .claude/hooks/static.sh
run_engine --plan
has 'security with no upstream change' $'kept\tframework\t.claude/hooks/static.sh\tsecurity'
run_engine --apply
assert_eq 'kept security needs confirmation' 3 "$code"
reset_ops
run_engine --plan
has 'new file plan' $'updated\tframework\tdocs/new'
has 'delete file plan' $'updated\tframework\tdocs/delete'
run_engine --apply
assert_eq 'new file created' added "$(cat "$ops/docs/new")"
assert_eq 'new file mode' yes "$([ -x "$ops/docs/new" ] && echo yes)"
assert_eq 'old file deleted' no "$([ -e "$ops/docs/delete" ] && echo yes || echo no)"
reset_ops
echo local > "$ops/docs/edited-delete"
run_engine --plan
has 'edited delete conflict' $'conflict\tframework\tdocs/edited-delete'
reset_ops
mkdir -p "$ops/.claude/skills/custom-x"
echo custom > "$ops/.claude/skills/custom-x/SKILL.md"
before=$(snapshot); status_before=$(git -C "$ops" status --porcelain)
run_engine --plan
assert_eq 'plan leaves work tree' "$before" "$(snapshot)"
assert_eq 'plan leaves index' "$status_before" "$(git -C "$ops" status --porcelain)"
assert_eq 'local-only path absent from plan' no "$(grep -q custom-x "$fixture/out" && echo yes || echo no)"
grep $'\t' "$fixture/out" > "$fixture/plan"
run_engine --apply
grep $'\t' "$fixture/out" > "$fixture/apply"
assert_eq 'plan and apply agree' "$(cat "$fixture/plan")" "$(cat "$fixture/apply")"
assert_eq 'local-only content' custom "$(cat "$ops/.claude/skills/custom-x/SKILL.md")"
reset_ops
rm "$ops/.claude/framework-version"
run_engine --plan
assert_eq 'missing anchor exit' 2 "$code"
has 'missing anchor message' '.claude/framework-version'
run_engine --plan --base v1.0.0
assert_eq 'explicit base without anchor' 0 "$code"
reset_ops
mkdir -p "$ops/custom-skills/foo"
echo custom > "$ops/custom-skills/foo/SKILL.md"
rm -rf "$ops/.claude/skills/foo"
ln -s ../../custom-skills/foo "$ops/.claude/skills/foo"
run_engine --plan
has 'overlay plan' $'kept\tframework\t.claude/skills/foo/SKILL.md\toverlay'
run_engine --apply
assert_eq 'overlay exit' 0 "$code"
assert_eq 'overlay content' custom "$(cat "$ops/custom-skills/foo/SKILL.md")"
assert_eq 'overlay link remains' yes "$([ -L "$ops/.claude/skills/foo" ] && echo yes)"
# Test a directory and a local delete without a local file read.
reset_ops
rm "$ops/docs/clean"; mkdir "$ops/docs/clean"
run_engine --apply
assert_eq 'directory conflict' 1 "$code"
reset_ops
rm "$ops/docs/clean"
run_engine --apply
assert_eq 'local delete conflict' 1 "$code"
# Check unchanged upstream files, absent files, and invalid inputs.
reset_ops
local_first .claude/hooks/static.sh
run_engine --apply --confirm-security
assert_eq 'kept security confirmed exit' 0 "$code"
assert_eq 'kept security edit remains' local "$(head -n 1 "$ops/.claude/hooks/static.sh")"
assert_eq 'kept security backup' yes "$(find "$ops/.claude/session/update-backup" -name static.sh.patch | while IFS= read -r p; do grep -q '+local' "$p" && echo yes; done)"
reset_ops
printf 'bad\n' > "$ops/.claude/framework-version"
run_engine --plan
assert_eq 'malformed anchor' 2 "$code"
printf 'v1.0.0\n\n' > "$ops/.claude/framework-version"
run_engine --plan
assert_eq 'multiple anchor lines' 2 "$code"
run_engine --plan --base missing-ref
assert_eq 'missing base ref' 2 "$code"
has 'base fetch instruction' 'git fetch upstream --tags'
reset_ops
code=0
/bin/bash "$engine" --plan --repo "$ops" --target missing-ref > "$fixture/out" 2>&1 || code=$?
assert_eq 'missing target ref' 2 "$code"
reset_ops
# The target manifest has no rule for itself.
run_engine --plan
has 'unclassified file' $'kept\tunmatched\t.claude/ownership-manifest.yaml\tunclassified'
# A file can already hold the target blob.
printf 'new\n' > "$ops/docs/clean"
run_engine --plan
assert_eq 'target blob is unchanged' no "$(grep -q $'\tdocs/clean' "$fixture/out" && echo yes || echo no)"
# Preserve a local delete when the upstream blob has not changed.
rm "$ops/.claude/hooks/static.sh"
run_engine --plan
has 'local delete is kept and marked' $'kept\tframework\t.claude/hooks/static.sh\tsecurity'
# Confirm a single-file overlay without reading the link target.
reset_ops
rm "$ops/docs/clean"
ln -s "$fixture/missing" "$ops/docs/clean"
run_engine --plan
has 'dangling file overlay' $'kept\tframework\tdocs/clean\toverlay'
run_engine --apply
assert_eq 'dangling overlay remains' yes "$([ -L "$ops/docs/clean" ] && echo yes)"
# Drift uses the base ref and leaves all local files intact.
run_drift() {
  code=0
  /bin/bash "$engine" --drift --repo "$ops" "$@" > "$fixture/out" 2>&1 </dev/null || code=$?
}
reset_ops
run_drift
assert_eq 'clean drift exit' 0 "$code"
has 'clean drift summary' 'drift: no local edits to framework-owned files'
local_first .claude/skills/foo/SKILL.md
local_first .claude/hooks/static.sh
local_first handbooks/shared.md
printf 'local adopter\n' > "$ops/apexyard.projects.yaml"
before=$(snapshot)
run_drift
assert_eq 'local drift exit' 1 "$code"
has 'skill drift' $'drift\t.claude/skills/foo/SKILL.md'
has 'drift skill suggestion' '  Suggestion: copy the skill to ./custom-skills/foo/'
has 'security drift' $'drift\t.claude/hooks/static.sh\tsecurity'
has 'local drift summary' 'drift: 2 local edit(s) to framework-owned files'
assert_eq 'shared path has no drift' no "$(grep -q 'handbooks/shared.md' "$fixture/out" && echo yes || echo no)"
assert_eq 'adopter path has no drift' no "$(grep -q 'apexyard.projects.yaml' "$fixture/out" && echo yes || echo no)"
assert_eq 'drift leaves work tree' "$before" "$(snapshot)"
run_drift --target x
assert_eq 'drift rejects target' 2 "$code"
run_drift --confirm-security
assert_eq 'drift rejects security confirmation' 2 "$code"
reset_ops
rm "$ops/docs/clean"
ln -s "$fixture/missing" "$ops/docs/clean"
run_drift
assert_eq 'overlay has no drift' 0 "$code"
assert_eq 'overlay path absent from drift' no "$(grep -q 'docs/clean' "$fixture/out" && echo yes || echo no)"
reset_ops
local_first .claude/skills/foo/SKILL.md
: > "$ops/.apexyard-fork"
mkdir -p "$ops/bin"
cp "$SRC_ROOT/bin/update-files.sh" "$SRC_ROOT/bin/_lib-ownership.sh" "$ops/bin/"
code=0
(cd "$ops" && /bin/bash "$SRC_ROOT/bin/apexyard" doctor --drift) > "$fixture/out" 2>&1 || code=$?
assert_eq 'doctor drift exit' 1 "$code"
has 'doctor skill drift' $'drift\t.claude/skills/foo/SKILL.md'
# Compare classes and bytes for a merge, a kept file, and an update.
reset_ops
local_first .claude/skills/foo/SKILL.md
printf 'local adopter\n' > "$ops/apexyard.projects.yaml"
cp "$ops/apexyard.projects.yaml" "$fixture/kept"
printf 'v1.1.0\n' > "$ops/.claude/framework-version"
run_engine --plan --base v1.0.0
assert_eq 'class plan exit' 0 "$code"
has 'class plan merge' $'merged\tframework\t.claude/skills/foo/SKILL.md'
has 'class plan kept' $'kept\tadopter\tapexyard.projects.yaml'
has 'class plan update' $'updated\tframework\tdocs/clean'
awk -F '\t' 'NF >= 3 { print $1 "\t" $2 "\t" $3 }' "$fixture/out" | LC_ALL=C sort > "$fixture/plan"
run_engine --apply --base v1.0.0
assert_eq 'class apply exit' 0 "$code"
awk -F '\t' 'NF >= 3 { print $1 "\t" $2 "\t" $3 }' "$fixture/out" | LC_ALL=C sort > "$fixture/apply"
assert_eq 'plan and apply classes agree' "$(cat "$fixture/plan")" "$(cat "$fixture/apply")"
while IFS=$'\t' read -r status _ path; do
  case "$status" in
    merged)
      assert_eq "merged local bytes: $path" local "$(head -n 1 "$ops/$path")"
      assert_eq "merged upstream bytes: $path" upstream "$(tail -n 1 "$ops/$path")" ;;
    updated)
      if git -C "$fw" cat-file -e "v1.1.0:$path" 2>/dev/null; then
        git -C "$fw" show "v1.1.0:$path" > "$fixture/expected"
        assert_eq "updated bytes: $path" yes "$(cmp -s "$fixture/expected" "$ops/$path" && echo yes || echo no)"
      else
        assert_eq "updated delete: $path" no "$([ -e "$ops/$path" ] && echo yes || echo no)"
      fi ;;
    kept)
      git -C "$ops" show "HEAD:$path" > "$fixture/expected"
      if [ "$path" = apexyard.projects.yaml ]; then cp "$fixture/kept" "$fixture/expected"; fi
      if [ "$path" = .claude/framework-version ]; then printf 'v1.1.0\n' > "$fixture/expected"; fi
      assert_eq "kept bytes: $path" yes "$(cmp -s "$fixture/expected" "$ops/$path" && echo yes || echo no)" ;;
  esac
done < "$fixture/plan"
# Routed agents: the routing hook rewrites the model line. The update takes
# upstream's file and ignores that line for each agent the routing names.
set_model() {
  sed "s/^model: sonnet$/model: $2/" "$ops/.claude/agents/$1.md" > "$fixture/file"
  cp "$fixture/file" "$ops/.claude/agents/$1.md"
}
write_routing() {
  printf '# routing\nagents:\n  routed:\n    model: opus\n  "still":\n    model: opus\nother:\n  plain:\n    model: x\n' > "$1"
}
reset_ops
write_routing "$ops/agent-routing.yaml"
for agent in routed plain still; do set_model "$agent" opus; done
run_engine --plan
has 'routed model line is not an edit' $'updated\tframework\t.claude/agents/routed.md'
has 'unrouted model line is an edit' $'merged\tframework\t.claude/agents/plain.md'
assert_eq 'routed agent with no upstream change' no "$(grep -q 'agents/still.md' "$fixture/out" && echo yes || echo no)"
has 'plan header names the default' '# Per-file update by owner class. This is the default. /update --git-merge runs the history merge instead.'
run_engine --apply
assert_eq 'routed apply exit' 0 "$code"
assert_eq 'routed agent takes upstream file' "$(git -C "$fw" show v1.1.0:.claude/agents/routed.md)" "$(cat "$ops/.claude/agents/routed.md")"
assert_eq 'unrouted agent keeps local model' 'model: opus' "$(grep '^model:' "$ops/.claude/agents/plain.md")"
assert_eq 'routed still agent is untouched' 'model: opus' "$(grep '^model:' "$ops/.claude/agents/still.md")"
reset_ops
write_routing "$ops/agent-routing.yaml"
set_model routed opus
local_first .claude/agents/routed.md
run_engine --plan
has 'routed agent with a body edit merges' $'merged\tframework\t.claude/agents/routed.md'
run_engine --apply
assert_eq 'routed merge keeps the body edit' local "$(sed -n '5p' "$ops/.claude/agents/routed.md")"
assert_eq 'routed merge takes upstream body' upstream "$(tail -n 1 "$ops/.claude/agents/routed.md")"
assert_eq 'routed merge takes base model line' 'model: sonnet' "$(grep '^model:' "$ops/.claude/agents/routed.md")"
reset_ops
set_model routed opus
run_engine --plan
has 'no routing file: model line is an edit' $'merged\tframework\t.claude/agents/routed.md'
if command -v jq >/dev/null 2>&1; then
  reset_ops
  mkdir -p "$ops/routing"
  write_routing "$ops/routing/custom.yaml"
  printf '{"portfolio":{"agent_routing":"routing/custom.yaml"}}\n' > "$ops/.claude/project-config.json"
  set_model routed opus
  run_engine --plan
  has 'routing path from project config' $'updated\tframework\t.claude/agents/routed.md'
else
  echo 'NOTE: jq is not installed, so the project-config routing path is not checked'
fi
# doctor --drift: a routed model line is not drift. An unrouted one is.
reset_ops
write_routing "$ops/agent-routing.yaml"
set_model routed opus
set_model still opus
run_drift
assert_eq 'routed model line is not drift' 0 "$code"
has 'routed drift summary' 'drift: no local edits to framework-owned files'
set_model plain opus
run_drift
assert_eq 'unrouted model line is drift' 1 "$code"
has 'unrouted drift line' $'drift\t.claude/agents/plain.md'
assert_eq 'routed agent not listed' no "$(grep -Eq 'agents/(routed|still).md' "$fixture/out" && echo yes || echo no)"
rm "$ops/agent-routing.yaml"
run_drift
assert_eq 'no routing file: model lines are drift' 1 "$code"
has 'drift without routing lists routed' $'drift\t.claude/agents/routed.md'

# Fail closed on unreadable git state (Rex B1 on #1894).
reset_ops
missing=0123456789abcdef0123456789abcdef01234567
bad_commit=$(printf 'tree %s\nauthor t <t@t> 0 +0000\ncommitter t <t@t> 0 +0000\n\nmissing tree\n' "$missing" |
  git -C "$ops" hash-object -t commit -w --literally --stdin)
before=$(snapshot)
code=0
/bin/bash "$engine" --apply --confirm-security --repo "$ops" --target "$bad_commit" > "$fixture/out" 2>&1 </dev/null || code=$?
assert_eq 'missing target tree exits 2' 2 "$code"
assert_eq 'missing target tree writes nothing' "$before" "$(snapshot)"
has 'missing target tree message' 'Cannot read the target tree. Nothing is written.'
sub=$(printf '100644 blob %s\townership-manifest.yaml\n' "$missing" | git -C "$ops" mktree --missing)
top=$(printf '040000 tree %s\t.claude\n' "$sub" | git -C "$ops" mktree)
bad_commit=$(git -C "$ops" -c user.name=t -c user.email=t@t commit-tree "$top" -m 'missing manifest blob')
code=0
/bin/bash "$engine" --apply --confirm-security --repo "$ops" --target "$bad_commit" > "$fixture/out" 2>&1 </dev/null || code=$?
assert_eq 'unreadable target manifest exits 2' 2 "$code"
assert_eq 'unreadable target manifest writes nothing' "$before" "$(snapshot)"
has 'no fallback to the base manifest' 'Cannot read the ownership manifest. Nothing is written.'
# Refuse a hostile tree path (Rex A1 on #1894).
good=$(printf 'x\n' | git -C "$ops" hash-object -w --stdin)
sub=$(printf '100644 blob %s\tescape\n' "$good" | git -C "$ops" mktree)
top=$(printf '040000 tree %s\t..\n' "$sub" | git -C "$ops" mktree)
bad_commit=$(git -C "$ops" -c user.name=t -c user.email=t@t commit-tree "$top" -m 'dot-dot path')
code=0
/bin/bash "$engine" --plan --repo "$ops" --target "$bad_commit" > "$fixture/out" 2>&1 </dev/null || code=$?
assert_eq 'dot-dot tree path exits 2' 2 "$code"
has 'dot-dot tree path message' "Refused tree path with a '..' or '.git' segment: ../escape"
# A gate file behind a link is never kept silently (Rex B2 on #1894).
reset_ops
printf 'other gate\n' > "$fixture/other-gate.sh"
rm "$ops/.claude/hooks/static.sh"
ln -s "$fixture/other-gate.sh" "$ops/.claude/hooks/static.sh"
run_engine --plan
has 'linked gate file is marked' $'kept\tframework\t.claude/hooks/static.sh\tsecurity\toverlay'
before=$(snapshot)
run_engine --apply
assert_eq 'linked gate file needs confirmation' 3 "$code"
assert_eq 'linked gate file writes nothing' "$before" "$(snapshot)"
has 'banner shows the link' "link: .claude/hooks/static.sh -> $fixture/other-gate.sh"
run_engine --apply --confirm-security
assert_eq 'linked gate file confirmed' 0 "$code"
assert_eq 'linked gate file link remains' yes "$([ -L "$ops/.claude/hooks/static.sh" ] && echo yes)"
assert_eq 'link target is not written' 'other gate' "$(cat "$fixture/other-gate.sh")"
reset_ops
mv "$ops/.claude/hooks" "$ops/custom-hooks"
ln -s ../custom-hooks "$ops/.claude/hooks"
before=$(snapshot)
run_engine --apply
assert_eq 'linked hooks dir needs confirmation' 3 "$code"
assert_eq 'linked hooks dir writes nothing' "$before" "$(snapshot)"
has 'banner shows the hooks dir link' 'link: .claude/hooks -> ../custom-hooks'
has 'linked hooks dir gate is listed' '.claude/hooks/gate.sh (kept, behind a link)'

echo '===== test_update_files.sh ====='
echo "Passed: $PASS"
echo "Failed: $FAIL"
[ "$FAIL" -eq 0 ]
