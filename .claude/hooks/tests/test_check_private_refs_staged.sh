#!/bin/bash
# Regression tests for the Git-native staged private-reference gate (#1218).

set -u

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HOOK_SRC="$ROOT/.claude/hooks/check-private-refs-staged.sh"
RUNTIME_SRC="$ROOT/.claude/hooks/check-private-refs-runtime.sh"
PARSER_LIB_SRC="$ROOT/.claude/hooks/_lib-registry-parser.sh"
PRE_COMMIT_SRC="$ROOT/.githooks/pre-commit"

PASS=0
FAIL=0

pass() { printf '  ok   %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL %s: %s\n' "$1" "$2" >&2; FAIL=$((FAIL + 1)); }

make_sandbox() {
  local sandbox
  sandbox=$(mktemp -d)
  mkdir -p "$sandbox/.claude/hooks" "$sandbox/.githooks"
  cp "$HOOK_SRC" "$sandbox/.claude/hooks/check-private-refs-staged.sh"
  cp "$RUNTIME_SRC" "$sandbox/.claude/hooks/check-private-refs-runtime.sh"
  cp "$PRE_COMMIT_SRC" "$sandbox/.githooks/pre-commit"
  cp "$PARSER_LIB_SRC" "$sandbox/.claude/hooks/_lib-registry-parser.sh"
  chmod +x "$sandbox/.claude/hooks/check-private-refs-staged.sh" "$sandbox/.claude/hooks/check-private-refs-runtime.sh" "$sandbox/.githooks/pre-commit"
  cat > "$sandbox/apexyard.projects.yaml" <<'YAML'
projects:
  - name: amber-lantern
    repo: acme/amber-lantern
    workspace: workspace/amber-lantern
YAML
  (
    cd "$sandbox" || exit 1
    git init -q
    git config user.email test@example.com
    git config user.name Test
    git add apexyard.projects.yaml
    git commit -q -m baseline
  )
  printf '%s\n' "$sandbox"
}

run_hook() {
  local sandbox="$1"; shift
  local out rc
  out=$(cd "$sandbox" && "$HOOK_SRC" 2>&1); rc=$?
  printf '%s\n%s\n' "$rc" "$out"
}

assert_hook() {
  local label="$1" sandbox="$2" expected_rc="$3" expected_text="$4" forbidden_text="$5"
  local result rc output
  result=$(run_hook "$sandbox")
  rc=$(printf '%s\n' "$result" | head -1)
  output=$(printf '%s\n' "$result" | sed '1d')
  if [ "$rc" != "$expected_rc" ]; then
    fail "$label" "expected exit $expected_rc, got $rc: $output"
  elif [ -n "$expected_text" ] && ! printf '%s' "$output" | grep -qF -- "$expected_text"; then
    fail "$label" "missing diagnostic: $expected_text"
  elif [ -n "$forbidden_text" ] && printf '%s' "$output" | grep -qF -- "$forbidden_text"; then
    fail "$label" "diagnostic disclosed private identifier"
  else
    pass "$label"
  fi
}

echo "== Staged private-reference gate (#1218)"

sandbox=$(make_sandbox)
printf 'Private reference: amber-lantern\n' > "$sandbox/leak.md"
git -C "$sandbox" add leak.md
assert_hook "staged project name blocks without disclosing token" "$sandbox" 2 "File: leak.md" "amber-lantern"
rm -rf "$sandbox"

sandbox=$(make_sandbox)
printf 'Reference: acme/amber-lantern#42\n' > "$sandbox/repo.md"
git -C "$sandbox" add repo.md
assert_hook "staged repository slug blocks" "$sandbox" 2 "File: repo.md" "acme/amber-lantern"
rm -rf "$sandbox"

sandbox=$(make_sandbox)
printf 'Path: workspace/amber-lantern/src\n' > "$sandbox/path.md"
git -C "$sandbox" add path.md
assert_hook "staged workspace path blocks" "$sandbox" 2 "File: path.md" "workspace/amber-lantern"
rm -rf "$sandbox"

sandbox=$(make_sandbox)
printf 'The generic workspace term is safe.\n' > "$sandbox/clean.md"
git -C "$sandbox" add clean.md
assert_hook "generic workspace word remains allowed" "$sandbox" 0 "" ""
rm -rf "$sandbox"

sandbox=$(make_sandbox)
printf 'Private reference: amber-lantern\n' > "$sandbox/history.md"
git -C "$sandbox" add history.md
assert_hook "first add blocks before a later removal can hide it" "$sandbox" 2 "File: history.md" "amber-lantern"
git -C "$sandbox" restore --staged history.md
printf 'Private reference removed.\n' > "$sandbox/history.md"
git -C "$sandbox" add history.md
assert_hook "clean replacement is evaluated from its staged blob" "$sandbox" 0 "" ""
rm -rf "$sandbox"

sandbox=$(make_sandbox)
printf 'Private reference: amber-lantern\n' > "$sandbox/working-only.md"
assert_hook "unstaged content does not block a different staged commit" "$sandbox" 0 "" ""
rm -rf "$sandbox"

sandbox=$(make_sandbox)
git -C "$sandbox" config core.hooksPath .githooks
printf 'Private reference: amber-lantern\n' > "$sandbox/commit.md"
git -C "$sandbox" add commit.md
commit_output=$(git -C "$sandbox" commit -m 'test private reference' 2>&1); commit_rc=$?
if [ "$commit_rc" = "0" ]; then
  fail "installed pre-commit hook blocks the commit" "commit unexpectedly succeeded"
elif printf '%s' "$commit_output" | grep -qF 'File: commit.md' && ! printf '%s' "$commit_output" | grep -qF 'amber-lantern'; then
  pass "installed pre-commit hook blocks the commit"
else
  fail "installed pre-commit hook blocks the commit" "$commit_output"
fi
rm -rf "$sandbox"

sandbox=$(make_sandbox)
resolved_repo="me2resh/apexyard"
runtime_output=$(cd "$sandbox" && .claude/hooks/check-private-refs-runtime.sh "$resolved_repo" 'Reviewed amber-lantern' '' 2>&1); runtime_rc=$?
if [ "$runtime_rc" = "2" ] && ! printf '%s' "$runtime_output" | grep -qF 'amber-lantern'; then
  pass "resolved wrapper values block without disclosing token"
else
  fail "resolved wrapper values block without disclosing token" "$runtime_output"
fi
rm -rf "$sandbox"

sandbox=$(make_sandbox)
printf '%s\n' 'projects:' '  - name: amber-secondary' '    repos:' '      - acme/amber-primary' '      - acme/amber-secondary' '    workspace: workspace/amber-secondary' > "$sandbox/apexyard.projects.yaml"
runtime_output=$(cd "$sandbox" && .claude/hooks/check-private-refs-runtime.sh "$resolved_repo" 'Reviewed acme/amber-secondary#7' '' 2>&1); runtime_rc=$?
if [ "$runtime_rc" = "2" ] && ! printf '%s' "$runtime_output" | grep -qF 'acme/amber-secondary'; then
  pass "plural repos entries block secondary repository references"
else
  fail "plural repos entries block secondary repository references" "$runtime_output"
fi
rm -rf "$sandbox"

echo
echo "== Upstream owner/repo exemption (#1431)"
#
# An ops fork's `origin` remote is the fork itself. The public framework
# lives at the `upstream` remote. The hook used to exempt only a registered
# name or repo slug equal to `origin`'s bare name or slug, so a registry
# that lists the framework repo itself, or a registered project whose name
# equals the upstream owner login, blocked the ordinary
# `<upstream-owner>/<repo>#N` issue-reference form. All fixture names below
# are SYNTHETIC.

# make_sandbox_with_remotes REGISTRY_YAML ORIGIN_URL [UPSTREAM_URL] — like
# make_sandbox, but takes the registry content and configures the given
# remotes (upstream is optional, matching a fork with none configured).
make_sandbox_with_remotes() {
  local registry_yaml="$1" origin_url="$2" upstream_url="${3:-}"
  local sandbox
  sandbox=$(mktemp -d)
  mkdir -p "$sandbox/.claude/hooks" "$sandbox/.githooks"
  cp "$HOOK_SRC" "$sandbox/.claude/hooks/check-private-refs-staged.sh"
  cp "$RUNTIME_SRC" "$sandbox/.claude/hooks/check-private-refs-runtime.sh"
  cp "$PRE_COMMIT_SRC" "$sandbox/.githooks/pre-commit"
  cp "$PARSER_LIB_SRC" "$sandbox/.claude/hooks/_lib-registry-parser.sh"
  chmod +x "$sandbox/.claude/hooks/check-private-refs-staged.sh" "$sandbox/.claude/hooks/check-private-refs-runtime.sh" "$sandbox/.githooks/pre-commit"
  printf '%s' "$registry_yaml" > "$sandbox/apexyard.projects.yaml"
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

# "acme-framework" collides with the synthetic upstream owner login.
# "framework" is that upstream's own bare repo name, registered by its slug
# ("acme-framework/framework") — the "registry lists the framework repo
# itself" case the issue names. "secret-app" is an ordinary unrelated
# private project that must keep blocking throughout.
UPSTREAM_REGISTRY_YAML='projects:
  - name: acme-framework
    repo: acme-org/acme-framework-app
    workspace: workspace/acme-framework-app
  - name: framework
    repo: acme-framework/framework
    workspace: workspace/framework-mirror
  - name: secret-app
    repo: acme-org/secret-app
    workspace: workspace/secret-app
'
FORK_ORIGIN_URL="https://github.com/atlas-fork/ops-fork.git"
FRAMEWORK_UPSTREAM_URL="https://github.com/acme-framework/framework.git"

# 1. The exact repro: an upstream issue cited as <owner>/<repo>#N. Exercises
#    the owner-login name exemption and the upstream repo-slug exemption
#    together (the registered "framework" project's repo IS the upstream
#    slug).
sandbox=$(make_sandbox_with_remotes "$UPSTREAM_REGISTRY_YAML" "$FORK_ORIGIN_URL" "$FRAMEWORK_UPSTREAM_URL")
printf 'See acme-framework/framework#12 for the same root cause.\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
assert_hook "upstream owner/repo#N reference does not block" "$sandbox" 0 "" ""
rm -rf "$sandbox"

# 2. A bare, standalone mention of the upstream owner login must still
#    block, exactly like any other registered private project's name.
sandbox=$(make_sandbox_with_remotes "$UPSTREAM_REGISTRY_YAML" "$FORK_ORIGIN_URL" "$FRAMEWORK_UPSTREAM_URL")
printf 'The acme-framework project needs a rename.\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
assert_hook "bare upstream-owner mention still blocks" "$sandbox" 2 "File: notes.md" "acme-framework"
rm -rf "$sandbox"

# 3. An unrelated registered private project's name must still block.
sandbox=$(make_sandbox_with_remotes "$UPSTREAM_REGISTRY_YAML" "$FORK_ORIGIN_URL" "$FRAMEWORK_UPSTREAM_URL")
printf 'Discovered while touching secret-app during the rebuild.\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
assert_hook "unrelated registered project name still blocks" "$sandbox" 2 "File: notes.md" "secret-app"
rm -rf "$sandbox"

# 4. With no upstream remote configured, today's (origin-only) behaviour
#    holds: the same owner/repo reference has no exemption to fall back on
#    and still blocks.
sandbox=$(make_sandbox_with_remotes "$UPSTREAM_REGISTRY_YAML" "$FORK_ORIGIN_URL")
printf 'See acme-framework/framework#12 for the same root cause.\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
assert_hook "no upstream remote keeps origin-only behaviour (still blocks)" "$sandbox" 2 "File: notes.md" "acme-framework"
rm -rf "$sandbox"

# 5. @-mentioning the upstream owner login (no slash, no repo name) is the
#    other safe form and must not block either.
sandbox=$(make_sandbox_with_remotes "$UPSTREAM_REGISTRY_YAML" "$FORK_ORIGIN_URL" "$FRAMEWORK_UPSTREAM_URL")
printf 'Thanks @acme-framework, filing the fix now.\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
assert_hook "@-mentioning the upstream owner login does not block" "$sandbox" 0 "" ""
rm -rf "$sandbox"

# 6. Regression guard — a hyphen-joined form of the owner login is NOT the
#    safe form and must still block, matching the narrow #1400 boundary
#    this fix ports.
sandbox=$(make_sandbox_with_remotes "$UPSTREAM_REGISTRY_YAML" "$FORK_ORIGIN_URL" "$FRAMEWORK_UPSTREAM_URL")
printf 'Ship the acme-framework-cli update first.\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
assert_hook "hyphen-joined owner-login form still blocks" "$sandbox" 2 "File: notes.md" "acme-framework"
rm -rf "$sandbox"

# 7. Regression guard — an owner-form mention alongside a genuine leak in
#    the same file must still catch the real leak. The owner exemption
#    skips only the owner's own name entry.
sandbox=$(make_sandbox_with_remotes "$UPSTREAM_REGISTRY_YAML" "$FORK_ORIGIN_URL" "$FRAMEWORK_UPSTREAM_URL")
printf 'Filed against acme-framework/framework; also seen in secret-app.\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
assert_hook "owner mention plus a real leak still blocks" "$sandbox" 2 "File: notes.md" "secret-app"
rm -rf "$sandbox"

# 8. Fail-before proof — the SAME case-1 content, run against the hook as it
#    existed at a PINNED pre-#1431 commit, must reproduce the bug (block).
#    Confirms this is a genuine fail→pass fix, not a pre-existing pass.
#
#    Pinned to a fixed SHA rather than `upstream/dev`'s moving tip — once
#    this PR merges, `upstream/dev` HOLDS the fix, and a case that reads
#    "the hook on upstream/dev" would then read the FIXED hook and fail
#    forever in any fork with an `upstream` remote configured (Rex, PR
#    #1432). PRE_1431_SHA is the commit at the tip of `upstream/dev` when
#    this fix branched from it — the last commit before any of #1431's
#    changes — so it always reads the unfixed hook, regardless of where
#    `upstream/dev` moves afterward.
PRE_1431_SHA="9e3b2d90e17b5816e35f8ed1db5e3c83535aab16"
sandbox=$(make_sandbox_with_remotes "$UPSTREAM_REGISTRY_YAML" "$FORK_ORIGIN_URL" "$FRAMEWORK_UPSTREAM_URL")
printf 'See acme-framework/framework#12 for the same root cause.\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
pre_fix_hook=$(mktemp)
if git -C "$ROOT" show "${PRE_1431_SHA}:.claude/hooks/check-private-refs-staged.sh" > "$pre_fix_hook" 2>/dev/null \
  && [ -s "$pre_fix_hook" ]; then
  chmod +x "$pre_fix_hook"
  cp "$pre_fix_hook" "$sandbox/.claude/hooks/check-private-refs-staged.sh"
  prefix_output=$(cd "$sandbox" && .claude/hooks/check-private-refs-staged.sh 2>&1); prefix_rc=$?
  if [ "$prefix_rc" = "2" ]; then
    pass "fail-before: the pre-#1431 hook ($PRE_1431_SHA) still blocks the owner/repo form"
  else
    fail "fail-before: the pre-#1431 hook ($PRE_1431_SHA) still blocks the owner/repo form" "expected exit 2, got $prefix_rc: $prefix_output"
  fi
else
  echo "  skip fail-before proof: could not read $PRE_1431_SHA's copy of the hook (not fetched in this clone)"
fi
rm -f "$pre_fix_hook"
rm -rf "$sandbox"

# 9. #1477 — a private, non-fork origin must NOT exempt its owner login.
#    Without upstream (and without origin in public_framework_repos), the
#    owner/repo form of origin's owner is a private reference and blocks.
#    A bare mention of that owner still blocks either way.
ORIGIN_OWNER_REGISTRY_YAML='projects:
  - name: atlas-fork
    repo: acme-org/atlas-fork-tool
    workspace: workspace/atlas-fork-tool
  - name: secret-app
    repo: acme-org/secret-app
    workspace: workspace/secret-app
'
sandbox=$(make_sandbox_with_remotes "$ORIGIN_OWNER_REGISTRY_YAML" "$FORK_ORIGIN_URL")
printf 'Filed against atlas-fork/ops-fork directly.\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
assert_hook "origin-owner-only: private origin owner/repo form blocks (no public proof)" "$sandbox" 2 "File: notes.md" "atlas-fork"
rm -rf "$sandbox"

sandbox=$(make_sandbox_with_remotes "$ORIGIN_OWNER_REGISTRY_YAML" "$FORK_ORIGIN_URL")
printf 'The atlas-fork account needs review.\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
assert_hook "origin-owner-only: a bare mention of ORIGIN's owner still blocks (no upstream)" "$sandbox" 2 "File: notes.md" "atlas-fork"
rm -rf "$sandbox"

# 9b. #1477 — a public upstream alone does NOT prove origin public.
#     Private ops repos commonly set upstream to the public framework.
#     Without origin_verified_public (or origin in public_framework_repos /
#     registry public:true), the origin-owner exemption must not fire.
PUBLIC_UPSTREAM_URL="https://github.com/me2resh/apexyard.git"
sandbox=$(make_sandbox_with_remotes "$ORIGIN_OWNER_REGISTRY_YAML" "$FORK_ORIGIN_URL" "$PUBLIC_UPSTREAM_URL")
printf 'Filed against atlas-fork/ops-fork directly.\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
assert_hook "origin-owner with public upstream only: owner/repo form still blocks" "$sandbox" 2 "File: notes.md" "atlas-fork"
rm -rf "$sandbox"

# 9c. #1477 — recorded origin_verified_public matching origin restores the
#     narrow owner/repo exemption (skills write this after an online check).
#     Defaults must exist: _config_load skips overrides when they are absent.
sandbox=$(make_sandbox_with_remotes "$ORIGIN_OWNER_REGISTRY_YAML" "$FORK_ORIGIN_URL" "$PUBLIC_UPSTREAM_URL")
cp "$ROOT/.claude/hooks/_lib-read-config.sh" "$sandbox/.claude/hooks/_lib-read-config.sh"
printf '%s\n' '{"leak_protection":{}}' \
  > "$sandbox/.claude/project-config.defaults.json"
printf '%s\n' '{"leak_protection":{"origin_verified_public":"atlas-fork/ops-fork"}}' \
  > "$sandbox/.claude/project-config.json"
printf 'Filed against atlas-fork/ops-fork directly.\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
assert_hook "origin-owner with matching origin_verified_public: owner/repo form does not block" "$sandbox" 0 "" ""
rm -rf "$sandbox"

# 10. Upstream-slug-only case — the repo-slug exemption must work on its
#     own, decoupled from any name-based owner/bare-name match. The
#     registered project below is named "mirror-project" (no coincidental
#     match to the upstream owner or bare name); its `repo` field alone
#     happens to equal the upstream slug, the way an adopter might register
#     the framework itself under a custom project name.
SLUG_ONLY_REGISTRY_YAML='projects:
  - name: mirror-project
    repo: acme-framework/framework
    workspace: workspace/mirror-project
  - name: secret-app
    repo: acme-org/secret-app
    workspace: workspace/secret-app
'
sandbox=$(make_sandbox_with_remotes "$SLUG_ONLY_REGISTRY_YAML" "$FORK_ORIGIN_URL" "$FRAMEWORK_UPSTREAM_URL")
printf 'See acme-framework/framework#5 for background.\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
assert_hook "upstream-slug-only: repo-slug exemption fires with no coincidental name match" "$sandbox" 0 "" ""
rm -rf "$sandbox"

# 11. Hakim MEDIUM — the upstream bare-name exemption must require the
#     registry's OWN pairing of that name to the upstream slug, not a bare
#     string coincidence. Here "framework" is registered, but its `repo`
#     points at a DIFFERENT, private repo — not the upstream slug — so the
#     coincidental name match must not exempt it.
MISMATCHED_NAME_REGISTRY_YAML='projects:
  - name: acme-framework
    repo: acme-org/acme-framework-app
    workspace: workspace/acme-framework-app
  - name: framework
    repo: acme-org/framework-internal
    workspace: workspace/framework-internal
  - name: secret-app
    repo: acme-org/secret-app
    workspace: workspace/secret-app
'
sandbox=$(make_sandbox_with_remotes "$MISMATCHED_NAME_REGISTRY_YAML" "$FORK_ORIGIN_URL" "$FRAMEWORK_UPSTREAM_URL")
printf 'A generic framework bug. No project named.\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
assert_hook "MEDIUM: bare-name match to upstream without a matching repo still blocks" "$sandbox" 2 "File: notes.md" "framework-internal"
rm -rf "$sandbox"

# 11b. Rex round 3 — registry_name_repo_matches loops over
# name_repo_pairs[@] with no guard. Under `set -u`, bash 3.2 (macOS's
# `/bin/bash`, this hook's own shebang) treats an EMPTY array's `[@]`
# expansion as an unbound variable and aborts the whole hook with exit 1
# — every commit blocked, not just the leaky ones. bash 4.4+ fixed that
# specific case, so a Homebrew/Linux bash never sees it, which is why CI
# missed it. name_repo_pairs is empty whenever every registry entry uses
# the PLURAL `repos:` form — no singular `repo:` field ever fires the
# awk pairing branch. The fixture below is plural-only on purpose.
PLURAL_ONLY_REGISTRY_YAML='projects:
  - name: framework
    repos:
      - acme-org/framework-mirror-a
      - acme-org/framework-mirror-b
    workspace: workspace/framework-mirror
  - name: secret-app
    repos:
      - acme-org/secret-app
    workspace: workspace/secret-app
'
# A genuinely clean file — no registered name, repo, or workspace path at
# all. The crash this guards against fires on EVERY staged file once a
# registered name equals upstream_name, regardless of that file's own
# content: the NAME loop always reaches the empty-array call for
# "framework" before it ever checks what the file says.
sandbox=$(make_sandbox_with_remotes "$PLURAL_ONLY_REGISTRY_YAML" "$FORK_ORIGIN_URL" "$FRAMEWORK_UPSTREAM_URL")
printf 'Nothing private mentioned here.\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
assert_hook "round 3: plural-only registry with no name-repo pairs does not abort (clean file passes)" "$sandbox" 0 "" ""
rm -rf "$sandbox"

sandbox=$(make_sandbox_with_remotes "$PLURAL_ONLY_REGISTRY_YAML" "$FORK_ORIGIN_URL" "$FRAMEWORK_UPSTREAM_URL")
printf 'Discovered while touching secret-app during the rebuild.\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
assert_hook "round 3: plural-only registry with no name-repo pairs still blocks a real leak" "$sandbox" 2 "File: notes.md" "secret-app"
rm -rf "$sandbox"

# 12-13. Hakim HIGH-1 — a raw non-UTF-8 byte in the staged blob must not
# make the owner branch fail open. In a UTF-8 locale, unpatched `tr`/BSD
# `sed` stop with "illegal byte sequence" on the byte below, the pipeline's
# exit code goes non-zero, and the pre-fix helper read ANY failure as "no
# bare mention remains" — exempting a file that was never actually scanned.
# The byte is written with `printf '\xe9'` (a lone Latin-1 continuation
# byte, invalid standalone UTF-8) on line 1; a bare upstream-owner mention
# on line 2 must still block.
sandbox=$(make_sandbox_with_remotes "$UPSTREAM_REGISTRY_YAML" "$FORK_ORIGIN_URL" "$FRAMEWORK_UPSTREAM_URL")
printf 'note \xe9 byte\nThe acme-framework project needs a rename.\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
assert_hook "HIGH-1: a non-UTF-8 byte does not make the owner branch fail open" "$sandbox" 2 "File: notes.md" "acme-framework"
rm -rf "$sandbox"

# 13. Fail-before for HIGH-1 — pinned to THIS PR's own round-1 commit, not
# to any upstream SHA. `owner_bare_mention_remains` did not exist before
# this PR at all, so there is no pre-#1431 commit where this specific
# regression could have existed; the only meaningful "before" state is the
# round-1 commit that introduced the helper, before round 2's LC_ALL=C /
# fail-closed fix.
ROUND1_SHA="706c323a0daf7f8645f1b75e974705efb5104767"
sandbox=$(make_sandbox_with_remotes "$UPSTREAM_REGISTRY_YAML" "$FORK_ORIGIN_URL" "$FRAMEWORK_UPSTREAM_URL")
printf 'note \xe9 byte\nThe acme-framework project needs a rename.\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
round1_hook=$(mktemp)
if git -C "$ROOT" show "${ROUND1_SHA}:.claude/hooks/check-private-refs-staged.sh" > "$round1_hook" 2>/dev/null \
  && [ -s "$round1_hook" ]; then
  chmod +x "$round1_hook"
  cp "$round1_hook" "$sandbox/.claude/hooks/check-private-refs-staged.sh"
  round1_output=$(cd "$sandbox" && LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 .claude/hooks/check-private-refs-staged.sh 2>&1); round1_rc=$?
  if [ "$round1_rc" = "2" ]; then
    pass "fail-before HIGH-1: round-1 commit ($ROUND1_SHA) already blocks (locale did not reproduce the bug here)"
  elif [ "$round1_rc" = "0" ]; then
    pass "fail-before HIGH-1: round-1 commit ($ROUND1_SHA) fails open under a UTF-8 locale, as expected pre-fix"
  else
    fail "fail-before HIGH-1: round-1 commit ($ROUND1_SHA)" "unexpected exit $round1_rc: $round1_output"
  fi
else
  echo "  skip fail-before HIGH-1 proof: could not read $ROUND1_SHA's copy of the hook (not fetched in this clone)"
fi
rm -f "$round1_hook"
rm -rf "$sandbox"

echo
echo "== public: true registry entries (apexyard#1455)"
#
# A registered project marked `public: true` is not a private identifier —
# the staged and runtime hooks must let a commit mention its name, repo
# slug, or workspace path through, while an entry with no `public` field
# (the default) still blocks exactly as before. All fixture names below are
# SYNTHETIC.

PUBLIC_REGISTRY_YAML='projects:
  - name: open-marketing-site
    repo: acme-org/open-marketing-site
    public: true
    workspace: workspace/open-marketing-site
  - name: secret-app
    repo: acme-org/secret-app
    workspace: workspace/secret-app
'
NEUTRAL_ORIGIN_URL="https://github.com/neutral-fork/ops-fork.git"

sandbox=$(make_sandbox_with_remotes "$PUBLIC_REGISTRY_YAML" "$NEUTRAL_ORIGIN_URL")
printf 'Announcing open-marketing-site in the acme-org/open-marketing-site repo.\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
assert_hook "public:true entry — name and repo slug do not block" "$sandbox" 0 "" ""
rm -rf "$sandbox"

sandbox=$(make_sandbox_with_remotes "$PUBLIC_REGISTRY_YAML" "$NEUTRAL_ORIGIN_URL")
printf 'Docs live at workspace/open-marketing-site/README.md\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
assert_hook "public:true entry — workspace path does not block" "$sandbox" 0 "" ""
rm -rf "$sandbox"

sandbox=$(make_sandbox_with_remotes "$PUBLIC_REGISTRY_YAML" "$NEUTRAL_ORIGIN_URL")
printf 'Discovered while touching secret-app during the rebuild.\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
assert_hook "entry without public field still blocks (default private)" "$sandbox" 2 "File: notes.md" "secret-app"
rm -rf "$sandbox"

sandbox=$(make_sandbox_with_remotes "$PUBLIC_REGISTRY_YAML" "$NEUTRAL_ORIGIN_URL")
resolved_repo="me2resh/apexyard"
runtime_output=$(cd "$sandbox" && .claude/hooks/check-private-refs-runtime.sh "$resolved_repo" 'Announcing acme-org/open-marketing-site' '' 2>&1); runtime_rc=$?
if [ "$runtime_rc" = "0" ]; then
  pass "runtime hook — public:true entry's repo slug does not block"
else
  fail "runtime hook — public:true entry's repo slug does not block" "$runtime_output"
fi
rm -rf "$sandbox"

sandbox=$(make_sandbox_with_remotes "$PUBLIC_REGISTRY_YAML" "$NEUTRAL_ORIGIN_URL")
runtime_output=$(cd "$sandbox" && .claude/hooks/check-private-refs-runtime.sh "$resolved_repo" 'Reviewed secret-app' '' 2>&1); runtime_rc=$?
if [ "$runtime_rc" = "2" ] && ! printf '%s' "$runtime_output" | grep -qF 'secret-app'; then
  pass "runtime hook — entry without public field still blocks"
else
  fail "runtime hook — entry without public field still blocks" "$runtime_output"
fi
rm -rf "$sandbox"

echo
echo "== public: true entry-boundary scoping (apexyard#1457 review round 2)"
#
# Rex B2 / Hakim HIGH-1: the parser must scope `public: true` to its OWN
# entry only. Each case below proves a private entry stays blocked despite
# a nearby or nested `public: true` that must NOT bleed onto it. All names
# are SYNTHETIC.

# Case A — private entry, then a public entry whose first key is `repo:`
# (not `name:`). The public flag must not bleed backward onto the first.
CASE_A_YAML='projects:
  - name: secret-app
    repo: acme-org/secret-app
    workspace: workspace/secret-app
  - repo: acme-org/open-site
    name: open-site
    public: true
    workspace: workspace/open-site
'
sandbox=$(make_sandbox_with_remotes "$CASE_A_YAML" "$NEUTRAL_ORIGIN_URL")
printf 'Discovered while touching secret-app during the rebuild.\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
assert_hook "case A: repo:-first public entry does not unblock the entry above it" "$sandbox" 2 "File: notes.md" "secret-app"
rm -rf "$sandbox"

sandbox=$(make_sandbox_with_remotes "$CASE_A_YAML" "$NEUTRAL_ORIGIN_URL")
printf 'See acme-org/open-site for the open-site launch.\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
assert_hook "case A: the repo:-first public entry itself still passes" "$sandbox" 0 "" ""
rm -rf "$sandbox"

# Case A2 — public entry first, then a private entry whose first key is
# `workspace:` (not `name:`). The private entry must not inherit public.
#
# apexyard#1457 round 7 — the private set is now exactly dev's (9ac9d9e)
# own extraction, which only ever matched a bare "workspace:"/"repo:"
# line, never a dash-prefixed one (`- workspace:`/`- repo:`); only its
# "- name:" pattern allows a leading dash. So a NON-dash-prefixed field of
# this entry — its `repo:` line — still gets found by dev's scan, and is
# the one this test now checks for correlation correctness. Dev's own
# scan never finds this entry's bare NAME at all when `workspace:` opens
# it (the name line here has no dash either) — that is dev's own
# pre-existing limit, not a regression, and out of scope per this round.
CASE_A2_YAML='projects:
  - name: open-site
    repo: acme-org/open-site
    public: true
    workspace: workspace/open-site
  - workspace: workspace/secret-app
    name: secret-app
    repo: acme-org/secret-app
'
sandbox=$(make_sandbox_with_remotes "$CASE_A2_YAML" "$NEUTRAL_ORIGIN_URL")
printf 'Discovered while touching acme-org/secret-app during the rebuild.\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
assert_hook "case A2: workspace:-first private entry's repo: line still blocks" "$sandbox" 2 "File: notes.md" "secret-app"
rm -rf "$sandbox"

# Case C — a private entry with a NESTED map holding `public: true`. Only
# an exact top-level `public: true` on the entry counts.
CASE_C_YAML='projects:
  - name: secret-app
    repo: acme-org/secret-app
    deploy:
      public: true
      region: us
    workspace: workspace/secret-app
'
sandbox=$(make_sandbox_with_remotes "$CASE_C_YAML" "$NEUTRAL_ORIGIN_URL")
printf 'Discovered while touching secret-app during the rebuild.\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
assert_hook "case C: public: true nested under a sub-map does not unscrub the entry" "$sandbox" 2 "File: notes.md" "secret-app"
rm -rf "$sandbox"

# Case E — a top-level `defaults:` map (after the last entry) with
# `public: true` nested inside it must not unscrub the entry above it.
CASE_E_YAML='projects:
  - name: secret-app
    repo: acme-org/secret-app
    workspace: workspace/secret-app
defaults:
  public: true
  status: active
'
sandbox=$(make_sandbox_with_remotes "$CASE_E_YAML" "$NEUTRAL_ORIGIN_URL")
printf 'Discovered while touching secret-app during the rebuild.\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
assert_hook "case E: public: true under a top-level defaults: block does not unscrub the entry" "$sandbox" 2 "File: notes.md" "secret-app"
rm -rf "$sandbox"

# Block scalar — a `notes: |` body that happens to CONTAIN the literal text
# "public: true" as prose must not be read as the flag.
BLOCK_SCALAR_YAML='projects:
  - name: secret-app
    repo: acme-org/secret-app
    notes: |
      this project is not public: true actually
      public: true
    workspace: workspace/secret-app
'
sandbox=$(make_sandbox_with_remotes "$BLOCK_SCALAR_YAML" "$NEUTRAL_ORIGIN_URL")
printf 'Discovered while touching secret-app during the rebuild.\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
assert_hook "block scalar prose containing the string public: true is not read as the flag" "$sandbox" 2 "File: notes.md" "secret-app"
rm -rf "$sandbox"

# Nested "- name:" list item — a sub-list inside the entry that itself
# starts with "- name:" must not be mistaken for a NEW top-level entry.
NESTED_LIST_YAML='projects:
  - name: secret-app
    repo: acme-org/secret-app
    team:
      - name: someone
        public: true
    workspace: workspace/secret-app
'
sandbox=$(make_sandbox_with_remotes "$NESTED_LIST_YAML" "$NEUTRAL_ORIGIN_URL")
printf 'Discovered while touching secret-app during the rebuild.\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
assert_hook "nested - name: list item inside an entry does not open a new entry" "$sandbox" 2 "File: notes.md" "secret-app"
rm -rf "$sandbox"

# "public:true" with no space — YAML reads a colon with no following
# space as a plain scalar, not a key; must not be read as the flag.
NO_SPACE_YAML='projects:
  - name: secret-app
    repo: acme-org/secret-app
    public:true
    workspace: workspace/secret-app
'
sandbox=$(make_sandbox_with_remotes "$NO_SPACE_YAML" "$NEUTRAL_ORIGIN_URL")
printf 'Discovered while touching secret-app during the rebuild.\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
assert_hook "public:true with no space after the colon is not read as the flag" "$sandbox" 2 "File: notes.md" "secret-app"
rm -rf "$sandbox"

# CRLF registry — apexyard#1457 round 7 left this an accepted dev gap
# (dev's own extraction never stripped a trailing `\r`, so a CRLF line's
# token carried it and never matched plain text, for a private entry
# exactly as much as a public one). Round 8 (Hakim LOW-1) closes the
# private-entry half: registry_parse_entries now runs dev's extraction
# against a CR-stripped COPY of the registry, so a CRLF private token
# matches plain text like any other. This is strictly MORE scanning than
# dev did (never less), so it cannot regress the differential test's
# "never fewer than dev" guarantee. The public (structural) pass still
# reads the registry as-is, unchanged.
sandbox=$(make_sandbox_with_remotes "$CASE_A_YAML" "$NEUTRAL_ORIGIN_URL")
printf 'projects:\r\n  - name: open-site\r\n    repo: acme-org/open-site\r\n    public: true\r\n    workspace: workspace/open-site\r\n' > "$sandbox/apexyard.projects.yaml"
printf 'See acme-org/open-site for the open-site launch.\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
assert_hook "CRLF registry — a public entry still passes" "$sandbox" 0 "" ""
rm -rf "$sandbox"

sandbox=$(make_sandbox_with_remotes "$CASE_A_YAML" "$NEUTRAL_ORIGIN_URL")
printf 'projects:\r\n  - name: pp-crlf-priv\r\n    repo: acme-org/pp-crlf-repo\r\n' > "$sandbox/apexyard.projects.yaml"
printf 'See acme-org/pp-crlf-repo mentioned here.\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
assert_hook "CRLF registry (round 8, Hakim LOW-1) — a private entry now blocks" "$sandbox" 2 "File: notes.md" "pp-crlf-repo"
rm -rf "$sandbox"

echo
echo "== #1431 name-repo pairing when the upstream repo is in a repos: list (Hakim LOW-1)"
#
# The staged hook's name_repo_pairs now pairs a name with EVERY repo in its
# entry, including each item of a plural `repos:` list (a side effect of
# the entry-scoped rewrite). This proves the upstream bare-name exemption
# still fires when the upstream repo is one of several in a `repos:` list,
# and is a deliberate behaviour change from the base #1431 pairing (which
# only ever paired the first singular `repo:`).
REPOS_LIST_UPSTREAM_YAML='projects:
  - name: framework
    repos:
      - acme-org/other-repo
      - acme-framework/framework
    workspace: workspace/framework-mirror
  - name: secret-app
    repo: acme-org/secret-app
    workspace: workspace/secret-app
'
# The BARE upstream repo name only — no "@owner" or "owner/repo" form — so
# this exercises registry_name_repo_matches (the name<->repos: pairing),
# not the separate owner-login exemption (#1387).
sandbox=$(make_sandbox_with_remotes "$REPOS_LIST_UPSTREAM_YAML" "$FORK_ORIGIN_URL" "$FRAMEWORK_UPSTREAM_URL")
printf 'The framework has a bug in this area.\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
assert_hook "LOW-1: upstream bare-name exemption fires when upstream repo is inside a repos: list" "$sandbox" 0 "" ""
rm -rf "$sandbox"

echo
echo "== Regression: no workspace field at all (bash 3.2 unbound-variable crash)"
#
# Rex suggestion — at a prior base, a registry where NO entry has a
# workspace: field crashed the staged hook under bash 3.2's `set -u` with
# `workspaces[@]: unbound variable` (exit 1), blocking every commit
# regardless of content. The `"${!array[@]}"` index loops fix this.
NO_WORKSPACE_YAML='projects:
  - name: secret-app
    repo: acme-org/secret-app
'
sandbox=$(make_sandbox_with_remotes "$NO_WORKSPACE_YAML" "$NEUTRAL_ORIGIN_URL")
printf 'Nothing private mentioned here.\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
assert_hook "a registry with no workspace: field anywhere does not crash (clean file passes)" "$sandbox" 0 "" ""
rm -rf "$sandbox"

sandbox=$(make_sandbox_with_remotes "$NO_WORKSPACE_YAML" "$NEUTRAL_ORIGIN_URL")
printf 'Discovered while touching secret-app during the rebuild.\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
assert_hook "a registry with no workspace: field anywhere still blocks a real leak" "$sandbox" 2 "File: notes.md" "secret-app"
rm -rf "$sandbox"

echo
echo "== Round 3: valid YAML shapes the parser must not drop (apexyard#1457)"
#
# Rex B4 / Hakim HIGH-3, HIGH-4 — five valid YAML shapes dropped their
# entries at commit 3a424f5. Each test body below names ONLY the private
# REPO SLUG, never the project name, so a surviving NAME token cannot mask
# a dropped REPO token. Verified by hand against 3a424f5's copy of
# _lib-registry-parser.sh before this fix: N3 produced zero tokens, N3b
# dropped its entry, N1b and N2b dropped their repos: items, and N4 dropped
# its bare-"-" entry entirely. All names/slugs are SYNTHETIC.

# N3 — a top-level list before `projects:`, at a DIFFERENT indent than the
# real entries, must not anchor the entry column.
N3_YAML='maintainers:
- ops-team
- infra-team
projects:
  - name: aa-app
    repo: acme-org/aa-repo-one
    workspace: workspace/aa-app
'
sandbox=$(make_sandbox_with_remotes "$N3_YAML" "$NEUTRAL_ORIGIN_URL")
printf 'Reproduces in acme-org/aa-repo-one as well.\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
assert_hook "N3: a top-level list before projects: does not drop the entry" "$sandbox" 2 "File: notes.md" "aa-repo-one"
rm -rf "$sandbox"

# N3b — a top-level block scalar before `projects:` with a line that
# starts with "- ", at a column that does not match the real entries.
N3B_YAML='description: |
    Some prose about this registry.
    - not a real project entry
projects:
  - name: bb-app
    repo: acme-org/bb-repo-one
    workspace: workspace/bb-app
'
sandbox=$(make_sandbox_with_remotes "$N3B_YAML" "$NEUTRAL_ORIGIN_URL")
printf 'Reproduces in acme-org/bb-repo-one as well.\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
assert_hook "N3b: a top-level block scalar with a - line does not drop the entry" "$sandbox" 2 "File: notes.md" "bb-repo-one"
rm -rf "$sandbox"

# N1b — a compact repos: sequence, item dashes at the SAME column as the
# repos: key itself (valid YAML; not only the strictly-deeper form).
N1B_YAML='projects:
  - name: cc-app
    repos:
    - acme-org/cc-repo-one
    - acme-org/cc-repo-two
'
sandbox=$(make_sandbox_with_remotes "$N1B_YAML" "$NEUTRAL_ORIGIN_URL")
printf 'Reproduces in acme-org/cc-repo-one as well.\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
assert_hook "N1b: a compact repos: list does not drop its items" "$sandbox" 2 "File: notes.md" "cc-repo-one"
rm -rf "$sandbox"

# N2b — an indentless projects: list ("- name:" at column 0, PyYAML's
# default dump shape) combined with a compact repos: list.
N2B_YAML='projects:
- name: dd-app
  repos:
  - acme-org/dd-repo-one
  - acme-org/dd-repo-two
'
sandbox=$(make_sandbox_with_remotes "$N2B_YAML" "$NEUTRAL_ORIGIN_URL")
printf 'Reproduces in acme-org/dd-repo-one as well.\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
assert_hook "N2b: an indentless projects: list with a compact repos: list does not drop its items" "$sandbox" 2 "File: notes.md" "dd-repo-one"
rm -rf "$sandbox"

# N4 — a bare "-" entry, with its keys on the following lines.
N4_YAML='projects:
  - name: ee-app
    repo: acme-org/ee-repo-one
  -
    name: ff-app
    repo: acme-org/ff-repo-one
    workspace: workspace/ff-app
'
sandbox=$(make_sandbox_with_remotes "$N4_YAML" "$NEUTRAL_ORIGIN_URL")
printf 'Reproduces in acme-org/ff-repo-one as well.\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
assert_hook "N4: a bare - entry with keys on the next lines does not drop the entry" "$sandbox" 2 "File: notes.md" "ff-repo-one"
rm -rf "$sandbox"

echo
echo "== Round 3: runtime hook, same shapes (where it applies)"
#
# apexyard#1457 round 7 — no compact/block-list repos: case is asserted
# for the runtime hook here any more. Its own dev (9ac9d9e) extraction
# has a pre-existing bug that keeps a `repos:` block list from EVER being
# read (a bare `in_repos = 0` statement, with no braces, is itself an
# always-false PATTERN in awk, so it re-fires and resets the flag on
# every single line, not just once at start) — no `repos:` block-list
# item, compact or indented, was ever scrubbed by this hook on dev. That
# is dev's own gap, kept unchanged and out of scope this round.
resolved_repo="me2resh/apexyard"

sandbox=$(make_sandbox_with_remotes "$N4_YAML" "$NEUTRAL_ORIGIN_URL")
runtime_output=$(cd "$sandbox" && .claude/hooks/check-private-refs-runtime.sh "$resolved_repo" 'Reproduces in acme-org/ff-repo-one as well' '' 2>&1); runtime_rc=$?
if [ "$runtime_rc" = "2" ] && ! printf '%s' "$runtime_output" | grep -qF 'ff-repo-one'; then
  pass "runtime hook — N4 bare - entry does not drop the entry"
else
  fail "runtime hook — N4 bare - entry does not drop the entry" "$runtime_output"
fi
rm -rf "$sandbox"

echo
echo "== Round 3/4: sanity gate — projects:/name: present but the parse gives zero tokens (Hakim MEDIUM)"
#
# A registry that plainly has a projects: key and a name: key, but the
# parse could not extract any token, must block rather than silently
# allow every private reference (a parser gap, not an empty registry).
#
# apexyard#1457 round 4 — the private set is now a greedy, structure-
# independent scan (registry_has_project_shape allows "name:" ANYWHERE on
# a line; the greedy awk pass requires the line'\''s own content to START
# with "name:"), so this fixture has to exploit that specific gap between
# the two: "name:" appears mid-line, after other text, which the lenient
# sanity-gate heuristic still matches but the anchored greedy pass does
# not. A fixture that puts "name:" at the START of any line (even inside
# prose) is no longer a zero-token case at all — the greedy pass would
# find it, which is by design.
ZERO_TOKEN_YAML='projects:
notes: the name: field is optional here
'
sandbox=$(make_sandbox_with_remotes "$ZERO_TOKEN_YAML" "$NEUTRAL_ORIGIN_URL")
printf 'Nothing private mentioned here at all.\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
assert_hook "sanity gate: projects:/name: present, zero tokens parsed, still blocks" "$sandbox" 2 "registry parse produced no tokens" ""
rm -rf "$sandbox"

# A genuinely EMPTY registry (no projects:/name: shape at all) must stay a
# no-op, exactly as before — the sanity gate must not fire on a registry
# that legitimately registers nothing.
EMPTY_YAML='version: 1
'
sandbox=$(make_sandbox_with_remotes "$EMPTY_YAML" "$NEUTRAL_ORIGIN_URL")
printf 'Nothing private mentioned here at all.\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
assert_hook "sanity gate: a genuinely empty registry stays a no-op" "$sandbox" 0 "" ""
rm -rf "$sandbox"

echo
echo "== Round 3: the non-zero parser-exit branch of B1 (an unreadable, not missing, registry)"
#
# apexyard#1457 round 2 Rex suggestion — only the "library missing" branch
# had a test. This exercises the OTHER fail-closed branch: the library
# loads fine, but registry_parse_entries itself returns non-zero because
# the registry file exists but cannot be read.
sandbox=$(make_sandbox_with_remotes "$N3_YAML" "$NEUTRAL_ORIGIN_URL")
chmod 000 "$sandbox/apexyard.projects.yaml"
unreadable_output=$(cd "$sandbox" && .claude/hooks/check-private-refs-staged.sh 2>&1); unreadable_rc=$?
chmod 644 "$sandbox/apexyard.projects.yaml"
if [ "$unreadable_rc" = "2" ] && printf '%s' "$unreadable_output" | grep -qF 'registry parse failed'; then
  pass "staged hook blocks when the registry exists but is unreadable (non-zero parser exit)"
else
  fail "staged hook blocks when the registry exists but is unreadable (non-zero parser exit)" "exit=$unreadable_rc output=$unreadable_output"
fi
rm -rf "$sandbox"

sandbox=$(make_sandbox_with_remotes "$N3_YAML" "$NEUTRAL_ORIGIN_URL")
chmod 000 "$sandbox/apexyard.projects.yaml"
unreadable_runtime_output=$(cd "$sandbox" && .claude/hooks/check-private-refs-runtime.sh "me2resh/apexyard" "irrelevant" '' 2>&1); unreadable_runtime_rc=$?
chmod 644 "$sandbox/apexyard.projects.yaml"
if [ "$unreadable_runtime_rc" = "2" ] && printf '%s' "$unreadable_runtime_output" | grep -qF 'registry parse failed'; then
  pass "runtime hook blocks when the registry exists but is unreadable (non-zero parser exit)"
else
  fail "runtime hook blocks when the registry exists but is unreadable (non-zero parser exit)" "exit=$unreadable_runtime_rc output=$unreadable_runtime_output"
fi
rm -rf "$sandbox"

echo
echo "== Round 4: the projects: anchor itself must not be droppable (apexyard#1457)"
#
# Rex A / Hakim S5, Hakim S1, Hakim S4, Rex B / Hakim S9, Hakim S8 — the
# round-3 structural anchor still dropped a whole entry (name AND repo)
# when the real top-level projects: key was preceded by an ambiguous or
# unrecognized shape. Each fixture pairs a "target" entry with a repo
# slug that shares NO substring with its own name, so a surviving NAME
# token can never mask a dropped REPO token (or vice versa). Verified by
# hand against 44c0fb6's copy of _lib-registry-parser.sh before adding
# these: every one of the five reproduced the drop (S1 kept only the
# first, ambiguous entry; S4/S5 kept only the fake prose/nested name; S8
# and S9 produced no tokens at all). All names/slugs are SYNTHETIC.

# S1 — two top-level projects: keys; the first holds a public entry. The
# whole parse must become ambiguous, so nothing is exempt — but the
# SECOND (real, private) entry must still be captured at all.
S1_YAML='projects:
  - name: aa-decoy
    repo: acme-org/site-one
    public: true
projects:
  - name: bb-target
    repo: acme-org/vault-one
'
sandbox=$(make_sandbox_with_remotes "$S1_YAML" "$NEUTRAL_ORIGIN_URL")
printf 'Reproduces in acme-org/vault-one as well.\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
assert_hook "S1: two top-level projects: keys do not drop the second entry" "$sandbox" 2 "File: notes.md" "vault-one"
rm -rf "$sandbox"

# S4 — a top-level block scalar whose TEXT holds "projects:" and a
# "- name:" line, before the real key.
S4_YAML='notes: |
  projects:
  - name: cc-fake
projects:
  - name: dd-target
    repo: acme-org/vault-two
'
sandbox=$(make_sandbox_with_remotes "$S4_YAML" "$NEUTRAL_ORIGIN_URL")
printf 'Reproduces in acme-org/vault-two as well.\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
assert_hook "S4: a block scalar whose text holds projects: and - name: does not drop the real entry" "$sandbox" 2 "File: notes.md" "vault-two"
rm -rf "$sandbox"

# S5 / Rex A — a nested projects: list under another top-level map,
# before the real key.
S5_YAML='meta:
  projects:
    - name: ee-fake
projects:
  - name: ff-target
    repo: acme-org/vault-three
'
sandbox=$(make_sandbox_with_remotes "$S5_YAML" "$NEUTRAL_ORIGIN_URL")
printf 'Reproduces in acme-org/vault-three as well.\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
assert_hook "S5/Rex A: a nested projects: key under another map does not drop the real entry" "$sandbox" 2 "File: notes.md" "vault-three"
rm -rf "$sandbox"

# S8 — an anchored key, projects: &all.
S8_YAML='projects: &all
  - name: gg-target
    repo: acme-org/vault-four
'
sandbox=$(make_sandbox_with_remotes "$S8_YAML" "$NEUTRAL_ORIGIN_URL")
printf 'Reproduces in acme-org/vault-four as well.\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
assert_hook "S8: projects: &all (an anchor) does not drop every entry" "$sandbox" 2 "File: notes.md" "vault-four"
rm -rf "$sandbox"

# S9 / Rex B — a quoted key, "projects":.
S9_YAML='"projects":
  - name: hh-target
    repo: acme-org/vault-five
'
sandbox=$(make_sandbox_with_remotes "$S9_YAML" "$NEUTRAL_ORIGIN_URL")
printf 'Reproduces in acme-org/vault-five as well.\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
assert_hook "S9/Rex B: a quoted projects: key does not drop every entry" "$sandbox" 2 "File: notes.md" "vault-five"
rm -rf "$sandbox"

echo
echo "== Round 4: runtime hook, representative anchor shapes"

sandbox=$(make_sandbox_with_remotes "$S1_YAML" "$NEUTRAL_ORIGIN_URL")
resolved_repo="me2resh/apexyard"
runtime_output=$(cd "$sandbox" && .claude/hooks/check-private-refs-runtime.sh "$resolved_repo" 'Reproduces in acme-org/vault-one as well' '' 2>&1); runtime_rc=$?
if [ "$runtime_rc" = "2" ] && ! printf '%s' "$runtime_output" | grep -qF 'vault-one'; then
  pass "runtime hook — S1 (two top-level projects: keys) does not drop the second entry"
else
  fail "runtime hook — S1 (two top-level projects: keys) does not drop the second entry" "$runtime_output"
fi
rm -rf "$sandbox"

sandbox=$(make_sandbox_with_remotes "$S8_YAML" "$NEUTRAL_ORIGIN_URL")
runtime_output=$(cd "$sandbox" && .claude/hooks/check-private-refs-runtime.sh "$resolved_repo" 'Reproduces in acme-org/vault-four as well' '' 2>&1); runtime_rc=$?
if [ "$runtime_rc" = "2" ] && ! printf '%s' "$runtime_output" | grep -qF 'vault-four'; then
  pass "runtime hook — S8 (projects: &all anchor) does not drop every entry"
else
  fail "runtime hook — S8 (projects: &all anchor) does not drop every entry" "$runtime_output"
fi
rm -rf "$sandbox"

echo
echo "== Round 5: line-based exemption, not count-based (Hakim HIGH-7)"
#
# The round-4 exemption rule compared PER-VALUE OCCURRENCE COUNTS between
# the greedy (private) pass and the structural (public) pass, on the
# assumption both end a repos: list at the same line. They do not: the
# greedy pass ends the list at ANY key-shaped line, including a repos:
# item that is itself a map (`- primary: ...`) or a `- repo:` item; the
# structural pass keeps the list open until the entry's own field
# column. A public entry whose repos: list has such an item before a
# slug it shares with a PRIVATE entry could then have equal counts (1
# each) — exempting a token that is genuinely private elsewhere. Fixed
# by comparing LINE NUMBERS: a token is exempt only when every line
# where the greedy pass found it is ALSO a line the structural pass
# attributes to a proven public entry. Verified by hand against
# 8196285's copy of _lib-registry-parser.sh before adding these: X1 and
# X1b both marked the shared slug PUBLIC=1 there; X1c (control) already
# blocked correctly. All names/slugs are SYNTHETIC.

# X1 — a MAP item ("- primary: ... / mirror: true") before the shared
# slug in a public entry's repos: list; the same slug also appears in a
# private entry via a plain repo: key.
X1_YAML='projects:
  - name: aa-open
    public: true
    repos:
      - primary: org/open-x1
        mirror: true
      - org/shared-x1
  - name: bb-private
    repo: org/shared-x1
'
sandbox=$(make_sandbox_with_remotes "$X1_YAML" "$NEUTRAL_ORIGIN_URL")
printf 'Reproduces in org/shared-x1 as well.\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
assert_hook "X1: a map item before the shared slug does not exempt it" "$sandbox" 2 "File: notes.md" "shared-x1"
rm -rf "$sandbox"

# X1b — a "- repo: ..." item before the shared slug in the public
# entry's repos: list.
X1B_YAML='projects:
  - name: cc-open
    public: true
    repos:
      - repo: org/open-x1b
      - org/shared-x1b
  - name: dd-private
    repo: org/shared-x1b
'
sandbox=$(make_sandbox_with_remotes "$X1B_YAML" "$NEUTRAL_ORIGIN_URL")
printf 'Reproduces in org/shared-x1b as well.\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
assert_hook "X1b: a - repo: item before the shared slug does not exempt it" "$sandbox" 2 "File: notes.md" "shared-x1b"
rm -rf "$sandbox"

# X1c (control) — a plain list, same shared slug, nothing before it.
# Must already block correctly; proves the fix did not overcorrect.
X1C_YAML='projects:
  - name: ee-open
    public: true
    repos:
      - org/open-x1c
      - org/shared-x1c
  - name: ff-private
    repo: org/shared-x1c
'
sandbox=$(make_sandbox_with_remotes "$X1C_YAML" "$NEUTRAL_ORIGIN_URL")
printf 'Reproduces in org/shared-x1c as well.\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
assert_hook "X1c (control): a plain list with the same shared slug still blocks" "$sandbox" 2 "File: notes.md" "shared-x1c"
rm -rf "$sandbox"

echo
echo "== Round 5: strict public: true validation (Hakim item 3)"
#
# An entry is public only if it has EXACTLY ONE public: key and that
# key's value is exactly true. A second public: key, or any other
# value, makes the entry private.
DUP_PUBLIC_YAML='projects:
  - name: secret-app
    repo: acme-org/secret-app-duppublic
    public: true
    public: true
    workspace: workspace/secret-app-duppublic
'
sandbox=$(make_sandbox_with_remotes "$DUP_PUBLIC_YAML" "$NEUTRAL_ORIGIN_URL")
printf 'Reproduces in acme-org/secret-app-duppublic as well.\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
assert_hook "a second public: true key makes the entry private" "$sandbox" 2 "File: notes.md" "secret-app-duppublic"
rm -rf "$sandbox"

echo
echo "== Round 5: an ambiguity warning names its cause (Rex/Hakim advisory)"
#
# When the public set is suppressed (a duplicate top-level projects: key,
# or a tab in the registry's indentation), the parser writes one line to
# stderr naming the cause. The commit still blocks on its own merits
# (the mentioned repo slug); this only checks the diagnostic is present.
sandbox=$(make_sandbox_with_remotes "$S1_YAML" "$NEUTRAL_ORIGIN_URL")
printf 'Reproduces in acme-org/vault-one as well.\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
warn_output=$(cd "$sandbox" && .claude/hooks/check-private-refs-staged.sh 2>&1)
if printf '%s' "$warn_output" | grep -qF 'a second top-level projects: key'; then
  pass "ambiguity warning names a duplicate top-level projects: key"
else
  fail "ambiguity warning names a duplicate top-level projects: key" "$warn_output"
fi
rm -rf "$sandbox"

sandbox=$(make_sandbox_with_remotes "$S1_YAML" "$NEUTRAL_ORIGIN_URL")
printf 'projects:\n\t- name: secret-app\n\t  repo: acme-org/secret-app-tab\n' > "$sandbox/apexyard.projects.yaml"
printf 'Reproduces in acme-org/secret-app-tab as well.\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
warn_output=$(cd "$sandbox" && .claude/hooks/check-private-refs-staged.sh 2>&1)
if printf '%s' "$warn_output" | grep -qF "a tab character in the registry"; then
  pass "ambiguity warning names a tab in the registry's indentation"
else
  fail "ambiguity warning names a tab in the registry's indentation" "$warn_output"
fi
rm -rf "$sandbox"

echo
echo "== Round 6: a repos: list surviving a - repo:/- workspace: item (Rex B6)"
#
# apexyard#1457 round 7 — these two cases are re-verified here against
# dev's (9ac9d9e) own extraction, which the private set is built from
# again as of this round. Dev's standard (staged/public-tracker) awk
# already handled a one-key "- repo: x" or "- workspace: x" list item
# correctly on its own: its per-line dash rule has no `next` and never
# resets `current_list`, so the list stays armed for the plain item
# after it. A THIRD B6 shape — a multi-key map item, `- primary: x` then
# a `mirror: true` continuation line — is NOT asserted here any more:
# dev's own generic "any key: line closes the list" rule closes it on
# the `mirror: true` continuation just as much as it would on a real
# sibling key, so the plain item after it was never scrubbed on dev
# either. That is dev's own gap, kept unchanged and out of scope this
# round. Each test body names ONLY the private repo slug that came
# AFTER the map-shaped item, never the entry name. All names/slugs are
# SYNTHETIC.

B6_REPO_YAML='projects:
  - name: pp-priv1
    repos:
      - repo: org/decoy-b6-repo
      - org/target-b6-after-repo
'
sandbox=$(make_sandbox_with_remotes "$B6_REPO_YAML" "$NEUTRAL_ORIGIN_URL")
printf 'Reproduces in org/target-b6-after-repo as well.\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
assert_hook "B6: a - repo: item does not close the repos: list early" "$sandbox" 2 "File: notes.md" "target-b6-after-repo"
rm -rf "$sandbox"

B6_WS_YAML='projects:
  - name: qq-priv2
    repos:
      - workspace: w/decoy-b6-ws
      - org/target-b6-after-ws
'
sandbox=$(make_sandbox_with_remotes "$B6_WS_YAML" "$NEUTRAL_ORIGIN_URL")
printf 'Reproduces in org/target-b6-after-ws as well.\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
assert_hook "B6: a - workspace: item does not close the repos: list early" "$sandbox" 2 "File: notes.md" "target-b6-after-ws"
rm -rf "$sandbox"

echo
echo "== Round 6: runtime hook — see note above; not asserted (dev's own gap)"
#
# apexyard#1457 round 7 — the runtime hook's own dev extraction cannot
# scrub ANY repos: block-list item at all (see the "in_repos" note in
# the round-3 runtime section above), so neither the - repo: nor the
# multi-key-map B6 shape is asserted for it here. Not a regression:
# dev never scrubbed a block-list repos: item for this hook.
resolved_repo="me2resh/apexyard"

echo
echo "== Round 6: a duplicate name:/repo:/workspace:/repos: key makes the entry private (Hakim D1, advisory)"
#
# A missing "- " typo lets a whole second project's fields land inside
# the entry above it as duplicate keys. The parser reads it as one
# entry with a duplicate name:/repo: — treated the same as a duplicate
# public: key.
D1_YAML='projects:
  - name: ss-pub1
    public: true
    repo: org/decoy-d1-primary
    name: tt-typo1
    repo: org/target-d1-shared
'
sandbox=$(make_sandbox_with_remotes "$D1_YAML" "$NEUTRAL_ORIGIN_URL")
printf 'Reproduces in org/target-d1-shared as well.\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
assert_hook "D1: a duplicate name:/repo: key (missing - typo) makes the entry private" "$sandbox" 2 "File: notes.md" "target-d1-shared"
rm -rf "$sandbox"

echo
echo "== Round 7 (Hakim HIGH-8, Rex B7): an entry starting with - repos: must not swallow later entries"
#
# The round-6 greedy scan's g_repos_indent got the whole LINE's own
# indentation, not the column of the repos: key text — on a "- repos:"
# line those are the same column as the entry's own dash, so the list
# never closed and every later entry's fields (name, repo, workspace)
# were read as more items of that same list. Deleted with the rest of
# the round 4-6 rewrite (apexyard#1457 round 7): the private set no
# longer depends on any custom entry-boundary logic at all, so this
# shape was never at risk under dev's (9ac9d9e) own flat extraction —
# verified here, in both the indented and indentless projects: styles.
# Each body checks the path form (name/file), the hyphenated form
# (name-suffix), and a workspace path followed by /. All names/slugs
# SYNTHETIC.

G1_YAML='projects:
  - repos:
      - priv-g1
    workspace: workspace/wsg1
  - name: priv-g1-target
    repo: acme-org/priv-g1-target-repo
    workspace: workspace/priv-g1-target
'
sandbox=$(make_sandbox_with_remotes "$G1_YAML" "$NEUTRAL_ORIGIN_URL")
printf 'See priv-g1-target/api for details.\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
assert_hook "G1/B7 (indented): an entry starting with - repos: does not swallow the next entry's name (path form)" "$sandbox" 2 "File: notes.md" "priv-g1-target"
rm -rf "$sandbox"

sandbox=$(make_sandbox_with_remotes "$G1_YAML" "$NEUTRAL_ORIGIN_URL")
printf 'The priv-g1-target-api service is down.\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
assert_hook "G1/B7 (indented): an entry starting with - repos: does not swallow the next entry's name (hyphenated form)" "$sandbox" 2 "File: notes.md" "priv-g1-target"
rm -rf "$sandbox"

sandbox=$(make_sandbox_with_remotes "$G1_YAML" "$NEUTRAL_ORIGIN_URL")
printf 'Edit workspace/priv-g1-target/README.md.\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
assert_hook "G1/B7 (indented): an entry starting with - repos: does not swallow the next entry's workspace path" "$sandbox" 2 "File: notes.md" "priv-g1-target"
rm -rf "$sandbox"

G2_YAML='projects:
- repos:
    - priv-g2
  workspace: workspace/wsg2
- name: priv-g2-target
  repo: acme-org/priv-g2-target-repo
  workspace: workspace/priv-g2-target
'
sandbox=$(make_sandbox_with_remotes "$G2_YAML" "$NEUTRAL_ORIGIN_URL")
printf 'See priv-g2-target/api for details.\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
assert_hook "G2/B7 (indentless): an entry starting with - repos: does not swallow the next entry's name (path form)" "$sandbox" 2 "File: notes.md" "priv-g2-target"
rm -rf "$sandbox"

sandbox=$(make_sandbox_with_remotes "$G2_YAML" "$NEUTRAL_ORIGIN_URL")
printf 'The priv-g2-target-api service is down.\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
assert_hook "G2/B7 (indentless): an entry starting with - repos: does not swallow the next entry's name (hyphenated form)" "$sandbox" 2 "File: notes.md" "priv-g2-target"
rm -rf "$sandbox"

sandbox=$(make_sandbox_with_remotes "$G2_YAML" "$NEUTRAL_ORIGIN_URL")
printf 'Edit workspace/priv-g2-target/README.md.\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
assert_hook "G2/B7 (indentless): an entry starting with - repos: does not swallow the next entry's workspace path" "$sandbox" 2 "File: notes.md" "priv-g2-target"
rm -rf "$sandbox"

echo
echo "== Round 7: runtime hook, representative G1 shape"

sandbox=$(make_sandbox_with_remotes "$G1_YAML" "$NEUTRAL_ORIGIN_URL")
runtime_output=$(cd "$sandbox" && .claude/hooks/check-private-refs-runtime.sh "$resolved_repo" 'See priv-g1-target/api for details' '' 2>&1); runtime_rc=$?
if [ "$runtime_rc" = "2" ] && ! printf '%s' "$runtime_output" | grep -qF 'priv-g1-target'; then
  pass "runtime hook — G1/B7 (indented) does not swallow the next entry's name"
else
  fail "runtime hook — G1/B7 (indented) does not swallow the next entry's name" "$runtime_output"
fi
rm -rf "$sandbox"

echo
echo "== Round 7: a map-item continuation (mirror: true) must not produce a 'true' token"
#
# apexyard#1457 round 7 — dev's (9ac9d9e) own extraction never captured
# a map-item's continuation line as a value at all (its generic "any
# key: line closes the list" rule fires on "mirror: true" before any
# repos-item rule could), so the private set built from dev's
# extraction must not contain a bare "true" token either. A commit that
# merely says "true" must not block.
G3_YAML='projects:
  - name: priv-g3
    repos:
      - primary: acme-org/priv-g3-primary
        mirror: true
'
sandbox=$(make_sandbox_with_remotes "$G3_YAML" "$NEUTRAL_ORIGIN_URL")
printf 'Set the flag to true and merge to main when ready.\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
assert_hook "G3: a map-item continuation (mirror: true) does not make 'true' a private token" "$sandbox" 0 "" ""
rm -rf "$sandbox"

echo
echo "== Round 8 (Hakim HIGH-9): a multi-word dev token still blocks on its real word"
#
# apexyard#1457 round 8 — dev's own hook looped over a space-joined
# string, so the shell split a multi-word token (a map item like
# "primary: acme-org/x", or a one-key "- repo: acme-org/x" list item —
# both of which dev's extraction emits as ONE value with an embedded
# space) into separate words and checked each word on its own. Round 2's
# move to indexed arrays checks each value as one whole string instead,
# which normal text never contains verbatim. _lib-registry-parser.sh now
# restores dev's per-word behaviour once, in the shared path, so every
# consumer gets it. M2b is the staged-hook mirror of public-tracker's
# M1b (M1a's shape is already covered on staged by G3 above, which only
# asserted the "true" non-match half; this adds the real-slug match half
# for the staged hook via M2b specifically, per round-8 scope). All
# names/slugs SYNTHETIC.

M2B_YAML='projects:
  - name: mm-priv-b2
    repos:
      - repo: acme-org/mm-target-b2
'
sandbox=$(make_sandbox_with_remotes "$M2B_YAML" "$NEUTRAL_ORIGIN_URL")
printf 'Reproduces in acme-org/mm-target-b2 as well.\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
assert_hook "M2b: a - repo: item inside repos: blocks via its split word on the staged hook" "$sandbox" 2 "File: notes.md" "mm-target-b2"
rm -rf "$sandbox"

echo
echo "== Round 8 (Hakim MEDIUM): a tab inside a proven-public value cannot forge a line number"
#
# apexyard#1457 round 8 — _registry_correlate split a "value\tline" pair
# at the FIRST tab. A proven-public value containing an embedded tab
# followed by a digit string chosen to match some OTHER private token's
# real line let that first-tab split misread the embedded tab as the
# value/line separator, forging a PubR entry at an attacker-chosen line
# — exempting a private token that has nothing to do with the actual
# public entry. Below, "nn-public"'\''s repos: list carries ONE item,
# "org/mm-shared-tabforge<TAB>3" (captured whole-line by dev'\''s repos-
# item pattern, tab included), chosen so the OLD first-tab split would
# read line 3 — the real line of "mm-private"'\''s own, unrelated repo:
# value. Verified against `0104011`'\''s copy of the library before fixing:
# it marks "org/mm-shared-tabforge" PUBLIC=1 (wrongly exempted). Fixed by
# splitting at the LAST tab, and by never trusting a proven-public value
# that still contains a tab after that split. The private mention must
# still block.
TAB=$(printf '\t')
MEDIUM_YAML="projects:
  - name: mm-private
    repo: org/mm-shared-tabforge
  - name: nn-public
    public: true
    repos:
      - org/mm-shared-tabforge${TAB}3
"
sandbox=$(make_sandbox_with_remotes "$MEDIUM_YAML" "$NEUTRAL_ORIGIN_URL")
printf 'Reproduces in org/mm-shared-tabforge as well.\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
assert_hook "MEDIUM: a tab-forged line number does not exempt the real private token" "$sandbox" 2 "File: notes.md" "mm-shared-tabforge"
rm -rf "$sandbox"

echo
echo "== Round 9 (Rex B8): a trailing comment on a repos: item does not become private words"
#
# apexyard#1457 round 9 — round 8's word-split ran on dev's whole-line
# capture of a repos: block-list item, which includes a trailing YAML
# comment verbatim ("- acme-org/dd-one  # primary service" -> dev value
# "acme-org/dd-one  # primary service"). Splitting that on whitespace
# alone produced "#", "primary", and "service" as standalone private
# tokens, and "#" then blocked every Markdown heading. Fixed by
# stripping a trailing "[[:space:]]+#.*$" comment before the split. The
# real slug must still block. All names/slugs SYNTHETIC.

B8_YAML='projects:
  - name: dd-priv-b8
    repos:
      - acme-org/dd-one  # primary service
'
sandbox=$(make_sandbox_with_remotes "$B8_YAML" "$NEUTRAL_ORIGIN_URL")
printf '# Release notes\n\nSee the changelog.\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
assert_hook "B8: a Markdown heading (# ...) is not blocked by a commented repos: item" "$sandbox" 0 "" ""
rm -rf "$sandbox"

sandbox=$(make_sandbox_with_remotes "$B8_YAML" "$NEUTRAL_ORIGIN_URL")
printf 'This is the primary service for the team.\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
assert_hook "B8: the comment's own words (primary service) are not blocked" "$sandbox" 0 "" ""
rm -rf "$sandbox"

sandbox=$(make_sandbox_with_remotes "$B8_YAML" "$NEUTRAL_ORIGIN_URL")
printf 'Reproduces in acme-org/dd-one as well.\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
assert_hook "B8: the real slug (acme-org/dd-one) still blocks" "$sandbox" 2 "File: notes.md" "dd-one"
rm -rf "$sandbox"

echo
echo "== apexyard#1458 items 1-3: follow-up to #1457"
#
# Each is verified to fail against the PRE-fix library before the
# corresponding fix landed (see the differential-test probes and the PR
# description). All names/slugs SYNTHETIC.

# Item 1 — a comment-only repos: block-list item ("- # note") is one dev
# token whose value IS the comment, with no whitespace before the "#" for
# the old split_words() strip to anchor on. It split into "#" and "note"
# as their own standalone tokens; "#" then blocked every Markdown
# heading.
IT1_YAML='projects:
  - name: ee-priv-it1
    repos:
      - acme-org/it1-target
      - # note
'
sandbox=$(make_sandbox_with_remotes "$IT1_YAML" "$NEUTRAL_ORIGIN_URL")
printf '# Release notes\n\nSee the changelog.\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
assert_hook "IT1: a Markdown heading (# ...) is not blocked by a comment-only repos: item" "$sandbox" 0 "" ""
rm -rf "$sandbox"

sandbox=$(make_sandbox_with_remotes "$IT1_YAML" "$NEUTRAL_ORIGIN_URL")
printf 'Please note the deadline.\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
assert_hook "IT1: the comment word (note) is not blocked" "$sandbox" 0 "" ""
rm -rf "$sandbox"

sandbox=$(make_sandbox_with_remotes "$IT1_YAML" "$NEUTRAL_ORIGIN_URL")
printf 'Reproduces in acme-org/it1-target as well.\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
assert_hook "IT1: the real slug (acme-org/it1-target) still blocks" "$sandbox" 2 "File: notes.md" "it1-target"
rm -rf "$sandbox"

# Item 2 — DROPPED (round 11, Hakim HIGH-1). The GARBAGE classification
# round 10 added here (exempting a nested "- name:" line whenever it sat
# deeper than the entry's own dash column) could not tell a genuinely
# nested sub-item from a real project entry that legitimately sits
# deeper than the FIRST entry's column. GA1/GA2/GA5 below are the three
# valid YAML shapes Hakim found where that column test wrongly exempted
# a REAL private project name. dev over-blocks a nested "- name:" (item
# 2's original report); that stays an accepted usability gap, not a
# leak — see AgDR-0180. These three cases must still BLOCK.

# GA1 — grouped projects: a "- group:" entry (not "- name:") holding a
# nested "projects:" list with a real project entry inside it.
GA1_YAML='projects:
  - group: team-a
    projects:
      - name: priv-ga1
        repo: acme-org/priv-ga1-repo
        workspace: workspace/priv-ga1
'
sandbox=$(make_sandbox_with_remotes "$GA1_YAML" "$NEUTRAL_ORIGIN_URL")
printf 'See priv-ga1 today.\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
assert_hook "GA1: a real project name nested under a - group: entry still blocks" "$sandbox" 2 "File: notes.md" "priv-ga1"
rm -rf "$sandbox"

# GA2 — projects: as a map of lists, with "archived:" indented MORE
# deeply than "active:". The uneven indentation makes the deeper entry
# look nested inside the shallower one to a column-only reader.
GA2_YAML='projects:
  active:
    - name: priv-ga2a
      repo: acme-org/priv-ga2a-repo
  archived:
      - name: priv-ga2b
        repo: acme-org/priv-ga2b-repo
'
sandbox=$(make_sandbox_with_remotes "$GA2_YAML" "$NEUTRAL_ORIGIN_URL")
printf 'See priv-ga2b today.\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
assert_hook "GA2: a real project name in an unevenly-indented archived: list still blocks" "$sandbox" 2 "File: notes.md" "priv-ga2b"
rm -rf "$sandbox"

# GA5 — an entry that is itself a sequence: a bare "-" opens a nested
# list, and the real project entry is the nested "- name:" inside it.
GA5_YAML='projects:
  -
    - name: priv-ga5
      repo: acme-org/priv-ga5-repo
'
sandbox=$(make_sandbox_with_remotes "$GA5_YAML" "$NEUTRAL_ORIGIN_URL")
printf 'See priv-ga5 today.\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
assert_hook "GA5: a real project name nested under a bare - sequence entry still blocks" "$sandbox" 2 "File: notes.md" "priv-ga5"
rm -rf "$sandbox"

# Item 3 — re-verified against the current (post-#1457 round 9) library:
# a public entry's own slug, written as a one-key "- repo:" map item
# inside its own repos: list, is correctly exempted already (the greedy
# private scan this was originally reported against, PR #1457 rounds
# 4-6, was deleted outright in round 7). Regression coverage only, no
# code change for this item.
IT3_YAML='projects:
  - name: gg-pub-it3
    public: true
    repos:
      - repo: acme-org/it3-pub-repo
'
sandbox=$(make_sandbox_with_remotes "$IT3_YAML" "$NEUTRAL_ORIGIN_URL")
printf 'See acme-org/it3-pub-repo for source.\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
assert_hook "IT3: a public entry own slug via a - repo: map item does not block" "$sandbox" 0 "" ""
rm -rf "$sandbox"

echo
echo "== apexyard#1458 round 11 (Rex B1): the runtime hook must not treat a"
echo "   roles:/tags: list after repos: as private repo tokens"
#
# Round 10's item-4 fix (moving in_repos = 0 into BEGIN {}) closed the
# leak gap but opened an over-block: in_repos closed only on a line
# starting at column 0, which never happens inside an indented
# projects: block, so a roles: or tags: list after a repos: block had
# every dash item wrongly captured as REPO=. Fixed by tracking the
# repos: key's own column and closing on any sibling key at or left of
# it, mirroring item 6's standard-extraction fix.
B1_YAML='projects:
  - name: aa-app-b1
    repos:
      - acme-org/aa-one-b1
    roles:
      - tech-lead
      - sre
    tags:
      - internal
  - name: bb-app-b1
    tags:
      - customer-facing
'
sandbox=$(make_sandbox_with_remotes "$B1_YAML" "$NEUTRAL_ORIGIN_URL")
runtime_output=$(cd "$sandbox" && .claude/hooks/check-private-refs-runtime.sh "me2resh/apexyard" 'This is internal tooling for the sre team.' '' 2>&1); runtime_rc=$?
if [ "$runtime_rc" = "0" ]; then
  pass "B1: a role/tag word (sre, internal) after repos: does not block"
else
  fail "B1: a role/tag word (sre, internal) after repos: does not block" "$runtime_output"
fi
rm -rf "$sandbox"

sandbox=$(make_sandbox_with_remotes "$B1_YAML" "$NEUTRAL_ORIGIN_URL")
runtime_output=$(cd "$sandbox" && .claude/hooks/check-private-refs-runtime.sh "me2resh/apexyard" 'Ping the tech-lead about the revenue report.' '' 2>&1); runtime_rc=$?
if [ "$runtime_rc" = "0" ]; then
  pass "B1: a role word (tech-lead) from a later entry does not block"
else
  fail "B1: a role word (tech-lead) from a later entry does not block" "$runtime_output"
fi
rm -rf "$sandbox"

sandbox=$(make_sandbox_with_remotes "$B1_YAML" "$NEUTRAL_ORIGIN_URL")
runtime_output=$(cd "$sandbox" && .claude/hooks/check-private-refs-runtime.sh "me2resh/apexyard" 'Reproduces in acme-org/aa-one-b1 as well.' '' 2>&1); runtime_rc=$?
if [ "$runtime_rc" = "2" ] && ! printf '%s' "$runtime_output" | grep -qF 'aa-one-b1'; then
  pass "B1: the real repo item (acme-org/aa-one-b1) still blocks"
else
  fail "B1: the real repo item (acme-org/aa-one-b1) still blocks" "$runtime_output"
fi
rm -rf "$sandbox"

sandbox=$(make_sandbox_with_remotes "$B1_YAML" "$NEUTRAL_ORIGIN_URL")
runtime_output=$(cd "$sandbox" && .claude/hooks/check-private-refs-runtime.sh "me2resh/apexyard" 'Private reference: aa-app-b1' '' 2>&1); runtime_rc=$?
if [ "$runtime_rc" = "2" ] && ! printf '%s' "$runtime_output" | grep -qF 'aa-app-b1'; then
  pass "B1: the real project name (aa-app-b1) still blocks"
else
  fail "B1: the real project name (aa-app-b1) still blocks" "$runtime_output"
fi
rm -rf "$sandbox"

# The differential superset check cannot catch this class of bug: extra
# tokens (a false positive) still pass a "never fewer than dev" test. A
# direct hook-level assertion against the SHIPPED example registry is
# the only thing that catches it — this is the exact file Rex found
# still over-blocking at 6ac5626 (tech-lead, backend-engineer,
# platform-engineer, customer-facing all leaked as REPO= tokens).
EXAMPLE_REGISTRY="$ROOT/apexyard.projects.yaml.example"
if [ -f "$EXAMPLE_REGISTRY" ]; then
  sandbox=$(mktemp -d)
  mkdir -p "$sandbox/.claude/hooks"
  cp "$RUNTIME_SRC" "$sandbox/.claude/hooks/check-private-refs-runtime.sh"
  cp "$PARSER_LIB_SRC" "$sandbox/.claude/hooks/_lib-registry-parser.sh"
  chmod +x "$sandbox/.claude/hooks/check-private-refs-runtime.sh"
  cp "$EXAMPLE_REGISTRY" "$sandbox/apexyard.projects.yaml"
  (
    cd "$sandbox" || exit 1
    git init -q
    git config user.email test@example.com
    git config user.name Test
    git add apexyard.projects.yaml
    git commit -q -m baseline
    git remote add origin "$NEUTRAL_ORIGIN_URL"
  )
  runtime_output=$(cd "$sandbox" && .claude/hooks/check-private-refs-runtime.sh "me2resh/apexyard" 'Ping the tech-lead about the revenue report.' '' 2>&1); runtime_rc=$?
  if [ "$runtime_rc" = "0" ]; then
    pass "B1: the shipped apexyard.projects.yaml.example does not block a role-name word"
  else
    fail "B1: the shipped apexyard.projects.yaml.example does not block a role-name word" "$runtime_output"
  fi
  rm -rf "$sandbox"
else
  fail "B1: apexyard.projects.yaml.example must exist for this test" "not found at $EXAMPLE_REGISTRY"
fi

echo
echo "===== test_check_private_refs_staged.sh ====="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[ "$FAIL" -eq 0 ]
