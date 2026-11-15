#!/usr/bin/env bash
# apexyard check — run local advisory gate checks on the current branch.
# Exit 0 when every check passes or is not verified. Exit 1 on any fail.
# Exit 2 on resolution or usage errors. Writes no repo file, marker, or index.
set -u

ADVISORY='this is a local result. The required check on the pull request decides.'
CHECK_ORDER='pre-push configured-pre-push branch-name commit-format commit-refs secrets'

usage() {
  cat <<'EOF'
Usage: apexyard check [--repo <name|owner/name>] [--json]

Run the pre-push scripts and the branch-name, commit-format, commit-refs,
and secrets hooks against the resolved working tree. The result is advisory.
The required check on the pull request decides.

  --repo <name|owner/name>  Select a registered project.
  --json                    Print one JSON object with one record per check.
  -h, --help                Show this help.

JSON shape:
  {"repo","branch","base","advisory","checks":[{"name","status","message"}]}
  status is pass, fail, or not_verified.
EOF
}

fail_usage() {
  printf '%s\n' "$1" >&2
  exit 2
}

json=0
selector=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo)
      [ "$#" -gt 1 ] && [ -n "$2" ] || fail_usage '--repo requires a value'
      selector=$2
      shift 2
      ;;
    --json) json=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) fail_usage "Unknown option: $1" ;;
    *) fail_usage "Unknown argument: $1" ;;
  esac
done

ops_root=${APEXYARD_CHECK_OPS_ROOT:-}
[ -n "$ops_root" ] || fail_usage 'apexyard check: ops root is not set'

lib_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=bin/_lib-repo-resolve.sh
# shellcheck disable=SC1091
source "$lib_dir/_lib-repo-resolve.sh"

export APEXYARD_DISABLE_RESOLUTION_CACHE=1
resolved_repo=''
resolved_clone=''
repo_resolve "$ops_root" "$selector" "$PWD" "$json" || exit 2
repo=$resolved_repo
clone=$resolved_clone
[ -d "$clone" ] || {
  printf 'apexyard: no clone of %s at %s. Clone it first:\n' "$repo" "$clone" >&2
  printf 'gh repo clone %s %s\n' "$repo" "$clone" >&2
  exit 2
}

normalize_origin() {
  local origin=$1
  origin=${origin%.git}
  case "$origin" in
    *://*) origin=${origin#*://}; origin=${origin#*/} ;;
    *@*:*) origin=${origin#*:} ;;
  esac
  printf '%s' "$origin"
}

# Prefer the current tree when its origin matches the resolved repo (worktree-safe).
tree=$clone
current_top=$(git rev-parse --show-toplevel 2>/dev/null) || current_top=''
if [ -n "$current_top" ]; then
  current_origin=$(git -C "$current_top" remote get-url origin 2>/dev/null) || current_origin=''
  current_origin=$(normalize_origin "$current_origin")
  if [ -n "$current_origin" ] && [ "$current_origin" = "$repo" ]; then
    tree=$(cd "$current_top" && pwd -P)
  fi
fi
clone=$(cd "$clone" && pwd -P)

# The commit hooks read the message path from a command string, so the path
# must hold no space or shell character. Use /tmp when TMPDIR is not safe.
tmp_base=${TMPDIR:-/tmp}
case "$tmp_base" in
  *[!A-Za-z0-9/._-]*) tmp_base=/tmp ;;
esac
tmpdir=$(mktemp -d "${tmp_base%/}/apexyard-check.XXXXXX") || exit 2
trap 'rm -rf "$tmpdir"' EXIT

mkdir -p "$tmpdir/results"
progress() {
  if [ "$json" = 1 ]; then
    printf '%s\n' "$*" >&2
  fi
}

record() {
  local name=$1 status=$2 message=$3
  printf '%s\n' "$status" > "$tmpdir/results/$name.status"
  printf '%s' "$message" > "$tmpdir/results/$name.message"
}

collapse_msg() {
  # First lines, single-line display. Keep enough of the hook text for diagnosis.
  printf '%s' "$1" | tr '\n' ' ' | sed 's/[[:space:]]\{1,\}/ /g; s/^[[:space:]]*//; s/[[:space:]]*$//' | cut -c1-400
}

run_script_check() {
  local name=$1 script=$2
  local out rc=0
  if [ ! -f "$tree/bin/$script" ]; then
    record "$name" not_verified "script not found"
    return 0
  fi
  progress "checking $name"
  out=$tmpdir/$name.out
  (cd "$tree" && bash "bin/$script") >"$out" 2>&1 || rc=$?
  if [ "$rc" -eq 0 ] && grep -q 'bypassed by skip marker' "$out"; then
    record "$name" not_verified 'skipped by skip marker in HEAD commit message'
  elif [ "$rc" -eq 0 ]; then
    record "$name" pass ''
  elif [ "$rc" -eq 1 ]; then
    record "$name" fail "$(collapse_msg "$(tail -n 20 "$out")")"
  else
    record "$name" not_verified "exit $rc"
  fi
}

hooks_dir=''
if [ -d "$tree/.claude/hooks" ]; then
  hooks_dir="$tree/.claude/hooks"
elif [ -d "$ops_root/.claude/hooks" ]; then
  hooks_dir="$ops_root/.claude/hooks"
fi

have_jq=0
command -v jq >/dev/null 2>&1 && have_jq=1

branch=$(git -C "$tree" branch --show-current 2>/dev/null) || branch=''
detached=0
[ -n "$branch" ] || detached=1

# The base is the integration branch nearest to HEAD, so a repo that merges
# to dev while origin/HEAD names main still gets the right commit range.
base=''
best=''
for candidate in refs/remotes/origin/HEAD origin/main origin/dev origin/master; do
  git -C "$tree" rev-parse --verify "$candidate" >/dev/null 2>&1 || continue
  count=$(git -C "$tree" rev-list --count "$candidate"..HEAD 2>/dev/null) || continue
  if [ -z "$best" ] || [ "$count" -lt "$best" ]; then
    best=$count
    base=$candidate
  fi
done

run_hook() {
  # $1 name, $2 hook file, $3 command string
  local name=$1 hook_file=$2 cmd=$3
  local payload out err rc=0
  if [ "$have_jq" -ne 1 ]; then
    record "$name" not_verified 'jq not found'
    return 0
  fi
  if [ -z "$hooks_dir" ] || [ ! -f "$hooks_dir/$hook_file" ]; then
    record "$name" not_verified 'hook not found'
    return 0
  fi
  payload=$(jq -n --arg cwd "$tree" --arg cmd "$cmd" \
    '{cwd:$cwd, tool_input:{command:$cmd}}') || {
    record "$name" not_verified 'could not build payload'
    return 0
  }
  out=$tmpdir/$name.out
  err=$tmpdir/$name.err
  printf '%s' "$payload" | bash "$hooks_dir/$hook_file" >"$out" 2>"$err" || rc=$?
  if [ "$rc" -eq 0 ]; then
    record "$name" pass ''
  elif [ "$rc" -eq 2 ]; then
    record "$name" fail "$(collapse_msg "$(cat "$err")")"
  else
    record "$name" not_verified "exit $rc"
  fi
}

run_script_check pre-push run-pre-push-checks.sh
run_script_check configured-pre-push run-configured-pre-push-checks.sh

progress 'checking branch-name'
if [ "$detached" -eq 1 ]; then
  record branch-name not_verified 'detached HEAD'
elif [ "$have_jq" -ne 1 ]; then
  record branch-name not_verified 'jq not found'
elif [ -z "$hooks_dir" ] || [ ! -f "$hooks_dir/validate-branch-name.sh" ]; then
  record branch-name not_verified 'hook not found'
else
  run_hook branch-name validate-branch-name.sh "git push origin $branch"
fi

# Commit-format and commit-refs: one synthetic commit command per commit, aggregated.
aggregate_commit_hook() {
  local name=$1 hook_file=$2 need_gh=$3
  local sha msg_file cmd rc any_fail=0 any_nv=0 nv_reason='' fail_msg='' out err
  if [ "$detached" -eq 1 ]; then
    record "$name" not_verified 'detached HEAD'
    return 0
  fi
  if [ -z "$base" ]; then
    record "$name" not_verified 'no base ref'
    return 0
  fi
  if [ "$have_jq" -ne 1 ]; then
    record "$name" not_verified 'jq not found'
    return 0
  fi
  if [ -z "$hooks_dir" ] || [ ! -f "$hooks_dir/$hook_file" ]; then
    record "$name" not_verified 'hook not found'
    return 0
  fi
  if [ "$need_gh" = 1 ]; then
    if ! command -v "${APEXYARD_GH:-gh}" >/dev/null 2>&1; then
      record "$name" not_verified 'gh not found'
      return 0
    fi
  fi
  progress "checking $name"
  while IFS= read -r sha; do
    [ -n "$sha" ] || continue
    # Pass the message by file. The hooks read -F, and a file needs no quoting.
    msg_file=$tmpdir/commit-message
    case "$msg_file" in
      *[!A-Za-z0-9/._-]*)
        record "$name" not_verified 'temporary path is not safe'
        return 0
        ;;
    esac
    git -C "$tree" log -1 --format=%B "$sha" > "$msg_file"
    cmd="git commit -F $msg_file"
    out=$tmpdir/$name-$sha.out
    err=$tmpdir/$name-$sha.err
    payload=$(jq -n --arg cwd "$tree" --arg cmd "$cmd" \
      '{cwd:$cwd, tool_input:{command:$cmd}}') || {
      any_nv=1
      nv_reason='could not build payload'
      continue
    }
    rc=0
    printf '%s' "$payload" | bash "$hooks_dir/$hook_file" >"$out" 2>"$err" || rc=$?
    if [ "$rc" -eq 0 ]; then
      :
    elif [ "$rc" -eq 2 ]; then
      any_fail=1
      fail_msg=$(collapse_msg "$(cat "$err")")
      break
    else
      any_nv=1
      nv_reason="exit $rc"
    fi
  done < <(git -C "$tree" rev-list --no-merges --reverse "$base"..HEAD 2>/dev/null)

  if [ "$any_fail" -eq 1 ]; then
    record "$name" fail "$fail_msg"
  elif [ "$any_nv" -eq 1 ]; then
    record "$name" not_verified "$nv_reason"
  else
    record "$name" pass ''
  fi
}

aggregate_commit_hook commit-format validate-commit-format.sh 0
aggregate_commit_hook commit-refs verify-commit-refs.sh 1

progress 'checking secrets'
if [ "$have_jq" -ne 1 ]; then
  record secrets not_verified 'jq not found (scans staged changes)'
elif [ -z "$hooks_dir" ] || [ ! -f "$hooks_dir/check-secrets.sh" ]; then
  record secrets not_verified 'hook not found (scans staged changes)'
else
  # Scope: the secrets hook reads the staged diff only. Do not stage files.
  run_hook secrets check-secrets.sh 'git commit -m "chore: apexyard check secrets scan"'
  # Annotate the recorded message with the staged-changes scope.
  sec_status=$(cat "$tmpdir/results/secrets.status")
  sec_msg=$(cat "$tmpdir/results/secrets.message")
  case "$sec_status" in
    pass)
      record secrets pass 'scans staged changes'
      ;;
    fail)
      record secrets fail "scans staged changes: $sec_msg"
      ;;
    not_verified)
      if [ -n "$sec_msg" ]; then
        record secrets not_verified "$sec_msg (scans staged changes)"
      else
        record secrets not_verified 'scans staged changes'
      fi
      ;;
  esac
fi

any_fail=0
for name in $CHECK_ORDER; do
  status=$(cat "$tmpdir/results/$name.status")
  [ "$status" != fail ] || any_fail=1
done

if [ "$json" = 1 ]; then
  # Build JSON with jq when available; otherwise emit a minimal hand-built object.
  if [ "$have_jq" -eq 1 ]; then
    checks_json='[]'
    for name in $CHECK_ORDER; do
      status=$(cat "$tmpdir/results/$name.status")
      message=$(cat "$tmpdir/results/$name.message")
      checks_json=$(jq -c -n --argjson arr "$checks_json" --arg name "$name" \
        --arg status "$status" --arg message "$message" \
        '$arr + [{name:$name, status:$status, message:$message}]')
    done
    jq -n --arg repo "$repo" --arg branch "$branch" --arg base "$base" \
      --arg advisory "$ADVISORY" --argjson checks "$checks_json" \
      '{repo:$repo, branch:$branch, base:$base, advisory:$advisory, checks:$checks}'
  else
    printf '{"repo":'
    repo_json_string "$repo"
    printf ',"branch":'
    repo_json_string "$branch"
    printf ',"base":'
    repo_json_string "$base"
    printf ',"advisory":'
    repo_json_string "$ADVISORY"
    printf ',"checks":['
    first=1
    for name in $CHECK_ORDER; do
      status=$(cat "$tmpdir/results/$name.status")
      message=$(cat "$tmpdir/results/$name.message")
      [ "$first" = 1 ] || printf ','
      first=0
      printf '{"name":'
      repo_json_string "$name"
      printf ',"status":'
      repo_json_string "$status"
      printf ',"message":'
      repo_json_string "$message"
      printf '}'
    done
    printf ']}\n'
  fi
else
  printf 'Repo: %s  Branch: %s\n' "$repo" "$branch"
  for name in $CHECK_ORDER; do
    status=$(cat "$tmpdir/results/$name.status")
    message=$(cat "$tmpdir/results/$name.message")
    case "$status" in
      pass)
        printf 'pass   %s\n' "$name"
        ;;
      fail)
        if [ -n "$message" ]; then
          printf 'FAIL   %s: %s\n' "$name" "$message"
        else
          printf 'FAIL   %s\n' "$name"
        fi
        ;;
      not_verified)
        if [ -n "$message" ]; then
          printf 'not verified   %s: %s\n' "$name" "$message"
        else
          printf 'not verified   %s\n' "$name"
        fi
        ;;
    esac
  done
  printf 'Advisory: %s\n' "$ADVISORY"
fi

[ "$any_fail" -eq 0 ] || exit 1
exit 0
