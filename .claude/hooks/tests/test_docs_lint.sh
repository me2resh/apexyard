#!/usr/bin/env bash
# Test the shared document lint.
set -u
if ! command -v node >/dev/null 2>&1; then
  echo 'SKIP: node is missing.'
  exit 0
fi
SRC_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
PASS=0
FAIL=0
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
assert_eq() {
  local label="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then
    echo "PASS [$label]"
    PASS=$((PASS + 1))
  else
    echo "FAIL [$label]: want '$want', got '$got'" >&2
    FAIL=$((FAIL + 1))
  fi
}
mkdir -p "$fixture/docs/private" "$fixture/skills/demo"
git -C "$fixture" init -q
git -C "$fixture" config user.name 'Lint Test'
git -C "$fixture" config user.email 'lint@example.test'
cp "$SRC_ROOT/docs/docs-lint-rules.json" "$fixture/docs/docs-lint-rules.json"
cat > "$fixture/docs/docs-lint-scope.json" <<'JSON'
{"version":1,"include":[{"glob":"docs/**/*.md"},{"glob":"skills/*/SKILL.md","frontmatterOnly":true}],"exclude":["docs/private/**"]}
JSON
cat > "$fixture/docs/sample.md" <<'MD'
The file is written by the tool.

Use simply this file.

1. Read one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty.

Read one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty.

```
The file is written simply.
```

`The file is written simply.`
MD
printf '\nUse this \342\200\224 then stop.\n' >> "$fixture/docs/sample.md"
printf 'The file is written simply.\n' > "$fixture/docs/private/hidden.md"
cat > "$fixture/skills/demo/SKILL.md" <<'MD'
---
title: Test skill
description: The file is written by the tool.
---
The file is written simply.
MD
# Track fixture files without git add. Keep all writes in the fixture.
track() {
  local file="$1" blob
  blob=$(git -C "$fixture" hash-object -w "$file")
  git -C "$fixture" update-index --add --cacheinfo "100644,$blob,${file#"$fixture/"}"
}
for file in "$fixture"/docs/*.json "$fixture"/docs/*.md "$fixture"/docs/private/*.md "$fixture"/skills/demo/SKILL.md; do
  track "$file"
done
lint() { node "$SRC_ROOT/bin/docs-lint.mjs" --root "$fixture" "$@"; }
status=0
output=$(lint) || status=$?
assert_eq 'report exit' 0 "$status"
assert_eq 'passive file and line' 1 "$(printf '%s\n' "$output" | grep -c '^docs/sample.md:1: passive-voice:')"
assert_eq 'em dash' 1 "$(printf '%s\n' "$output" | grep -c '^docs/sample.md:15: em-dash:')"
assert_eq 'banned word' 1 "$(printf '%s\n' "$output" | grep -c '^docs/sample.md:3: banned-word:')"
assert_eq 'step length' 1 "$(printf '%s\n' "$output" | grep -c '^docs/sample.md:5: sentence-length-step:')"
assert_eq 'paragraph length' 0 "$(printf '%s\n' "$output" | grep -c '^docs/sample.md:7:')"
assert_eq 'ignore code' 0 "$(printf '%s\n' "$output" | grep -Ec '^docs/sample.md:(10|13):')"
assert_eq 'exclude path' 0 "$(printf '%s\n' "$output" | grep -c '^docs/private/hidden.md:')"
assert_eq 'skill description' 1 "$(printf '%s\n' "$output" | grep -c '^skills/demo/SKILL.md:3: passive-voice:')"
assert_eq 'ignore skill body' 0 "$(printf '%s\n' "$output" | grep -c '^skills/demo/SKILL.md:5:')"
assert_eq 'fixed sample parity count' 'Total: 4 findings' "$(lint docs/sample.md | grep '^Total:')"
printf 'The file is written by the tool.\n' > "$fixture/docs/base.md"
track "$fixture/docs/base.md"
# Create commits without commit hooks or workspace changes.
commit_fixture() {
  local tree commit
  tree=$(git -C "$fixture" write-tree)
  if git -C "$fixture" rev-parse --verify HEAD >/dev/null 2>&1; then
    commit=$(printf 'Test fixture\n' | git -C "$fixture" commit-tree "$tree" -p HEAD)
  else
    commit=$(printf 'Test fixture\n' | git -C "$fixture" commit-tree "$tree")
  fi
  git -C "$fixture" update-ref HEAD "$commit"
}
commit_fixture
base=$(git -C "$fixture" rev-parse HEAD)
printf '\nUse simply this file.\n\nRead the file.\n' >> "$fixture/docs/base.md"
track "$fixture/docs/base.md"
commit_fixture
status=0
output=$(lint --base "$base" --strict docs/base.md) || status=$?
assert_eq 'strict bad exit' 1 "$status"
assert_eq 'strict added line' 1 "$(printf '%s\n' "$output" | grep -c '^docs/base.md:3: banned-word:')"
assert_eq 'strict old line' 0 "$(printf '%s\n' "$output" | grep -c '^docs/base.md:1:')"
assert_eq 'old count only' 1 "$(printf '%s\n' "$output" | grep -c '^1 findings on unchanged lines, not checked$')"
status=0
lint --base "$base" docs/base.md >/dev/null || status=$?
assert_eq 'base report exit' 0 "$status"
printf 'The file is written by the tool.\n\nRead the file.\n' > "$fixture/docs/base.md"
track "$fixture/docs/base.md"
commit_fixture
status=0
output=$(lint --base "$base" --strict docs/base.md) || status=$?
assert_eq 'strict clean exit' 0 "$status"
assert_eq 'strict clean total' 1 "$(printf '%s\n' "$output" | grep -c '^Total: 0 findings$')"
printf 'docs/sample.md:3-3\n' > "$fixture/changed"
status=0
output=$(lint --changed "$fixture/changed" --strict docs/sample.md) || status=$?
assert_eq 'changed file exit' 1 "$status"
assert_eq 'changed file total' 1 "$(printf '%s\n' "$output" | grep -c '^Total: 1 findings$')"
# New fixtures follow the original repo-wide count checks.
printf 'The file is\nready now.\n' > "$fixture/docs/span.md"
cat > "$fixture/docs/header.md" <<'MD'
Read this file.

Keep this line.

Keep this other line.

Read that file.
MD
unicode_path=$(printf 'docs/caf\303\251 notes.md')
printf 'Read this file.\n' > "$fixture/$unicode_path"
printf 'Read this file.\n\nUse simply this file.\n' > "$fixture/docs/deletion.md"
for file in docs/span.md docs/header.md "$unicode_path" docs/deletion.md; do
  track "$fixture/$file"
done
commit_fixture
base=$(git -C "$fixture" rev-parse HEAD)
printf 'The file is\nwritten now.\n' > "$fixture/docs/span.md"
cat > "$fixture/docs/header.md" <<'MD'
Read this file.
++ b/docs/other.md

Keep this line.

Keep this other line.

Read that file.
Use simply this file.
MD
printf 'Read this file.\n\nUse simply this file.\n' > "$fixture/$unicode_path"
printf 'Read this file.\n' > "$fixture/docs/deletion.md"
for file in docs/span.md docs/header.md "$unicode_path" docs/deletion.md; do
  track "$fixture/$file"
done
commit_fixture
status=0
output=$(lint --base "$base" --strict docs/span.md) || status=$?
assert_eq 'multiline passive strict exit' 1 "$status"
assert_eq 'multiline passive first line' 1 "$(printf '%s\n' "$output" | grep -c '^docs/span.md:1: passive-voice:')"
printf 'docs/span.md:2\n' > "$fixture/changed"
status=0
output=$(lint --changed "$fixture/changed" --strict docs/span.md) || status=$?
assert_eq 'multiline changed exit' 1 "$status"
status=0
output=$(lint --base "$base" --strict docs/header.md) || status=$?
assert_eq 'header-like addition exit' 1 "$status"
assert_eq 'header-like addition later hunk' 1 "$(printf '%s\n' "$output" | grep -c '^docs/header.md:9: banned-word:')"
status=0
output=$(lint --base "$base" --strict "$unicode_path") || status=$?
assert_eq 'space and unicode path exit' 1 "$status"
assert_eq 'space and unicode path finding' 1 "$(printf '%s\n' "$output" | grep -Fc "$unicode_path:3: banned-word:")"
status=0
output=$(lint --base "$base" --strict docs/deletion.md) || status=$?
assert_eq 'deletion-only exit' 0 "$status"
assert_eq 'deletion-only total' 'Total: 0 findings' "$(printf '%s\n' "$output" | grep '^Total:')"
status=0
output=$(lint --base HEAD --strict) || status=$?
assert_eq 'no changed files exit' 0 "$status"
assert_eq 'no changed files total' 'Total: 0 findings' "$(printf '%s\n' "$output" | grep '^Total:')"
assert_eq 'no changed files fast path' '0 findings on unchanged lines, not checked' "$(printf '%s\n' "$output" | grep 'not checked$')"
cat > "$fixture/docs/words.md" <<'MD'
Adjust the file.

A just-in-time step.

Use just this.
MD
cat > "$fixture/docs/passive.md" <<'MD'
The file is also written by the tool.

The file is set up by the tool.
MD
cat > "$fixture/docs/table.md" <<'MD'
| Description |
| --- |
| Read one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty twentyone twentytwo twentythree twentyfour twentyfive. |
MD
for file in docs/words.md docs/passive.md docs/table.md; do
  track "$fixture/$file"
done
output=$(lint docs/words.md)
assert_eq 'whole-word banned count' 1 "$(printf '%s\n' "$output" | grep -c ': banned-word:')"
assert_eq 'whole-word banned line' 1 "$(printf '%s\n' "$output" | grep -c '^docs/words.md:5: banned-word:')"
output=$(lint docs/passive.md)
assert_eq 'adverb passive' 1 "$(printf '%s\n' "$output" | grep -c '^docs/passive.md:1: passive-voice:')"
assert_eq 'approved passive phrase' 0 "$(printf '%s\n' "$output" | grep -c '^docs/passive.md:3: passive-voice:')"
output=$(lint docs/table.md)
assert_eq 'table sentence line' 1 "$(printf '%s\n' "$output" | grep -c '^docs/table.md:3: sentence-length:')"
echo "Passed: $PASS"
echo "Failed: $FAIL"
[ "$FAIL" -eq 0 ]
