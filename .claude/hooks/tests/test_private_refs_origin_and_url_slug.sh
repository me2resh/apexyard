#!/bin/bash
# Regression coverage for #1477:
#   1. Origin identity exemptions require offline proof that origin is
#      public or a fork of a public repo (staged + runtime, in parity).
#   2. The staged hook treats `/` as a slug boundary so URL / path /
#      markdown forms of a private slug block (parity with runtime and
#      the public-repo hook from #1407 / #1476).
#
# Override STAGED_HOOK_SOURCE / RUNTIME_HOOK_SOURCE to point at unfixed
# copies when proving fail-before outside this suite. Do not assert
# fail-before inside this shipped file.
#
# URL-form cases deliberately use a registry name that is NOT the bare
# repo name. Otherwise the name matcher masks the slash-boundary bug.

set -u

# Isolate from live Claude Code session pin/cache (me2resh/apexyard#1549).
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"


ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
STAGED_HOOK_SOURCE=${STAGED_HOOK_SOURCE:-$ROOT/.claude/hooks/check-private-refs-staged.sh}
RUNTIME_HOOK_SOURCE=${RUNTIME_HOOK_SOURCE:-$ROOT/.claude/hooks/check-private-refs-runtime.sh}
PARSER_SOURCE="$ROOT/.claude/hooks/_lib-registry-parser.sh"
CONFIG_SOURCE="$ROOT/.claude/hooks/_lib-read-config.sh"

PASS=0
FAIL=0

pass() { printf '  ok   %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL %s: %s\n' "$1" "$2" >&2; FAIL=$((FAIL + 1)); }

# Copy the real config library so public_framework_repos and
# origin_verified_public paths exercise config_get (A1 / #1477).
# _config_load returns {} and skips overrides when defaults are absent,
# so ensure a defaults file exists (minimal leak_protection object).
install_config_lib() {
  local sandbox="$1"
  cp "$CONFIG_SOURCE" "$sandbox/.claude/hooks/_lib-read-config.sh"
  if [ ! -f "$sandbox/.claude/project-config.defaults.json" ]; then
    printf '%s\n' '{"leak_protection":{}}' \
      > "$sandbox/.claude/project-config.defaults.json"
  fi
}

write_defaults() {
  local sandbox="$1" json="$2"
  printf '%s\n' "$json" > "$sandbox/.claude/project-config.defaults.json"
}

write_override() {
  local sandbox="$1" json="$2"
  printf '%s\n' "$json" > "$sandbox/.claude/project-config.json"
}

make_sandbox() {
  local registry_yaml="$1" origin_url="$2" upstream_url="${3:-}"
  local sandbox
  sandbox=$(mktemp -d) || exit 1
  mkdir -p "$sandbox/.claude/hooks"
  cp "$STAGED_HOOK_SOURCE" "$sandbox/.claude/hooks/check-private-refs-staged.sh"
  cp "$RUNTIME_HOOK_SOURCE" "$sandbox/.claude/hooks/check-private-refs-runtime.sh"
  cp "$PARSER_SOURCE" "$sandbox/.claude/hooks/_lib-registry-parser.sh"
  chmod +x "$sandbox/.claude/hooks/check-private-refs-staged.sh" \
    "$sandbox/.claude/hooks/check-private-refs-runtime.sh"
  printf '%s\n' "$registry_yaml" > "$sandbox/apexyard.projects.yaml"
  (
    cd "$sandbox" || exit 1
    git init -q
    git config user.email test@example.com
    git config user.name Test
    git add apexyard.projects.yaml
    git commit -q -m baseline
    git remote add origin "$origin_url"
    if [ -n "$upstream_url" ]; then
      git remote add upstream "$upstream_url"
    fi
  )
  printf '%s\n' "$sandbox"
}

assert_staged() {
  local label="$1" sandbox="$2" expected_rc="$3" expected_text="$4" forbidden_text="$5"
  local output rc
  output=$(cd "$sandbox" && /bin/bash .claude/hooks/check-private-refs-staged.sh 2>&1)
  rc=$?
  if [ "$rc" -ne "$expected_rc" ]; then
    fail "$label" "expected exit $expected_rc, got $rc: $output"
  elif [ -n "$expected_text" ] && ! printf '%s' "$output" | grep -qF -- "$expected_text"; then
    fail "$label" "missing diagnostic: $expected_text"
  elif [ -n "$forbidden_text" ] && printf '%s' "$output" | grep -qF -- "$forbidden_text"; then
    fail "$label" "diagnostic disclosed private identifier"
  elif [ "$expected_rc" -eq 0 ] && [ -n "$output" ]; then
    fail "$label" "expected empty stdout/stderr on success, got: $output"
  else
    pass "$label"
  fi
}

assert_runtime() {
  local label="$1" sandbox="$2" target="$3" body="$4" expected_rc="$5"
  local output rc
  output=$(cd "$sandbox" && /bin/bash .claude/hooks/check-private-refs-runtime.sh \
    "$target" "$body" '' 2>&1)
  rc=$?
  if [ "$rc" -ne "$expected_rc" ]; then
    fail "$label" "expected exit $expected_rc, got $rc: $output"
  elif [ "$expected_rc" -eq 0 ] && [ -n "$output" ]; then
    fail "$label" "expected empty stdout/stderr on success, got: $output"
  elif [ "$expected_rc" -ne 0 ] \
    && printf '%s' "$output" | grep -qE 'private-org|ops-private|shadow-ops|lantern-app|atlas-fork'; then
    fail "$label" "diagnostic disclosed private identifier"
  else
    pass "$label"
  fi
}

# Name differs from the bare repo name so URL cases exercise the REPO
# matcher, not the NAME matcher.
SLUG_REGISTRY='projects:
  - name: lantern-app
    repo: private-org/ops-private
    workspace: workspace/ops-private
  - name: shadow-ops
    repo: private-org/shadow-ops
    workspace: workspace/shadow-ops
'
# Name equals the origin bare repo name (ops-private).
ORIGIN_NAME_REGISTRY='projects:
  - name: ops-private
    repo: private-org/ops-private
    workspace: workspace/ops-private
'
# Name equals the origin owner login (private-org).
ORIGIN_OWNER_REGISTRY='projects:
  - name: private-org
    repo: other-org/unrelated-tool
    workspace: workspace/unrelated-tool
'
PRIVATE_ORIGIN_URL='https://github.com/private-org/ops-private.git'
UNRELATED_ORIGIN_URL='https://github.com/other-org/other-ops.git'
PUBLIC_UPSTREAM_URL='https://github.com/me2resh/apexyard.git'
PUBLIC_TARGET='me2resh/apexyard'

echo '== #1477 private origin must not exempt its own identity =='

sandbox=$(make_sandbox "$SLUG_REGISTRY" "$PRIVATE_ORIGIN_URL")
printf 'See private-org/ops-private#9.\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
assert_staged 'staged: private origin slug blocks' "$sandbox" 2 'File: notes.md' 'private-org/ops-private'
assert_runtime 'runtime: private origin slug blocks' "$sandbox" "$PUBLIC_TARGET" \
  'See private-org/ops-private#9.' 2
rm -rf "$sandbox"

sandbox=$(make_sandbox "$ORIGIN_NAME_REGISTRY" "$PRIVATE_ORIGIN_URL")
printf 'The ops-private service needs a rename.\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
assert_staged 'staged: private origin bare name blocks' "$sandbox" 2 'File: notes.md' 'ops-private'
assert_runtime 'runtime: private origin bare name blocks' "$sandbox" "$PUBLIC_TARGET" \
  'The ops-private service needs a rename.' 2
rm -rf "$sandbox"

sandbox=$(make_sandbox "$ORIGIN_OWNER_REGISTRY" "$PRIVATE_ORIGIN_URL")
printf 'Filed against private-org/ops-private directly.\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
assert_staged 'staged: private origin owner/repo form blocks' "$sandbox" 2 'File: notes.md' 'private-org'
assert_runtime 'runtime: private origin owner/repo form blocks' "$sandbox" "$PUBLIC_TARGET" \
  'Filed against private-org/ops-private directly.' 2
rm -rf "$sandbox"

echo '== #1477 public upstream alone does NOT prove origin public =='

sandbox=$(make_sandbox "$SLUG_REGISTRY" "$PRIVATE_ORIGIN_URL" "$PUBLIC_UPSTREAM_URL")
printf 'See private-org/ops-private#9.\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
assert_staged 'staged: private origin slug blocks despite public upstream' \
  "$sandbox" 2 'File: notes.md' 'private-org/ops-private'
assert_runtime 'runtime: private origin slug blocks despite public upstream' \
  "$sandbox" "$PUBLIC_TARGET" 'See private-org/ops-private#9.' 2
rm -rf "$sandbox"

sandbox=$(make_sandbox "$ORIGIN_OWNER_REGISTRY" "$PRIVATE_ORIGIN_URL" "$PUBLIC_UPSTREAM_URL")
printf 'Filed against private-org/ops-private directly.\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
assert_staged 'staged: private origin owner/repo blocks despite public upstream' \
  "$sandbox" 2 'File: notes.md' 'private-org'
assert_runtime 'runtime: private origin owner/repo blocks despite public upstream' \
  "$sandbox" "$PUBLIC_TARGET" 'Filed against private-org/ops-private directly.' 2
rm -rf "$sandbox"

sandbox=$(make_sandbox "$SLUG_REGISTRY" "$PRIVATE_ORIGIN_URL" "$PUBLIC_UPSTREAM_URL")
printf 'See private-org/shadow-ops#2.\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
assert_staged 'staged: unrelated private slug still blocks under public upstream' \
  "$sandbox" 2 'File: notes.md' 'shadow-ops'
assert_runtime 'runtime: unrelated private slug still blocks under public upstream' \
  "$sandbox" "$PUBLIC_TARGET" 'See private-org/shadow-ops#2.' 2
rm -rf "$sandbox"

echo '== #1477 origin_verified_public exact match is offline proof =='

sandbox=$(make_sandbox "$SLUG_REGISTRY" "$PRIVATE_ORIGIN_URL" "$PUBLIC_UPSTREAM_URL")
install_config_lib "$sandbox"
write_override "$sandbox" \
  '{"leak_protection":{"origin_verified_public":"private-org/ops-private"}}'
printf 'See private-org/ops-private#9.\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
assert_staged 'staged: origin slug exempt when verified-public key matches' \
  "$sandbox" 0 '' ''
assert_runtime 'runtime: origin slug exempt when verified-public key matches' \
  "$sandbox" "$PUBLIC_TARGET" 'See private-org/ops-private#9.' 0
rm -rf "$sandbox"

sandbox=$(make_sandbox "$ORIGIN_OWNER_REGISTRY" "$PRIVATE_ORIGIN_URL" "$PUBLIC_UPSTREAM_URL")
install_config_lib "$sandbox"
write_override "$sandbox" \
  '{"leak_protection":{"origin_verified_public":"private-org/ops-private"}}'
printf 'Filed against private-org/ops-private directly.\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
assert_staged 'staged: origin owner/repo exempt when verified-public key matches' \
  "$sandbox" 0 '' ''
assert_runtime 'runtime: origin owner/repo exempt when verified-public key matches' \
  "$sandbox" "$PUBLIC_TARGET" 'Filed against private-org/ops-private directly.' 0
rm -rf "$sandbox"

sandbox=$(make_sandbox "$SLUG_REGISTRY" "$PRIVATE_ORIGIN_URL" "$PUBLIC_UPSTREAM_URL")
install_config_lib "$sandbox"
write_override "$sandbox" \
  '{"leak_protection":{"origin_verified_public":"other-org/other-ops"}}'
printf 'See private-org/ops-private#9.\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
assert_staged 'staged: mismatched verified-public key does not exempt origin' \
  "$sandbox" 2 'File: notes.md' 'private-org/ops-private'
assert_runtime 'runtime: mismatched verified-public key does not exempt origin' \
  "$sandbox" "$PUBLIC_TARGET" 'See private-org/ops-private#9.' 2
rm -rf "$sandbox"

echo '== #1477 A1: real config library + custom public_framework_repos =='

CUSTOM_ORIGIN_URL='https://github.com/acme/public-ops.git'
CUSTOM_REGISTRY='projects:
  - name: public-ops
    repo: acme/public-ops
    workspace: workspace/public-ops
  - name: shadow-ops
    repo: private-org/shadow-ops
    workspace: workspace/shadow-ops
'
sandbox=$(make_sandbox "$CUSTOM_REGISTRY" "$CUSTOM_ORIGIN_URL")
install_config_lib "$sandbox"
write_defaults "$sandbox" \
  '{"leak_protection":{"public_framework_repos":["acme/public-ops"]}}'
printf 'See acme/public-ops#4.\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
assert_staged 'staged: origin exempt via custom public_framework_repos (real config_get)' \
  "$sandbox" 0 '' ''
assert_runtime 'runtime: origin exempt via custom public_framework_repos (real config_get)' \
  "$sandbox" 'acme/public-ops' 'See acme/public-ops#4.' 0
rm -rf "$sandbox"

sandbox=$(make_sandbox "$CUSTOM_REGISTRY" "$CUSTOM_ORIGIN_URL")
install_config_lib "$sandbox"
write_defaults "$sandbox" \
  '{"leak_protection":{"public_framework_repos":["acme/public-ops"]}}'
printf 'See private-org/shadow-ops#2.\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
assert_staged 'staged: custom public list still blocks unrelated private slug' \
  "$sandbox" 2 'File: notes.md' 'shadow-ops'
assert_runtime 'runtime: custom public list still blocks unrelated private slug' \
  "$sandbox" 'acme/public-ops' 'See private-org/shadow-ops#2.' 2
rm -rf "$sandbox"

echo '== #1477 staged hook blocks private slugs inside URL forms =='

sandbox=$(make_sandbox "$SLUG_REGISTRY" "$UNRELATED_ORIGIN_URL")
printf 'See https://github.com/private-org/ops-private\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
assert_staged 'staged: GitHub URL contains a private slug' "$sandbox" 2 'File: notes.md' 'ops-private'
assert_runtime 'runtime: GitHub URL contains a private slug' "$sandbox" "$PUBLIC_TARGET" \
  'See https://github.com/private-org/ops-private' 2
rm -rf "$sandbox"

sandbox=$(make_sandbox "$SLUG_REGISTRY" "$UNRELATED_ORIGIN_URL")
printf 'See https://github.com/private-org/ops-private/issues/3\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
assert_staged 'staged: issue URL contains a private slug' "$sandbox" 2 'File: notes.md' 'ops-private'
assert_runtime 'runtime: issue URL contains a private slug' "$sandbox" "$PUBLIC_TARGET" \
  'See https://github.com/private-org/ops-private/issues/3' 2
rm -rf "$sandbox"

sandbox=$(make_sandbox "$SLUG_REGISTRY" "$UNRELATED_ORIGIN_URL")
printf 'See private-org/ops-private/issues/3\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
assert_staged 'staged: path contains a private slug' "$sandbox" 2 'File: notes.md' 'ops-private'
assert_runtime 'runtime: path contains a private slug' "$sandbox" "$PUBLIC_TARGET" \
  'See private-org/ops-private/issues/3' 2
rm -rf "$sandbox"

sandbox=$(make_sandbox "$SLUG_REGISTRY" "$UNRELATED_ORIGIN_URL")
printf 'See [details](https://github.com/private-org/ops-private)\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
assert_staged 'staged: markdown link contains a private slug' "$sandbox" 2 'File: notes.md' 'ops-private'
assert_runtime 'runtime: markdown link contains a private slug' "$sandbox" "$PUBLIC_TARGET" \
  'See [details](https://github.com/private-org/ops-private)' 2
rm -rf "$sandbox"

echo '== #1477 registry public:true on origin also proves public =='

# Origin slug is public:true. A separate private entry reuses the origin
# owner login as its project name. Only origin_identity_exempt (via the
# public:true proof) applies the narrow owner/repo strip. Without that
# proof the private name match blocks the owner/repo form.
PUBLIC_ORIGIN_REGISTRY='projects:
  - name: private-org
    repo: other-org/unrelated-tool
    workspace: workspace/unrelated-tool
  - name: marketing-site
    repo: private-org/ops-private
    workspace: workspace/ops-private
    public: true
  - name: shadow-ops
    repo: private-org/shadow-ops
    workspace: workspace/shadow-ops
'
sandbox=$(make_sandbox "$PUBLIC_ORIGIN_REGISTRY" "$PRIVATE_ORIGIN_URL")
printf 'Filed against private-org/ops-private directly.\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
assert_staged 'staged: origin owner/repo exempt via registry public:true proof' \
  "$sandbox" 0 '' ''
assert_runtime 'runtime: origin owner/repo exempt via registry public:true proof' \
  "$sandbox" "$PUBLIC_TARGET" 'Filed against private-org/ops-private directly.' 0
rm -rf "$sandbox"

sandbox=$(make_sandbox "$PUBLIC_ORIGIN_REGISTRY" "$PRIVATE_ORIGIN_URL")
printf 'See private-org/shadow-ops#2.\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
assert_staged 'staged: private sibling still blocks when origin is public:true' \
  "$sandbox" 2 'File: notes.md' 'shadow-ops'
assert_runtime 'runtime: private sibling still blocks when origin is public:true' \
  "$sandbox" "$PUBLIC_TARGET" 'See private-org/shadow-ops#2.' 2
rm -rf "$sandbox"

printf 'Passed: %s  Failed: %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
