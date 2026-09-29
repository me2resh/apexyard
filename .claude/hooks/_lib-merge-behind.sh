#!/bin/bash
# _lib-merge-behind.sh — decide whether a PR's head is behind its base
# branch, without relying on the forge's own `mergeStateStatus` field.
#
# WHY THIS EXISTS (me2resh/apexyard#1386)
# ----------------------------------------
# GitHub reports `mergeStateStatus=BEHIND` only when the base branch's
# ruleset has `strict_required_status_checks_policy=true`. When that policy
# is off — the common case, and the case #1386's own issue body describes —
# GitHub instead reports `BLOCKED`, `CLEAN`, or `UNKNOWN` for a PR that is
# genuinely behind its base. A check that reads `mergeStateStatus == BEHIND`
# therefore misses the exact race it was written to catch: a PR 8 or 19
# commits behind an unprotected base branch reports `BLOCKED`, `CLEAN`, or
# `UNKNOWN`, never `BEHIND`.
#
# This library computes "behind" directly from the compare API instead,
# which reports the real commit graph and does not depend on any ruleset
# setting.
#
# PUBLIC FUNCTIONS
# -----------------
#   is_pr_behind_base <owner/repo> <base_branch> <head_sha>
#       Echoes one of: true | false | unknown
#       - "true"    the base branch has commits the head does not (behind_by > 0)
#       - "false"   the head has every commit the base branch has (behind_by == 0)
#       - "unknown" the lookup failed (network/auth, a non-zero exit code
#                    even when stdout printed a number) or an argument was
#                    empty — the caller decides what "unknown" means; this
#                    function never blocks and always exits 0.
#
# The caller supplies the base branch name and the head SHA — this library
# does not itself resolve them, so it stays testable with a stubbed `gh`
# and has no opinion on where those values came from.

is_pr_behind_base() {
  local repo="$1" base="$2" head_sha="$3"
  if [ -z "$repo" ] || [ -z "$base" ] || [ -z "$head_sha" ]; then
    echo "unknown"
    return 0
  fi

  local behind_by rc
  behind_by=$(gh api "repos/${repo}/compare/${base}...${head_sha}" -q '.behind_by' 2>/dev/null)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "unknown"
    return 0
  fi

  case "$behind_by" in
    ''|*[!0-9]*)
      echo "unknown"
      ;;
    0)
      echo "false"
      ;;
    *)
      echo "true"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# CHEAPER MERGE REFRESH (me2resh/apexyard#1437)
# ---------------------------------------------------------------------------
# Two independent cost-cutters for the behind-base flow. Neither weakens the
# skew protection #1386 added — both fail closed on any uncertainty.
#
#   rex_approval_carries_over <owner/repo> <old_sha> <new_sha> <base_branch>
#       Echoes one of: true | false | unknown
#       "true" only when ALL of the following hold, each verified against
#       the forge (never against local git state alone — me2resh/apexyard#1437
#       round-2 review, Rex B1 + Hakim A1; hardened further in #1456):
#         - <new_sha> is a two-parent commit, per the forge's own commit API
#           (GET /repos/<repo>/commits/<new_sha>), not local `git log`.
#         - parent[0] is exactly <old_sha> (the Rex-approved commit).
#         - parent[1] is an ancestor of (or equal to) <base_branch>'s CURRENT
#           tip, resolved from the forge branches endpoint
#           (GET /repos/<repo>/branches/<url-encoded-name> → .commit.sha).
#           The commits/{ref} endpoint is NOT used for the tip: a tag with
#           the same name can shadow a branch there. Never a local ref —
#           a local branch/remote-tracking ref can be stale or attacker-set.
#           This is the fix for the critical bypass an earlier version had:
#           checking only parent[0] lets an attacker merge in ANY second
#           parent (e.g. a throwaway descendant of the approved commit) and
#           still pass, because nothing verified that second parent was
#           actually the real base.
#         - the merge is reproducible: `git merge-tree --write-tree
#           <parent0> <parent1>` runs inside a fresh empty GIT_DIR that
#           reads objects only via GIT_ALTERNATE_OBJECT_DIRECTORIES, with
#           core.commitGraph=false. The tree ID is read from stdout only.
#           A local .git/config merge driver, info/grafts entry, replace
#           ref, or commit-graph cannot change the result (#1456). The
#           computed tree must equal the forge-reported tree for
#           <new_sha> (`.commit.tree.sha`). Never trusts <new_sha>'s own
#           locally-recorded tree.
#       Every other shape — a missing/unresolvable base tip, a missing
#       object, a failed fetch, a non-merge commit, an octopus merge, a
#       parent[1] not on the base branch, or a merge-tree mismatch — is
#       "false" or "unknown", never "true". <old_sha> and <new_sha> must be
#       40 lowercase hex characters or the function returns "unknown"
#       without making any git or forge call. Requires a local git checkout
#       plus `gh` and `jq` on PATH.
#
#   merge_refresh_required <owner/repo> <base_branch> <pr_number> <merge_base_sha> <shared_patterns>
#       Echoes one of: required | skippable
#       "skippable" only when every name the base branch touched since
#       <merge_base_sha> — filename AND previous_filename, so a rename on
#       either side of the comparison still counts as touching a path — is
#       NEITHER one of the PR's own names (filename AND previous_filename)
#       NOR matched by any pattern in <shared_patterns> (newline-separated
#       glob patterns, matched with the same syntax as a bash `case`
#       pattern). "required" on: a lookup failure, a truncated compare (300
#       files or more on either side), a missing/non-array `.files` field
#       (a null `.files` would otherwise jq-`length` to 0 and be silently
#       misread as "the base touched nothing" — me2resh/apexyard#1437
#       round-2 review, Rex 4 / Hakim A4), an empty <shared_patterns>
#       argument, an empty PR file list, or any empty/missing argument.
#       This function never returns "skippable" on a result it could not
#       fully verify.

# _rex_carry_git — fetch (and other real-checkout git calls) go through this
# wrapper (Hakim A1): GIT_NO_REPLACE_OBJECTS=1 defeats a locally-installed
# replace-object; GIT_CONFIG_NOSYSTEM and GIT_CONFIG_GLOBAL=/dev/null ignore
# system/global config; GIT_TERMINAL_PROMPT=0 makes a fetch fail instead of
# hanging on a credential prompt. Assignment-prefix form, not `export` —
# scoped to this one command, never leaks into the caller's shell.
# NOTE: this does NOT isolate the local repo's .git/config or info/grafts.
# merge-base and merge-tree use _rex_carry_git_isolated instead (#1456).
_rex_carry_git() {
  GIT_NO_REPLACE_OBJECTS=1 GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
  GIT_TERMINAL_PROMPT=0 git -c merge.renormalize=false -c core.attributesFile= "$@"
}

# _rex_carry_git_isolated — run merge-base / merge-tree in a fresh empty
# GIT_DIR that reads real objects only through GIT_ALTERNATE_OBJECT_DIRECTORIES
# (me2resh/apexyard#1456). A local merge driver, info/grafts entry, replace
# ref, or commit-graph in the real clone cannot change the result. The tree
# ID from merge-tree is on stdout; callers must not merge stderr into it.
_rex_carry_git_isolated() {
  local objects_dir empty_git gd rc
  objects_dir=$(git rev-parse --path-format=absolute --git-path objects 2>/dev/null)
  if [ -z "$objects_dir" ]; then
    gd=$(git rev-parse --absolute-git-dir 2>/dev/null) || return 128
    objects_dir="${gd}/objects"
  fi
  if [ ! -d "$objects_dir" ]; then
    return 128
  fi

  empty_git=$(mktemp -d 2>/dev/null) || return 128
  # Minimal empty git dir — no config, no grafts, no replace refs. Avoid
  # `git init` so nothing writes a config an attacker could race.
  if ! mkdir -p "${empty_git}/objects" "${empty_git}/refs"; then
    rm -rf "$empty_git"
    return 128
  fi
  if ! printf 'ref: refs/heads/main\n' > "${empty_git}/HEAD"; then
    rm -rf "$empty_git"
    return 128
  fi

  # Start from an empty environment (env -i). An inherited GIT_* variable
  # such as GIT_GRAFT_FILE, GIT_OBJECT_DIRECTORY, GIT_REPLACE_REF_BASE or
  # GIT_CONFIG_PARAMETERS / GIT_CONFIG_COUNT could otherwise re-introduce
  # the local state this wrapper exists to exclude (#1456, Hakim MEDIUM-1).
  # Keep only PATH (to find git), HOME and TMPDIR, then set every GIT_*
  # variable this call needs explicitly. GIT_WORK_TREE stays unset.
  env -i \
    PATH="${PATH:-/usr/bin:/bin}" \
    HOME="${HOME:-/}" \
    TMPDIR="${TMPDIR:-/tmp}" \
    GIT_DIR="$empty_git" \
    GIT_ALTERNATE_OBJECT_DIRECTORIES="$objects_dir" \
    GIT_NO_REPLACE_OBJECTS=1 \
    GIT_CONFIG_NOSYSTEM=1 \
    GIT_CONFIG_GLOBAL=/dev/null \
    GIT_TERMINAL_PROMPT=0 \
    git -c core.commitGraph=false -c merge.renormalize=false -c core.attributesFile= "$@"
  rc=$?
  rm -rf "$empty_git"
  return "$rc"
}

# _rex_carry_is_sha40 <value> — 40 lowercase hex characters, exactly.
_rex_carry_is_sha40() {
  printf '%s' "${1:-}" | grep -qE '^[0-9a-f]{40}$'
}

# rex_approval_carries_over <owner/repo> <old_sha> <new_sha> <base_branch>
rex_approval_carries_over() {
  local repo="$1" old_sha="$2" new_sha="$3" base_branch="$4"

  if [ -z "$repo" ] || [ -z "$base_branch" ]; then
    echo "unknown"
    return 0
  fi
  # Validate BEFORE any git or forge call — an unvalidated value could
  # otherwise reach a shell-interpolated API path or git ref argument.
  if ! _rex_carry_is_sha40 "$old_sha" || ! _rex_carry_is_sha40 "$new_sha"; then
    echo "unknown"
    return 0
  fi

  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "unknown"
    return 0
  fi

  # 1. Resolve the base branch's CURRENT tip from the forge branches
  # endpoint. Never commits/{ref} — a tag with the same name can shadow
  # the branch there (#1456). Never a local ref either.
  local base_encoded base_tip base_tip_rc
  base_encoded=$(jq -nr --arg b "$base_branch" '$b|@uri' 2>/dev/null)
  if [ -z "$base_encoded" ]; then
    echo "unknown"
    return 0
  fi
  base_tip=$(gh api "repos/${repo}/branches/${base_encoded}" -q '.commit.sha' 2>/dev/null)
  base_tip_rc=$?
  if [ "$base_tip_rc" -ne 0 ] || ! _rex_carry_is_sha40 "$base_tip"; then
    echo "unknown"
    return 0
  fi

  # 2. Resolve <new_sha>'s parents AND tree from the forge commit API — not
  # from local `git log`/`git show`, which reads whatever this clone's
  # object store currently contains.
  local commit_json commit_json_rc
  commit_json=$(gh api "repos/${repo}/commits/${new_sha}" 2>/dev/null)
  commit_json_rc=$?
  if [ "$commit_json_rc" -ne 0 ] || [ -z "$commit_json" ]; then
    echo "unknown"
    return 0
  fi
  local forge_parent_count
  forge_parent_count=$(printf '%s' "$commit_json" | jq -r '.parents | length' 2>/dev/null)
  case "$forge_parent_count" in
    ''|*[!0-9]*)
      echo "unknown"
      return 0
      ;;
  esac
  if [ "$forge_parent_count" -ne 2 ]; then
    # A non-merge commit (1 parent) or an octopus merge (3+ parents) is
    # never a "clean base merge" — no carry-over.
    echo "false"
    return 0
  fi

  local forge_parent0 forge_parent1 forge_tree
  forge_parent0=$(printf '%s' "$commit_json" | jq -r '.parents[0].sha' 2>/dev/null)
  forge_parent1=$(printf '%s' "$commit_json" | jq -r '.parents[1].sha' 2>/dev/null)
  forge_tree=$(printf '%s' "$commit_json" | jq -r '.commit.tree.sha' 2>/dev/null)
  if ! _rex_carry_is_sha40 "$forge_parent0" || ! _rex_carry_is_sha40 "$forge_parent1" \
     || ! _rex_carry_is_sha40 "$forge_tree"; then
    echo "unknown"
    return 0
  fi

  if [ "$forge_parent0" != "$old_sha" ]; then
    echo "false"
    return 0
  fi

  # 3. The objects needed for the LOCAL computation below (parent0,
  # parent1, base_tip) must be present. Best-effort fetch when missing; a
  # failed fetch leaves the object absent and the follow-up check returns
  # "unknown". <new_sha> itself is never fetched or trusted locally — every
  # fact about it above came from the forge.
  local sha
  for sha in "$forge_parent0" "$forge_parent1" "$base_tip"; do
    if ! git cat-file -e "${sha}^{commit}" 2>/dev/null; then
      _rex_carry_git fetch -q "https://github.com/${repo}.git" "$sha" >/dev/null 2>&1
    fi
    if ! git cat-file -e "${sha}^{commit}" 2>/dev/null; then
      echo "unknown"
      return 0
    fi
  done

  # 4. parent[1] must be an ancestor of (or equal to) the REAL base tip.
  # This is the fix for the critical bypass: without this check, a merge
  # whose second parent is any descendant of <old_sha> — not actually the
  # base branch at all — would otherwise pass on parent[0] alone.
  # Runs in an isolated empty GIT_DIR (#1456) so a local grafts entry
  # cannot invent the ancestor relationship.
  # No `!` negation here on purpose: `if ! cmd; then` would make `$?` inside
  # the branch reflect the NEGATION's exit status (always 0), not cmd's own
  # code — and rc 1 (not an ancestor) must be distinguished from rc 128+ (an
  # object couldn't be read / an internal error).
  _rex_carry_git_isolated merge-base --is-ancestor "$forge_parent1" "$base_tip" 2>/dev/null
  local anc_rc=$?
  if [ "$anc_rc" -ne 0 ]; then
    if [ "$anc_rc" -eq 1 ]; then
      echo "false"
    else
      echo "unknown"
    fi
    return 0
  fi

  # 5. Recompute the merge in an isolated empty GIT_DIR (#1456) and compare
  # its TREE (stdout only) against the forge-reported tree for <new_sha>.
  # Never parses diff text, never trusts <new_sha>'s local object, and
  # never lets a local merge driver alter the recomputation.
  local mt_tree mt_rc mt_err
  mt_err=$(mktemp 2>/dev/null) || {
    echo "unknown"
    return 0
  }
  mt_tree=$(_rex_carry_git_isolated merge-tree --write-tree "$forge_parent0" "$forge_parent1" 2>"$mt_err")
  mt_rc=$?
  if [ "$mt_rc" -ne 0 ]; then
    if grep -qiE 'unknown option|usage: git merge-tree' "$mt_err" 2>/dev/null; then
      # This git build doesn't support `merge-tree --write-tree` — cannot
      # verify, not "verified and conflicting".
      rm -f "$mt_err"
      echo "unknown"
    else
      # A real conflict: the recorded merge required a decision git's own
      # merge could not make on its own — not a mechanical replay.
      rm -f "$mt_err"
      echo "false"
    fi
    return 0
  fi
  rm -f "$mt_err"

  mt_tree=$(printf '%s' "$mt_tree" | head -1 | tr -d '[:space:]')
  if ! _rex_carry_is_sha40 "$mt_tree"; then
    echo "unknown"
    return 0
  fi
  if [ "$mt_tree" != "$forge_tree" ]; then
    echo "false"
    return 0
  fi

  echo "true"
}

# _merge_behind_path_matches_any <path> <newline-separated patterns>
# Internal helper. Echoes "true"/"false". Patterns use bash `case` glob
# syntax (`*` matches any run of characters, including `/`).
_merge_behind_path_matches_any() {
  local path="$1" patterns="$2" pattern
  [ -z "$path" ] && { echo "false"; return 0; }
  while IFS= read -r pattern; do
    [ -z "$pattern" ] && continue
    # shellcheck disable=SC2254
    case "$path" in
      $pattern) echo "true"; return 0 ;;
    esac
  done <<EOF
${patterns}
EOF
  echo "false"
}

# merge_refresh_required <owner/repo> <base_branch> <pr_number> <merge_base_sha> <shared_patterns>
merge_refresh_required() {
  local repo="$1" base="$2" pr="$3" merge_base="$4" patterns="${5:-}"

  if [ -z "$repo" ] || [ -z "$base" ] || [ -z "$pr" ] || [ -z "$merge_base" ]; then
    echo "required"
    return 0
  fi

  # An empty shared-pattern argument is indistinguishable from "the config
  # read failed" and from "an adopter deliberately emptied the list" — this
  # function cannot tell which, so it does not treat either as "nothing to
  # worry about" (Rex 4 / Hakim A4).
  local patterns_nonblank
  patterns_nonblank=$(printf '%s\n' "$patterns" | grep -c '[^[:space:]]')
  if [ "$patterns_nonblank" -eq 0 ]; then
    echo "required"
    return 0
  fi

  # Names (filename AND, on a rename, previous_filename) the PR itself
  # touches. --paginate avoids the 30-per-page default truncating a large
  # PR's file list before the 300-file guard below sees it. A rename shows
  # up as ONE entry with both fields set, not two separate entries, so this
  # does not double the 300-file truncation threshold's meaning.
  local pr_files pr_rc
  pr_files=$(gh api "repos/${repo}/pulls/${pr}/files" --paginate \
    -q '.[] | .filename, (.previous_filename // empty)' 2>/dev/null)
  pr_rc=$?
  if [ "$pr_rc" -ne 0 ]; then
    echo "required"
    return 0
  fi
  local pr_file_count=0
  if [ -n "$pr_files" ]; then
    pr_file_count=$(printf '%s\n' "$pr_files" | grep -c .)
  fi
  # An empty PR file list is not a real, ordinary state — every PR touches
  # at least one file — so it reads as a silently-swallowed API problem,
  # not "nothing to compare against" (Rex 4 / Hakim A4).
  if [ "$pr_file_count" -eq 0 ]; then
    echo "required"
    return 0
  fi
  if [ "$pr_file_count" -ge 300 ]; then
    echo "required"
    return 0
  fi

  # Files the base branch touched since the merge base — i.e. exactly the
  # commits a refresh would pull in.
  local compare_json compare_rc
  compare_json=$(gh api "repos/${repo}/compare/${merge_base}...${base}" 2>/dev/null)
  compare_rc=$?
  if [ "$compare_rc" -ne 0 ] || [ -z "$compare_json" ]; then
    echo "required"
    return 0
  fi

  # A missing or `null` `.files` field must NOT be read as "zero files
  # touched" — jq's `length` builtin returns 0 for `null` with no error,
  # which would otherwise silently misclassify an unparseable/truncated
  # response as "skippable" (Rex 4 / Hakim A4). Require a genuine array.
  local files_type
  files_type=$(printf '%s' "$compare_json" | jq -r '.files | type' 2>/dev/null)
  if [ "$files_type" != "array" ]; then
    echo "required"
    return 0
  fi

  local base_file_count
  base_file_count=$(printf '%s' "$compare_json" | jq -r '.files | length' 2>/dev/null)
  case "$base_file_count" in
    ''|*[!0-9]*)
      echo "required"
      return 0
      ;;
  esac
  if [ "$base_file_count" -ge 300 ]; then
    echo "required"
    return 0
  fi
  if [ "$base_file_count" -eq 0 ]; then
    echo "skippable"
    return 0
  fi

  # Names (filename AND previous_filename) the base branch touched — a
  # rename counts as touching BOTH its old and new path, so a PR that
  # touched the file under either name still overlaps (Rex 3 / Hakim A3).
  local base_files
  base_files=$(printf '%s' "$compare_json" \
    | jq -r '.files[] | .filename, (.previous_filename // empty)' 2>/dev/null)
  if [ -z "$base_files" ]; then
    echo "required"
    return 0
  fi

  local f overlap
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    # -e prevents a filename that happens to start with "-" from being
    # read as a grep option (Hakim A5).
    if printf '%s\n' "$pr_files" | grep -qxF -e "$f"; then
      echo "required"
      return 0
    fi
    overlap=$(_merge_behind_path_matches_any "$f" "$patterns")
    if [ "$overlap" = "true" ]; then
      echo "required"
      return 0
    fi
  done <<EOF
${base_files}
EOF

  echo "skippable"
}
