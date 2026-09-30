#!/bin/bash
# Tests for bin/record-origin-verified-public.sh (#1477 / AgDR-0190 / #1508).
# Uses a stubbed `gh` on PATH. No network.
# SCRIPT_UNDER_TEST may point at an unfixed copy for fail-before checks.

set -u

ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
SCRIPT="${SCRIPT_UNDER_TEST:-$ROOT/bin/record-origin-verified-public.sh}"

PASS=0
FAIL=0

pass() { printf '  ok   %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL %s: %s\n' "$1" "$2" >&2; FAIL=$((FAIL + 1)); }

# Temp repo outside the worktree. Named GIT_DIR avoids sandboxes that block
# a literal `.git` directory. GIT_CEILING_DIRECTORIES stops a failed init
# from walking into a parent repo. Stop the suite if init fails.
make_repo() {
  local sandbox origin_url
  sandbox=$(mktemp -d) || exit 1
  origin_url=${1:-https://github.com/acme/public-ops.git}
  (
    export GIT_CEILING_DIRECTORIES="$sandbox"
    cd "$sandbox" || exit 1
    export GIT_DIR="$sandbox/gitdir"
    export GIT_WORK_TREE="$sandbox"
    mkdir -p "$GIT_DIR"
    if ! git init -q; then
      printf 'make_repo: git init failed in %s\n' "$sandbox" >&2
      exit 1
    fi
    if [ ! -d "$GIT_DIR" ]; then
      printf 'make_repo: git init produced no gitdir in %s\n' "$sandbox" >&2
      exit 1
    fi
    git config user.email test@example.com
    git config user.name Test
    printf 'x\n' > README.md
    git add README.md
    git commit -q -m baseline
    git remote add origin "$origin_url"
  ) || {
    rm -rf "$sandbox"
    exit 1
  }
  printf '%s\n' "$sandbox"
}

# Run the helper with GIT_DIR/GIT_WORK_TREE so the named gitdir is visible.
run_helper() {
  local sandbox="$1"
  shift
  (
    export GIT_CEILING_DIRECTORIES="$sandbox"
    export GIT_DIR="$sandbox/gitdir"
    export GIT_WORK_TREE="$sandbox"
    cd "$sandbox" || exit 1
    bash "$SCRIPT" --repo-dir "$sandbox" "$@"
  )
}

install_stub_gh() {
  local sandbox="$1" visibility="$2" fail_mode="${3:-}"
  mkdir -p "$sandbox/bin"
  cat > "$sandbox/bin/gh" <<SH
#!/bin/sh
if [ "$fail_mode" = "fail" ]; then
  echo "gh: simulated failure" >&2
  exit 1
fi
if [ "\$1" = "repo" ] && [ "\$2" = "view" ]; then
  printf '%s\\n' '{"visibility":"$visibility","isFork":false}'
  exit 0
fi
echo "unexpected gh args: \$*" >&2
exit 2
SH
  chmod +x "$sandbox/bin/gh"
}

# PATH with jq and git, but no gh (for #1508 missing-gh cases).
path_without_gh() {
  local bindir git_bin jq_bin
  bindir=$(mktemp -d) || exit 1
  jq_bin=$(command -v jq) || {
    printf 'path_without_gh: jq is required on the host PATH\n' >&2
    exit 1
  }
  git_bin=$(command -v git) || {
    printf 'path_without_gh: git is required on the host PATH\n' >&2
    exit 1
  }
  ln -s "$jq_bin" "$bindir/jq"
  ln -s "$git_bin" "$bindir/git"
  printf '%s\n' "$bindir:/usr/bin:/bin"
}

echo '== record-origin-verified-public.sh =='

sandbox=$(make_repo)
install_stub_gh "$sandbox" PUBLIC
out=$(PATH="$sandbox/bin:$PATH" run_helper "$sandbox" 2>&1)
rc=$?
if [ "$rc" -eq 0 ] \
  && printf '%s' "$out" | grep -qF 'origin_verified_public=acme/public-ops' \
  && [ "$(jq -r '.leak_protection.origin_verified_public' "$sandbox/.claude/project-config.json")" = "acme/public-ops" ]; then
  pass 'writes key when gh reports PUBLIC'
else
  fail 'writes key when gh reports PUBLIC' "rc=$rc out=$out"
fi
rm -rf "$sandbox"

sandbox=$(make_repo)
install_stub_gh "$sandbox" PRIVATE
out=$(PATH="$sandbox/bin:$PATH" run_helper "$sandbox" 2>&1)
rc=$?
if [ "$rc" -eq 1 ] \
  && printf '%s' "$out" | grep -qF 'Origin exemption is OFF' \
  && [ ! -f "$sandbox/.claude/project-config.json" ]; then
  pass 'writes nothing when gh reports PRIVATE'
else
  fail 'writes nothing when gh reports PRIVATE' "rc=$rc out=$out exists=$( [ -f "$sandbox/.claude/project-config.json" ] && echo yes || echo no )"
fi
rm -rf "$sandbox"

sandbox=$(make_repo)
install_stub_gh "$sandbox" PUBLIC fail
out=$(PATH="$sandbox/bin:$PATH" run_helper "$sandbox" 2>&1)
rc=$?
if [ "$rc" -eq 1 ] \
  && printf '%s' "$out" | grep -qF 'Origin exemption is OFF' \
  && [ ! -f "$sandbox/.claude/project-config.json" ]; then
  pass 'writes nothing when gh repo view fails'
else
  fail 'writes nothing when gh repo view fails' "rc=$rc out=$out"
fi
rm -rf "$sandbox"

# Preserve an existing unrelated override key when writing.
sandbox=$(make_repo)
install_stub_gh "$sandbox" PUBLIC
mkdir -p "$sandbox/.claude"
printf '%s\n' '{"tracker":{"kind":"gh"},"leak_protection":{"skip_marker":"<!-- x -->"}}' \
  > "$sandbox/.claude/project-config.json"
out=$(PATH="$sandbox/bin:$PATH" run_helper "$sandbox" 2>&1)
rc=$?
kind=$(jq -r '.tracker.kind' "$sandbox/.claude/project-config.json")
marker=$(jq -r '.leak_protection.skip_marker' "$sandbox/.claude/project-config.json")
slug=$(jq -r '.leak_protection.origin_verified_public' "$sandbox/.claude/project-config.json")
if [ "$rc" -eq 0 ] && [ "$kind" = "gh" ] && [ "$marker" = "<!-- x -->" ] \
  && [ "$slug" = "acme/public-ops" ]; then
  pass 'merges key without wiping other project-config fields'
else
  fail 'merges key without wiping other project-config fields' \
    "rc=$rc kind=$kind marker=$marker slug=$slug out=$out"
fi
rm -rf "$sandbox"

# An origin made private after an earlier PUBLIC proof loses the key.
sandbox=$(make_repo)
install_stub_gh "$sandbox" PRIVATE
mkdir -p "$sandbox/.claude"
printf '%s\n' '{"tracker":{"kind":"gh"},"leak_protection":{"origin_verified_public":"acme/public-ops","skip_marker":"<!-- x -->"}}' \
  > "$sandbox/.claude/project-config.json"
out=$(PATH="$sandbox/bin:$PATH" run_helper "$sandbox" 2>&1)
rc=$?
key=$(jq -r '.leak_protection.origin_verified_public // "absent"' "$sandbox/.claude/project-config.json")
marker=$(jq -r '.leak_protection.skip_marker' "$sandbox/.claude/project-config.json")
kind=$(jq -r '.tracker.kind' "$sandbox/.claude/project-config.json")
if [ "$rc" -eq 1 ] && [ "$key" = "absent" ] && [ "$marker" = "<!-- x -->" ] && [ "$kind" = "gh" ] \
  && printf '%s' "$out" | grep -qF 'Removed the earlier'; then
  pass 'removes an earlier key when gh now reports PRIVATE'
else
  fail 'removes an earlier key when gh now reports PRIVATE' "rc=$rc key=$key marker=$marker kind=$kind out=$out"
fi
rm -rf "$sandbox"

# A failed check keeps an earlier matching key (no evidence it changed).
sandbox=$(make_repo)
install_stub_gh "$sandbox" PUBLIC fail
mkdir -p "$sandbox/.claude"
printf '%s\n' '{"leak_protection":{"origin_verified_public":"acme/public-ops"}}' \
  > "$sandbox/.claude/project-config.json"
out=$(PATH="$sandbox/bin:$PATH" run_helper "$sandbox" 2>&1)
rc=$?
key=$(jq -r '.leak_protection.origin_verified_public // "absent"' "$sandbox/.claude/project-config.json")
if [ "$rc" -eq 1 ] && [ "$key" = "acme/public-ops" ] \
  && printf '%s' "$out" | grep -qF 'earlier proof for acme/public-ops stays'; then
  pass 'keeps an earlier matching key when gh repo view fails'
else
  fail 'keeps an earlier matching key when gh repo view fails' "rc=$rc key=$key out=$out"
fi
rm -rf "$sandbox"

# #1508 — no gh, matching earlier key: keep key and say the earlier proof stays.
sandbox=$(make_repo)
mkdir -p "$sandbox/.claude"
printf '%s\n' '{"leak_protection":{"origin_verified_public":"acme/public-ops"}}' \
  > "$sandbox/.claude/project-config.json"
no_gh_path=$(path_without_gh)
out=$(PATH="$no_gh_path" run_helper "$sandbox" 2>&1)
rc=$?
key=$(jq -r '.leak_protection.origin_verified_public // "absent"' "$sandbox/.claude/project-config.json")
no_gh_bindir=${no_gh_path%%:*}
if [ "$rc" -eq 1 ] && [ "$key" = "acme/public-ops" ] \
  && printf '%s' "$out" | grep -qF 'earlier proof for acme/public-ops stays' \
  && ! printf '%s' "$out" | grep -qF 'Origin exemption is OFF'; then
  pass 'keeps matching key and says earlier proof stays when gh is missing'
else
  fail 'keeps matching key and says earlier proof stays when gh is missing' \
    "rc=$rc key=$key out=$out"
fi
rm -rf "$sandbox" "$no_gh_bindir"

# #1508 — no gh, no key: OFF message unchanged.
sandbox=$(make_repo)
no_gh_path=$(path_without_gh)
out=$(PATH="$no_gh_path" run_helper "$sandbox" 2>&1)
rc=$?
no_gh_bindir=${no_gh_path%%:*}
if [ "$rc" -eq 1 ] \
  && printf '%s' "$out" | grep -qF 'Origin exemption is OFF for acme/public-ops: gh is not on PATH' \
  && ! printf '%s' "$out" | grep -qF 'earlier proof' \
  && [ ! -f "$sandbox/.claude/project-config.json" ]; then
  pass 'unchanged OFF message when gh is missing and no key exists'
else
  fail 'unchanged OFF message when gh is missing and no key exists' "rc=$rc out=$out"
fi
rm -rf "$sandbox" "$no_gh_bindir"

printf 'Passed: %s  Failed: %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
