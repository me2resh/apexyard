#!/usr/bin/env bash
# Exercise rescue only against disposable repositories.
# Assertions evaluate their expressions inside check().
# shellcheck disable=SC2016,SC2034
set -u
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"
SRC=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
repo="$tmp/ops"
PASS=0 FAIL=0
check() {
  if eval "$2"; then echo "PASS: $1"; PASS=$((PASS + 1))
  else echo "FAIL: $1"; cat "$tmp/out"; FAIL=$((FAIL + 1)); fi
}
run() {
  rc=0
  bash "$SRC/bin/update-files.sh" --drift --repo "$repo" "$@" > "$tmp/out" 2>&1 || rc=$?
}
reset() {
  rm -rf "$repo" "$tmp/product" "$tmp/private"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$tmp/framework" archive v1.0.0 | tar -x -C "$repo"
  git -C "$repo" fetch -q "$tmp/framework" --tags
}
mkdir -p "$tmp/framework/.claude/skills/example" "$tmp/framework/.claude/agents" "$tmp/framework/.claude/hooks" "$tmp/framework/templates" "$tmp/framework/handbooks"
cat > "$tmp/framework/.claude/ownership-manifest.yaml" <<'YAML'
version: 1
paths:
  - glob: .claude/framework-version
    owner: adopter
  - glob: .claude/project-config.json
    owner: adopter
  - glob: .claude/settings*.json
    owner: shared
  - glob: .claude/**
    owner: framework
  - glob: templates/**
    owner: framework
  - glob: handbooks/**
    owner: shared
YAML
printf 'v1.0.0\n' > "$tmp/framework/.claude/framework-version"
printf -- '---\nname: example\ndescription: Write reports\n---\nOriginal\n' > "$tmp/framework/.claude/skills/example/SKILL.md"
printf -- '---\nname: reviewer\ndescription: Review code\n---\nOriginal\n' > "$tmp/framework/.claude/agents/reviewer.md"
printf 'supporting file\n' > "$tmp/framework/.claude/skills/example/helper.sh"
mkdir -p "$tmp/framework/.claude/skills/_lib-helper" "$tmp/framework/.claude/skills/no-entry"
printf 'helper\n' > "$tmp/framework/.claude/skills/_lib-helper/helper.sh"
printf 'helper\n' > "$tmp/framework/.claude/skills/no-entry/helper.sh"
for settings in settings.json settings.team.json; do
  printf '{"hooks":{}}\n' > "$tmp/framework/.claude/$settings"
done
for number in 1 2 3 4 5 6; do
  printf -- '---\nname: helper-%s\ndescription: Support the reviewer\n---\nOriginal\n' "$number" > "$tmp/framework/.claude/agents/helper-$number.md"
done
printf 'original hook\n' > "$tmp/framework/.claude/hooks/gate.sh"
printf 'original template\n' > "$tmp/framework/templates/report.md"
printf 'original handbook\n' > "$tmp/framework/handbooks/standard.md"
git -C "$tmp/framework" init -q
git -C "$tmp/framework" add .claude templates handbooks
git -C "$tmp/framework" -c user.name=fixture -c user.email=fixture@example.test commit -qm fixture
git -C "$tmp/framework" tag v1.0.0
reset
run
check 'clean tree' '[ "$rc" -eq 0 ]'
rm "$repo/.claude/framework-version"
run
check 'missing pin is drift' '[ "$rc" -eq 1 ] && grep -q "no pinned version" "$tmp/out"'
reset
for settings in settings.json settings.team.json; do
  printf '{"hooks":{"SessionStart":[{"command":"echo local"}]}}\n' > "$repo/.claude/$settings"
done
before=$(cksum "$repo/.claude/"settings*.json)
run
check 'shared tracked settings detected as drift' '[ "$rc" -eq 1 ] && grep -q "drift.*.claude/settings.json" "$tmp/out" && grep -q "drift.*.claude/settings.team.json" "$tmp/out"'
run --rescue --apply
after=$(cksum "$repo/.claude/"settings*.json)
check 'added settings hook listed for person and never moved' '[ "$before" = "$after" ] && grep -q "manual review.*.claude/settings.json" "$tmp/out" && grep -q "manual review.*.claude/settings.team.json" "$tmp/out" && ! grep -q "rescue plan.*settings" "$tmp/out"'
reset
for folder in _lib-helper no-entry; do
  printf 'edited\n' >> "$repo/.claude/skills/$folder/helper.sh"
done
run --rescue --apply
check 'helper folders without overlay homes stay for person' 'grep -q "manual review.*_lib-helper/helper.sh" "$tmp/out" && grep -q "manual review.*no-entry/helper.sh" "$tmp/out" && grep -q edited "$repo/.claude/skills/_lib-helper/helper.sh" && grep -q edited "$repo/.claude/skills/no-entry/helper.sh" && [ ! -e "$repo/custom-skills" ]'
reset
mkdir -p "$tmp/product"
cp -R "$repo/.claude" "$tmp/product/"
run --rescue --from "$tmp/product/.claude"
check 'unedited framework agents give zero duplicates' '! grep -q "^duplicate" "$tmp/out" && [ "$(grep -c "^shared.*agents/" "$tmp/out")" -eq 7 ]'
printf 'body-only edit\n' >> "$tmp/product/.claude/agents/helper-1.md"
run --rescue --from "$tmp/product/.claude"
check 'matching name and description remain shared' '! grep -q "^duplicate" "$tmp/out" && grep -q "^shared.*agents/helper-1.md" "$tmp/out"'
reset
printf '{"portfolio":{"agent_routing":"./absent.yaml"}}\n' > "$repo/.claude/project-config.json"
run
check 'absent config file' '[ "$rc" -eq 1 ] && grep -q "absent file" "$tmp/out"'
reset
printf 'your edit\n' >> "$repo/.claude/skills/example/SKILL.md"
printf 'your hook\n' >> "$repo/.claude/hooks/gate.sh"
before=$(find "$repo" -type f -not -path '*/.git/*' -exec cksum {} \; | LC_ALL=C sort)
run --rescue
after=$(find "$repo" -type f -not -path '*/.git/*' -exec cksum {} \; | LC_ALL=C sort)
check 'dry run preserves every file' '[ "$before" = "$after" ]'
check 'dry run writes nothing' '[ ! -e "$repo/custom-skills" ] && grep -q "your edit" "$repo/.claude/skills/example/SKILL.md"'
check 'hook listed for person' 'grep -q "manual review.*.claude/hooks/gate.sh" "$tmp/out"'
run --rescue --apply
check 'skill copied to overlay' 'grep -q "your edit" "$repo/custom-skills/example/SKILL.md"'
check 'supporting skill file copied' 'cmp -s "$repo/.claude/skills/example/helper.sh" "$repo/custom-skills/example/helper.sh"'
check 'skill restored to pin' '! grep -q "your edit" "$repo/.claude/skills/example/SKILL.md"'
check 'hook remains edited' 'grep -q "your hook" "$repo/.claude/hooks/gate.sh" && [ ! -e "$repo/custom-hooks" ]'
reset
mkdir -p "$tmp/product"
cp -R "$repo/.claude" "$tmp/product/"
printf -- '---\nname: example\ndescription: Deploy containers\n---\n' > "$tmp/product/.claude/skills/example/SKILL.md"
cp "$repo/.claude/agents/reviewer.md" "$tmp/product/.claude/agents/other-reviewer.md"
printf -- '---\nname: extra\ndescription: Another reviewer for this repository\n---\n' > "$tmp/product/.claude/agents/extra.md"
mkdir -p "$tmp/product/.claude/skills/new"
printf 'new skill\n' > "$tmp/product/.claude/skills/new/SKILL.md"
run --rescue --from "$tmp/product/.claude" --apply
check 'same name different job is duplicate' 'grep -q "duplicate.*skills/example/SKILL.md" "$tmp/out" && [ ! -e "$repo/custom-skills/example/SKILL.md" ]'
check 'second agent for role is duplicate' 'grep -q "duplicate.*agents/other-reviewer.md" "$tmp/out"'
check 'role phrase identifies second agent' 'grep -q "duplicate.*agents/extra.md" "$tmp/out"'
check 'repo-only stays' 'grep -q "repo-only.*skills/new/SKILL.md.*stay" "$tmp/out" && [ -f "$tmp/product/.claude/skills/new/SKILL.md" ]'
check 'unchanged shared classified' 'grep -q "shared.*agents/reviewer.md" "$tmp/out"'
cp "$repo/.claude/skills/example/SKILL.md" "$tmp/product/.claude/skills/example/SKILL.md"
printf 'repo-only attachment\n' > "$tmp/product/.claude/skills/example/local.txt"
printf 'imported edit\n' >> "$tmp/product/.claude/skills/example/SKILL.md"
run --rescue --from "$tmp/product/.claude" --apply
check 'import shared edit copied' 'grep -q "imported edit" "$repo/custom-skills/example/SKILL.md"'
# The overlay replaces the whole skill folder, so an import keeps the pinned
# supporting files (Hakim review 6012275255).
check 'import keeps pinned supporting files' '[ -f "$repo/custom-skills/example/helper.sh" ] && grep -q "supporting file" "$repo/custom-skills/example/helper.sh"'
check 'import copies only planned files' '[ ! -e "$repo/custom-skills/example/local.txt" ] && grep -q "repo-only.*example/local.txt.*stay" "$tmp/out"'
check 'import source preserved' 'grep -q "imported edit" "$tmp/product/.claude/skills/example/SKILL.md"'
reset
mkdir -p "$tmp/private"
printf '{}' > "$repo/.claude/project-config.defaults.json"
printf '{"portfolio":{"registry":"../private/registry.yaml","custom_skills_dir":"../private/custom-skills","custom_handbooks_dir":"../private/custom-handbooks"}}' > "$repo/.claude/project-config.json"
touch "$tmp/private/registry.yaml"
printf 'edited\n' >> "$repo/.claude/skills/example/SKILL.md"
printf 'edited\n' >> "$repo/templates/report.md"
printf 'edited\n' >> "$repo/handbooks/standard.md"
run --rescue --apply
check 'split skill overlay' 'grep -q edited "$tmp/private/custom-skills/example/SKILL.md"'
check 'split template overlay' 'grep -q edited "$tmp/private/custom-templates/report.md"'
check 'split handbook overlay' 'grep -q edited "$tmp/private/custom-handbooks/standard.md"'
reset
mkdir -p "$repo/custom-skills/example"
printf 'existing\n' > "$repo/custom-skills/example/SKILL.md"
printf 'edited\n' >> "$repo/.claude/skills/example/SKILL.md"
run --rescue --apply
check 'overlay collision refuses all writes' '[ "$rc" -eq 2 ] && grep -q existing "$repo/custom-skills/example/SKILL.md" && grep -q edited "$repo/.claude/skills/example/SKILL.md"'
reset
mkdir -p "$repo/custom-skills"
ln -s "$tmp/private" "$repo/custom-skills/example"
printf 'edited\n' >> "$repo/.claude/skills/example/SKILL.md"
run --rescue --apply
check 'overlay link refused' '[ "$rc" -eq 2 ] && grep -q edited "$repo/.claude/skills/example/SKILL.md"'
reset
git -C "$repo" update-ref refs/remotes/upstream/main v1.0.0
run
check 'your and upstream sections' 'grep -q "Your change" "$tmp/out" && grep -q "Upstream change" "$tmp/out"'
# Install only the tested runtime into the fixture for CLI and notice checks.
mkdir -p "$repo/bin"
cp "$SRC/bin/update-files.sh" "$SRC/bin/_lib-ownership.sh" "$SRC/bin/_lib-drift-rescue.sh" "$repo/bin/"
cp "$SRC/.claude/hooks/check-framework-drift.sh" "$repo/.claude/hooks/"
bash "$repo/.claude/hooks/check-framework-drift.sh" > "$tmp/notice"
check 'clean notice silent' '[ ! -s "$tmp/notice" ]'
printf 'edited\n' >> "$repo/.claude/skills/example/SKILL.md"
notice_rc=0
bash "$repo/.claude/hooks/check-framework-drift.sh" > "$tmp/notice" || notice_rc=$?
check 'notice warns once and succeeds' '[ "$notice_rc" -eq 0 ] && [ "$(wc -l < "$tmp/notice")" -eq 1 ] && grep -q "doctor --drift" "$tmp/notice"'
# The marker makes the CLI select the fixture, not its source checkout.
touch "$repo/.apexyard-fork"
rc=0
(cd "$repo" && bash "$SRC/bin/apexyard" doctor --drift) > "$tmp/out" 2>&1 || rc=$?
check 'CLI drift usable in CI' '[ "$rc" -eq 1 ] && grep -q "skills/example/SKILL.md" "$tmp/out"'
# A framework source clone (origin is the framework repo) has no pin: no
# notice. A team's ops fork without a pin still warns.
src_clone="$tmp/source-clone"; mkdir -p "$src_clone/.claude/hooks" "$src_clone/bin"
git -C "$src_clone" init -q
cp "$SRC/.claude/hooks/check-framework-drift.sh" "$src_clone/.claude/hooks/"
cp "$SRC/bin/update-files.sh" "$SRC/bin/_lib-ownership.sh" "$SRC/bin/_lib-drift-rescue.sh" "$src_clone/bin/"
touch "$src_clone/.apexyard-fork"
git -C "$src_clone" remote add origin https://github.com/me2resh/apexyard.git
bash "$src_clone/.claude/hooks/check-framework-drift.sh" > "$tmp/notice"
check 'framework source clone gets no notice' '[ ! -s "$tmp/notice" ]'
git -C "$src_clone" remote set-url origin git@github.com:a-team/ops.git
bash "$src_clone/.claude/hooks/check-framework-drift.sh" > "$tmp/notice"
check 'ops fork without a pin warns' 'grep -q "doctor --drift" "$tmp/notice"'
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
