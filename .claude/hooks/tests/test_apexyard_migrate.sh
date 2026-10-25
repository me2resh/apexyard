#!/bin/bash
# Test for `apexyard migrate` (bin/_lib-migrate.sh). Temp dir + fake gh only.
# Never talks to real GitHub. Exit 0 when every case passes.

set -u
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"

SRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../../.." && pwd)"
CLI="$SRC_ROOT/bin/apexyard"
LIB="$SRC_ROOT/bin/_lib-migrate.sh"
[ -f "$CLI" ] && [ -f "$LIB" ] || { echo "FAIL: missing CLI/lib" >&2; exit 1; }

PASS=0; FAIL=0; FAILED=""
mark_pass() { echo "  PASS $1"; PASS=$((PASS+1)); }
mark_fail() { echo "  FAIL $1: $2" >&2; FAIL=$((FAIL+1)); FAILED="$FAILED\n  - $1"; }

install_fake_gh() {
  mkdir -p "$1" "$FAKE_GH_STATE"
  cat > "$1/gh" <<'EOS'
#!/bin/bash
set -u
printf '%s\n' "$*" >> "${FAKE_GH_STATE}/calls.log"
if [ "${1:-}" = "repo" ] && [ "${2:-}" = "view" ]; then
  shift 2; target=""; json_flag=""; q_flag=""
  while [ $# -gt 0 ]; do
    case "$1" in --json) json_flag="$2"; shift 2 ;; -q) q_flag="$2"; shift 2 ;; --*) shift ;; *) target="$1"; shift ;; esac
  done
  if [ -z "$target" ]; then
    printf '%s\n' '{"isFork":true,"parent":{"nameWithOwner":"me2resh/apexyard","url":"'"${UPSTREAM_BARE}"'"}}'
    exit 0
  fi
  created="${FAKE_GH_STATE}/created-${target//\//_}"
  [ -f "$created" ] || exit 1
  url=$(cat "$created")
  [ "$q_flag" = ".url" ] && { printf '%s\n' "$url"; exit 0; }
  [ "$json_flag" = "url" ] && { printf '{"url":"%s"}\n' "$url"; exit 0; }
  exit 0
fi
if [ "${1:-}" = "repo" ] && [ "${2:-}" = "create" ]; then
  shift 2; name=""
  while [ $# -gt 0 ]; do
    case "$1" in --private|--public) shift ;; --source|--push) echo "refuse" >&2; exit 2 ;; --*) shift ;; *) name="$1"; shift ;; esac
  done
  [ -n "$name" ] || exit 2
  bare="${FAKE_GH_STATE}/bare-${name//\//_}.git"
  git init --bare -q "$bare"
  printf '%s\n' "$bare" > "${FAKE_GH_STATE}/created-${name//\//_}"
  exit 0
fi
if [ "${1:-}" = "repo" ] && { [ "${2:-}" = "archive" ] || [ "${2:-}" = "delete" ]; }; then
  echo "archive/delete must not be called" >&2; exit 99
fi
exit 0
EOS
  chmod +x "$1/gh"
}

reset_gh_state() {
  FAKE_GH_STATE="$1"
  mkdir -p "$FAKE_GH_STATE"
  export FAKE_GH_STATE
  : > "$FAKE_GH_STATE/calls.log"
  install_fake_gh "$FAKE_GH_BIN"
}

build_fixture() {
  local root="$1" upstream="$2" origin_bare pair
  mkdir -p "$root/.claude/migrations" "$root/bin" "$root/.claude/hooks"
  cp "$SRC_ROOT/.claude/hooks/_lib-migration-chain.sh" "$root/.claude/hooks/"
  printf '%s\n' 'v5.4.0' > "$root/.claude/framework-version"
  : > "$root/onboarding.yaml"; : > "$root/apexyard.projects.yaml"; : > "$root/.apexyard-fork"
  cat > "$root/bin/_lib-ownership.sh" <<'EOS'
ownership_class() { printf '%s\n' 'framework'; }
ownership_is_security() { return 1; }
EOS
  for pair in v5.4.0-to-v5.5.0 v5.5.0-to-v5.6.0 v5.6.0-to-v5.7.0; do
    {
      echo '#!/bin/bash'
      echo "printf '%s\\n' '${pair}' >> \"\${OPS_ROOT}/.migration-ran\""
      echo 'exit 0'
    } > "$root/.claude/migrations/${pair}.sh"
    chmod +x "$root/.claude/migrations/${pair}.sh"
  done
  ln -sf "$SRC_ROOT/bin/apexyard" "$root/bin/apexyard"
  ln -sf "$SRC_ROOT/bin/_lib-migrate.sh" "$root/bin/_lib-migrate.sh"
  origin_bare="${FAKE_GH_STATE}/old-origin.git"
  git init --bare -q "$origin_bare"
  (
    cd "$root" || exit 99
    git init -q
    git config user.email t@t.t; git config user.name t
    printf '%s\n' 'main-1' > README.md
    git add onboarding.yaml apexyard.projects.yaml .apexyard-fork \
      .claude/framework-version README.md bin/_lib-ownership.sh \
      .claude/migrations .claude/hooks/_lib-migration-chain.sh >/dev/null 2>&1
    git commit -q -m c1 >/dev/null 2>&1
    git branch -M main
    printf '%s\n' 'main-2' >> README.md
    git add README.md && git commit -q -m c2 >/dev/null 2>&1
    git checkout -q -b other
    printf '%s\n' 'other-1' > other.txt
    git add other.txt && git commit -q -m c3 >/dev/null 2>&1
    git checkout -q main
    git tag -a v-fixture -m tag
    git remote add upstream "$upstream"
    git remote add origin "$origin_bare"
    git push -q origin main other >/dev/null 2>&1
    git push -q origin --tags >/dev/null 2>&1
  ) || return 1
}

run_migrate() {
  local root="$1"; shift
  (
    cd "$root" || exit 99
    export FAKE_GH_STATE
    OPS_ROOT="$root" APEXYARD_GH=gh PATH="$FAKE_GH_BIN:$PATH" \
      APEXYARD_BIN_DIR="$APEXYARD_BIN_DIR" \
      bash "$root/bin/apexyard" migrate "$@"
  )
}

BASE=$(mktemp -d) && BASE=$(cd "$BASE" && pwd -P)
FAKE_GH_BIN="$BASE/fake-bin"
APEXYARD_BIN_DIR="$BASE/local-bin"
UPSTREAM_BARE="$BASE/upstream.git"
export UPSTREAM_BARE
mkdir -p "$APEXYARD_BIN_DIR"
git init --bare -q "$UPSTREAM_BARE"
reset_gh_state "$BASE/gh-state"

# Case 1: path keep
F1="$BASE/fork1"; mkdir -p "$F1"; reset_gh_state "$BASE/gh-state-1"
if build_fixture "$F1" "$UPSTREAM_BARE"; then
  before_status=$(git -C "$F1" status --porcelain)
  before_refs=$(git -C "$F1" for-each-ref --format='%(refname) %(objectname)' | sort)
  before_head=$(git -C "$F1" rev-parse HEAD)
  rc=0; out=$(run_migrate "$F1" --path keep 2>&1) || rc=$?
  after_status=$(git -C "$F1" status --porcelain)
  after_refs=$(git -C "$F1" for-each-ref --format='%(refname) %(objectname)' | sort)
  after_head=$(git -C "$F1" rev-parse HEAD)
  if [ "$rc" -eq 0 ] && [ "$before_status" = "$after_status" ] \
    && [ "$before_refs" = "$after_refs" ] && [ "$before_head" = "$after_head" ] \
    && [ -L "$APEXYARD_BIN_DIR/apexyard" ]; then
    mark_pass "path keep: porcelain+refs unchanged, symlink installed"
  else
    mark_fail "case1 keep" "rc=$rc out=$out"
  fi
else mark_fail "case1 build" "build_fixture failed"; fi

# Case 2: path move
F2="$BASE/fork2"; mkdir -p "$F2"; reset_gh_state "$BASE/gh-state-2"
APEXYARD_BIN_DIR="$BASE/local-bin-2"; mkdir -p "$APEXYARD_BIN_DIR"
if build_fixture "$F2" "$UPSTREAM_BARE"; then
  src_branches=$(git -C "$F2" for-each-ref --format='%(refname:short)' refs/heads | sort)
  src_tags=$(git -C "$F2" for-each-ref --format='%(refname:short)' refs/tags | sort)
  src_count=$(git -C "$F2" rev-list --all --count)
  mkdir -p "$BASE/gitwrap2"
  cat > "$BASE/gitwrap2/git" <<'EOS'
#!/bin/bash
printf '%s\n' "$*" >> "${FAKE_GH_STATE}/git-calls.log"
_wrapdir=$(CDPATH='' cd "$(dirname "$0")" && pwd)
_PATH=""; _oldifs=$IFS; IFS=:
for _p in $PATH; do [ "$_p" = "$_wrapdir" ] && continue; _PATH="${_PATH:+$_PATH:}$_p"; done
IFS=$_oldifs; PATH="$_PATH" exec git "$@"
EOS
  chmod +x "$BASE/gitwrap2/git"; : > "$FAKE_GH_STATE/git-calls.log"
  rc=0
  out=$(
    cd "$F2" || exit 99
    export FAKE_GH_STATE
    OPS_ROOT="$F2" APEXYARD_GH=gh PATH="$BASE/gitwrap2:$FAKE_GH_BIN:$PATH" \
      APEXYARD_BIN_DIR="$APEXYARD_BIN_DIR" \
      bash "$F2/bin/apexyard" migrate --path move --new-repo owner/new-ops --yes
  ) || rc=$?
  new_bare=$(cat "$FAKE_GH_STATE/created-owner_new-ops" 2>/dev/null || true)
  dest_branches=""; dest_tags=""; dest_count=""
  if [ -n "$new_bare" ] && [ -d "$new_bare" ]; then
    dest_branches=$(git --git-dir="$new_bare" for-each-ref --format='%(refname:short)' refs/heads | sort)
    dest_tags=$(git --git-dir="$new_bare" for-each-ref --format='%(refname:short)' refs/tags | sort)
    dest_count=$(git --git-dir="$new_bare" rev-list --all --count)
  fi
  up_url=$(git -C "$F2" remote get-url upstream 2>/dev/null || true)
  old_fork=$(git -C "$F2" remote get-url old-fork 2>/dev/null || true)
  log=$(cat "$FAKE_GH_STATE/calls.log" 2>/dev/null || true)
  gitlog=$(cat "$FAKE_GH_STATE/git-calls.log" 2>/dev/null || true)
  if [ "$rc" -eq 0 ] && [ "$src_branches" = "$dest_branches" ] && [ "$src_tags" = "$dest_tags" ] \
    && [ "$src_count" = "$dest_count" ] && [ -n "$up_url" ] && [ -n "$old_fork" ] \
    && printf '%s\n' "$out" | grep -q 'Archive the old fork by hand' \
    && ! printf '%s\n' "$log" | grep -Eiq 'archive|delete' \
    && ! printf '%s\n' "$gitlog" | grep -E 'push' | grep -Eq -- '--force|[[:space:]]-f[[:space:]]|--force-with-lease|\+| --mirror| --delete'
  then
    mark_pass "path move: full history, remotes, archive text, no force/archive/delete"
  else
    mark_fail "case2 move" "rc=$rc out=$out"
  fi
else mark_fail "case2 build" "build_fixture failed"; fi

# Case 3: refusals
F3="$BASE/fork3"; mkdir -p "$F3"; reset_gh_state "$BASE/gh-state-3"
if build_fixture "$F3" "$UPSTREAM_BARE"; then
  printf '%s\n' "$BASE/preexist.git" > "$FAKE_GH_STATE/created-owner_exists"
  git init --bare -q "$BASE/preexist.git"
  out=$(run_migrate "$F3" --path move --new-repo owner/exists 2>&1) && rc=0 || rc=$?
  if [ "$rc" -eq 1 ] && printf '%s\n' "$out" | grep -qi 'already exists'; then
    mark_pass "move refuses when new repo exists"
  else mark_fail "case3 exists" "rc=$rc out=$out"; fi
  out=$(run_migrate "$F3" --path move 2>&1) && rc=0 || rc=$?
  if [ "$rc" -eq 1 ] && printf '%s\n' "$out" | grep -qi 'new-repo'; then
    mark_pass "move refuses without --new-repo"
  else mark_fail "case3 no-new-repo" "rc=$rc out=$out"; fi
else mark_fail "case3 build" "build_fixture failed"; fi

# Case 4: chain
F4="$BASE/fork4"; mkdir -p "$F4"; reset_gh_state "$BASE/gh-state-4"
if build_fixture "$F4" "$UPSTREAM_BARE"; then
  out=$(run_migrate "$F4" --target v5.7.0 2>&1) || true
  o1=$(printf '%s\n' "$out" | grep -n 'v5.4.0-to-v5.5.0' | head -1 | cut -d: -f1)
  o2=$(printf '%s\n' "$out" | grep -n 'v5.5.0-to-v5.6.0' | head -1 | cut -d: -f1)
  o3=$(printf '%s\n' "$out" | grep -n 'v5.6.0-to-v5.7.0' | head -1 | cut -d: -f1)
  if [ -n "$o1" ] && [ -n "$o2" ] && [ -n "$o3" ] && [ "$o1" -lt "$o2" ] && [ "$o2" -lt "$o3" ]; then
    mark_pass "chain from v5.4.0 prints every step in order"
  else mark_fail "case4 chain print" "out=$out"; fi
  rm -f "$F4/.migration-ran"
  rc=0; out=$(run_migrate "$F4" --target v5.7.0 --run-migrations 2>&1) || rc=$?
  ran=$(cat "$F4/.migration-ran" 2>/dev/null || true)
  anchor=$(cat "$F4/.claude/framework-version" 2>/dev/null || true)
  expected=$(printf '%s\n' 'v5.4.0-to-v5.5.0' 'v5.5.0-to-v5.6.0' 'v5.6.0-to-v5.7.0')
  if [ "$rc" -eq 0 ] && [ "$ran" = "$expected" ] && [ "$anchor" = "v5.7.0" ]; then
    mark_pass "--run-migrations runs stubs in order; anchor=target"
  else mark_fail "case4 run" "rc=$rc ran='$ran' anchor='$anchor'"; fi
  out=$(run_migrate "$F4" --target v5.7.0 2>&1) || true
  if printf '%s\n' "$out" | grep -q '(empty)'; then
    mark_pass "up-to-date repo prints empty chain"
  else mark_fail "case4 empty" "out=$out"; fi
else mark_fail "case4 build" "build_fixture failed"; fi

# Case 5: dry-run
F5="$BASE/fork5"; mkdir -p "$F5"; reset_gh_state "$BASE/gh-state-5"
APEXYARD_BIN_DIR="$BASE/local-bin-5"; mkdir -p "$APEXYARD_BIN_DIR"
if build_fixture "$F5" "$UPSTREAM_BARE"; then
  before_remotes=$(git -C "$F5" remote -v)
  rc=0; out=$(run_migrate "$F5" --path move --new-repo owner/dry --dry-run 2>&1) || rc=$?
  after_remotes=$(git -C "$F5" remote -v)
  log=$(cat "$FAKE_GH_STATE/calls.log" 2>/dev/null || true)
  if [ "$rc" -eq 0 ] && ! printf '%s\n' "$log" | grep -q 'repo create' \
    && [ ! -e "$APEXYARD_BIN_DIR/apexyard" ] && [ "$before_remotes" = "$after_remotes" ]; then
    mark_pass "--dry-run mutates nothing (no create, no symlink, no remote change)"
  else mark_fail "case5 dry-run" "rc=$rc out=$out"; fi
else mark_fail "case5 build" "build_fixture failed"; fi

# Case 7: a failing migration pair exits non-zero and writes no anchor
F7="$BASE/fork7"; mkdir -p "$F7"; reset_gh_state "$BASE/gh-state-7"
if build_fixture "$F7" "$UPSTREAM_BARE"; then
  printf '%s\n' '#!/bin/bash' 'exit 7' > "$F7/.claude/migrations/v5.5.0-to-v5.6.0.sh"
  rc=0; out=$(run_migrate "$F7" --target v5.7.0 --run-migrations 2>&1) || rc=$?
  anchor=$(cat "$F7/.claude/framework-version" 2>/dev/null || true)
  if [ "$rc" -ne 0 ] && [ "$anchor" = "v5.4.0" ]; then
    mark_pass "failing migration pair exits non-zero and leaves the anchor"
  else mark_fail "case7 failing pair" "rc=$rc anchor='$anchor' out=$out"; fi
else mark_fail "case7 build" "build_fixture failed"; fi

# Case 8: path move copies branches that exist only on the old fork
F8="$BASE/fork8"; mkdir -p "$F8"; reset_gh_state "$BASE/gh-state-8"
APEXYARD_BIN_DIR="$BASE/local-bin-8"; mkdir -p "$APEXYARD_BIN_DIR"
if build_fixture "$F8" "$UPSTREAM_BARE"; then
  git -C "$F8" push -q origin main:refs/heads/remote-only >/dev/null 2>&1
  git -C "$F8" fetch -q origin >/dev/null 2>&1
  rc=0; out=$(run_migrate "$F8" --path move --new-repo owner/rem --yes 2>&1) || rc=$?
  new_bare=$(cat "$FAKE_GH_STATE/created-owner_rem" 2>/dev/null || true)
  if [ "$rc" -eq 0 ] && [ -n "$new_bare" ] \
    && git --git-dir="$new_bare" show-ref --verify --quiet refs/heads/remote-only \
    && ! git --git-dir="$new_bare" show-ref --verify --quiet refs/heads/HEAD; then
    mark_pass "path move copies old-fork-only branches without force"
  else mark_fail "case8 remote branches" "rc=$rc out=$out"; fi
else mark_fail "case8 build" "build_fixture failed"; fi

# Case 9: apexyard update works after each path
if grep -Eq '^  (init\|)?update\)' "$CLI"; then
  for p in keep move; do
    F9="$BASE/fork9$p"; mkdir -p "$F9"; reset_gh_state "$BASE/gh-state-9$p"
    APEXYARD_BIN_DIR="$BASE/local-bin-9$p"; mkdir -p "$APEXYARD_BIN_DIR"
    build_fixture "$F9" "$UPSTREAM_BARE" || { mark_fail "case9 build" "$p"; continue; }
    if [ "$p" = move ]; then run_migrate "$F9" --path move --new-repo "owner/upd" --yes >/dev/null 2>&1
    else run_migrate "$F9" --path keep >/dev/null 2>&1; fi
    # run_migrate appends "migrate"; call the CLI directly for update.
    out=$(cd "$F9" && OPS_ROOT="$F9" PATH="$FAKE_GH_BIN:$PATH" bash "$F9/bin/apexyard" update --check 2>&1 </dev/null) || true
    if printf '%s\n' "$out" | grep -qi 'unknown command'; then
      mark_fail "case9 update after $p" "$out"
    else mark_pass "apexyard update is recognised after path $p"; fi
  done
else
  echo "  SKIP apexyard update after paths: 'update' command absent from bin/apexyard"
fi

# Case 6: safety grep
scan_file() {
  local f="$1" hits push_f
  hits=$(grep -nE '(\brm[[:space:]]|git[[:space:]]+branch[[:space:]]+-[dD]|--force\b|--force-with-lease|--delete\b|\+[A-Za-z0-9_./-]+:|--mirror\b|repo[[:space:]]+delete|repo[[:space:]]+archive|reset[[:space:]]+--hard|git[[:space:]]+clean\b)' "$f" \
    | grep -vE '^[0-9]+:[[:space:]]*#' | grep -vE '^[0-9]+:[[:space:]]*printf' || true)
  push_f=$(grep -nE 'push' "$f" | grep -E '[[:space:]]-f[[:space:]]|[[:space:]]-f$' \
    | grep -vE '^[0-9]+:[[:space:]]*#' | grep -vE '^[0-9]+:[[:space:]]*printf' || true)
  hits=$(printf '%s\n%s\n' "$hits" "$push_f" | grep -v '^$' || true)
  [ -z "$hits" ] || { printf '%s\n' "$hits"; return 1; }
}
extract_migrate_branch() {
  awk '/^  migrate\)/{on=1} on{print} on && /^    ;;$/{exit}' "$CLI"
}
tmp_branch=$(mktemp); extract_migrate_branch > "$tmp_branch"
if scan_file "$LIB" && scan_file "$tmp_branch"; then
  mark_pass "grep: no forbidden patterns on executable lines"
else mark_fail "case6 safety grep" "forbidden pattern on executable line"; fi
rm -f "$tmp_branch"
rm -rf "$BASE" 2>/dev/null

echo ""
echo "apexyard migrate test: PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -ne 0 ]; then
  # shellcheck disable=SC2059
  printf "FAILED:$FAILED\n" >&2
  exit 1
fi
exit 0
