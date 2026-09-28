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

# 9. Origin-owner-only case — the owner-login exemption must work on its
#    own for `origin`, with no `upstream` remote configured at all. This
#    isolates the ORIGIN half of the owner branch from the upstream half
#    case 2/5/6 already cover.
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
assert_hook "origin-owner-only: owner/repo form of ORIGIN's own owner does not block (no upstream)" "$sandbox" 0 "" ""
rm -rf "$sandbox"

sandbox=$(make_sandbox_with_remotes "$ORIGIN_OWNER_REGISTRY_YAML" "$FORK_ORIGIN_URL")
printf 'The atlas-fork account needs review.\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
assert_hook "origin-owner-only: a bare mention of ORIGIN's owner still blocks (no upstream)" "$sandbox" 2 "File: notes.md" "atlas-fork"
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
printf 'Discovered while touching secret-app during the rebuild.\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
assert_hook "case A2: workspace:-first private entry after a public one still blocks" "$sandbox" 2 "File: notes.md" "secret-app"
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

# CRLF registry — Hakim LOW-3. A CRLF-terminated private entry (no public
# flag) must still block; a CRLF-terminated PUBLIC entry must still pass.
sandbox=$(make_sandbox_with_remotes "$CASE_A_YAML" "$NEUTRAL_ORIGIN_URL")
printf 'projects:\r\n  - name: secret-app\r\n    repo: acme-org/secret-app\r\n    workspace: workspace/secret-app\r\n' > "$sandbox/apexyard.projects.yaml"
printf 'Discovered while touching secret-app during the rebuild.\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
assert_hook "CRLF registry — a private entry still blocks" "$sandbox" 2 "File: notes.md" "secret-app"
rm -rf "$sandbox"

sandbox=$(make_sandbox_with_remotes "$CASE_A_YAML" "$NEUTRAL_ORIGIN_URL")
printf 'projects:\r\n  - name: open-site\r\n    repo: acme-org/open-site\r\n    public: true\r\n    workspace: workspace/open-site\r\n' > "$sandbox/apexyard.projects.yaml"
printf 'See acme-org/open-site for the open-site launch.\n' > "$sandbox/notes.md"
git -C "$sandbox" add notes.md
assert_hook "CRLF registry — a public entry still passes" "$sandbox" 0 "" ""
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
echo "===== test_check_private_refs_staged.sh ====="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[ "$FAIL" -eq 0 ]
