#!/bin/bash
# PreToolUse hook on `gh pr create`: when the PR's diff touches architecture
# paths OR adds a new dependency, require the PR body to reference an AgDR
# (matching `AgDR-\d+-[a-z0-9-]+`).
#
# This is the PR-time counterpart to `require-agdr-for-arch-changes.sh`
# (commit-time). The commit-time hook catches a single architectural change
# on its way into the repo; this hook catches the *cumulative* diff of a PR —
# the place where reviewers need a pointer to the decision record.
#
# Closes the asymmetry noted in `.claude/rules/agdr-decisions.md`:
# every other HARD STOP in the ruleset (merge approval, ticket-first,
# migration-first) is mechanically enforced — this one was prose-only.
#
# Behaviour:
#   - Matches ONLY on `gh pr create …`. Silent no-op on other commands.
#   - Computes the diff vs the base branch (parsed from --base; falls back
#     to `upstream/dev`, `origin/dev`, `upstream/main`, `origin/main`).
#   - Config via .claude/project-config.defaults.json (shallow-merged with
#     .claude/project-config.json):
#       .agdr_trigger_paths       → list of shell globs (case-style patterns)
#       .agdr_trigger_dep_files   → list of literal basenames (package.json, …)
#   - Architecture change detected if ANY of:
#       (a) a changed file matches any trigger path glob
#       (b) a dep file was changed AND the diff shows dependency ADDITIONS
#           (not version-only bumps — those are an /audit-deps concern).
#   - If arch change detected AND body does NOT contain `AgDR-\d+-[a-z0-9-]+`
#     → exit 2 with a helpful message.
#   - Skip marker `<!-- agdr: not-applicable -->` in body → exit 0 with a
#     visible WARN on stderr.
#   - Empty diff or unresolvable base → silent exit 0.

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)

if [ -z "$COMMAND" ]; then
  exit 0
fi

# Match only on `gh pr create …`.
if ! echo "$COMMAND" | grep -qE '\bgh\s+pr\s+create\b'; then
  exit 0
fi

# ---------------------------------------------------------------------------
# 1. Extract --title, --body, --body-file, -F <path> from the command.
#    Same parser shape as block-private-refs-in-public-repos.sh — lifted here
#    to avoid creating a shared extractor library solely for one new caller.
# ---------------------------------------------------------------------------

extract_flag_value() {
  # $1 = flag regex (e.g. --title | -t). Matches:
  #   --title "value with spaces"
  #   --title 'value with spaces'
  #   --title value
  #
  # The original sed form used `[^"]*` which truncated at the first embedded
  # double-quote inside the body value — false-blocking PRs whose body contained
  # a `"` before the AgDR reference (me2resh/apexyard#461). The fix mirrors the
  # already-corrected extractor in block-private-refs-in-public-repos.sh
  # (me2resh/apexyard#227): awk with a greedy `(.*)` match anchored on the next
  # recognised flag boundary (whitespace + `--<letter>`) or end-of-string. This
  # captures the full quoted span, including any embedded quotes, without
  # bleeding past the start of the next flag.
  local flag_re="$1"
  local cmd="$2"
  printf '%s' "$cmd" | awk -v FLAG_RE="$flag_re" -v SQ="'" '
    { buf = (NR == 1 ? $0 : buf "\n" $0) }
    END {
      s = buf
      # Double-quoted value: greedy `(.*)` anchored on next flag or EOS.
      re = "(" FLAG_RE ")[[:space:]]+\"(.*)\"([[:space:]]+--[a-zA-Z]|[[:space:]]*$)"
      if (match(s, re)) {
        chunk = substr(s, RSTART, RLENGTH)
        sub("^(" FLAG_RE ")[[:space:]]+\"", "", chunk)
        sub("\"([[:space:]]+--[a-zA-Z].*)?$", "", chunk)
        sub("\"[[:space:]]*$", "", chunk)
        print chunk
        exit
      }
      # Single-quoted value: same greedy + anchor treatment.
      re = "(" FLAG_RE ")[[:space:]]+" SQ "(.*)" SQ "([[:space:]]+--[a-zA-Z]|[[:space:]]*$)"
      if (match(s, re)) {
        chunk = substr(s, RSTART, RLENGTH)
        sub("^(" FLAG_RE ")[[:space:]]+" SQ, "", chunk)
        sub(SQ "([[:space:]]+--[a-zA-Z].*)?$", "", chunk)
        sub(SQ "[[:space:]]*$", "", chunk)
        print chunk
        exit
      }
      # Unquoted value: single token, embedded quotes irrelevant.
      re = "(" FLAG_RE ")[[:space:]]+[^[:space:]]+"
      if (match(s, re)) {
        chunk = substr(s, RSTART, RLENGTH)
        sub("^(" FLAG_RE ")[[:space:]]+", "", chunk)
        print chunk
        exit
      }
    }
  '
}

TITLE=$(extract_flag_value '--title|-t' "$COMMAND")
BODY=$(extract_flag_value '--body|-b' "$COMMAND")

# --body-file <path> / -F <path> (only when -F's value is NOT a key=val pair,
# because `gh api -F body=@file` uses the same flag letter).
BODY_FILE=$(extract_flag_value '--body-file' "$COMMAND")
if [ -z "$BODY_FILE" ]; then
  F_VAL=$(echo "$COMMAND" | sed -nE "s/.*(^|[[:space:]])-F[[:space:]]+\"([^\"]*)\".*/\2/p" | head -1)
  if [ -z "$F_VAL" ]; then
    F_VAL=$(echo "$COMMAND" | sed -nE "s/.*(^|[[:space:]])-F[[:space:]]+'([^']*)'.*/\2/p" | head -1)
  fi
  if [ -z "$F_VAL" ]; then
    F_VAL=$(echo "$COMMAND" | sed -nE "s/.*(^|[[:space:]])-F[[:space:]]+([^[:space:]]+).*/\2/p" | head -1)
  fi
  if [ -n "$F_VAL" ] && ! echo "$F_VAL" | grep -q '='; then
    BODY_FILE="$F_VAL"
  fi
fi

BODY_FILE_CONTENT=""
if [ -n "$BODY_FILE" ] && [ -f "$BODY_FILE" ]; then
  BODY_FILE_CONTENT=$(cat "$BODY_FILE" 2>/dev/null)
fi

# Build the body haystack. Title is included so an AgDR reference in the
# title also satisfies the requirement (reviewers will see it either way).
HAYSTACK=$(printf '%s\n%s\n%s\n' "$TITLE" "$BODY" "$BODY_FILE_CONTENT")

# ---------------------------------------------------------------------------
# 2. Skip marker short-circuit.
# ---------------------------------------------------------------------------
SKIP_MARKER='<!-- agdr: not-applicable -->'
if echo "$HAYSTACK" | grep -qF -- "$SKIP_MARKER"; then
  echo "WARN: agdr: not-applicable marker present — require-agdr-for-arch-pr bypassed. See .claude/rules/agdr-decisions.md." >&2
  exit 0
fi

# ---------------------------------------------------------------------------
# 2a. Resolve REPO_ROOT now (used by both the spike exemption below and the
# diff resolution further down).
# ---------------------------------------------------------------------------

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
if [ -z "$REPO_ROOT" ]; then
  exit 0
fi

# ---------------------------------------------------------------------------
# 2a-i. Cross-repo guard (me2resh/apexyard#464).
#
# When the hook fires on a `gh pr create --repo <X>` command but the current
# git working tree belongs to a DIFFERENT repo (e.g. the session is pinned to
# the ops-fork while the command targets a sibling repo), the diff computed
# below reflects the ops-fork's changed files — NOT the PR's actual diff.
# That produces false-positive blocks for PRs that don't touch any framework
# architecture paths.
#
# Fix: compare the PR target repo (--repo flag, or implicit same-repo) to the
# origin remote of the current working tree. If they differ, we cannot compute
# a meaningful diff for this PR from this cwd → exit 0 (no-op).
#
# Framework gating is preserved: when creating a me2resh/apexyard PR from the
# framework cwd, the --repo value matches origin → the guard does NOT fire and
# the diff check runs as usual.
# ---------------------------------------------------------------------------

HOOK_DIR_AGDR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$HOOK_DIR_AGDR/_lib-pr-repo.sh" ]; then
  # shellcheck source=/dev/null
  . "$HOOK_DIR_AGDR/_lib-pr-repo.sh"
  if ! pr_repo_matches_cwd "$COMMAND" "$REPO_ROOT"; then
    # PR targets a different repo than this working tree — cannot evaluate
    # the arch-path diff from here. Silently pass; the hook in that repo's
    # own CI context will gate this correctly.
    exit 0
  fi
else
  # _lib-pr-repo.sh is missing (partial checkout or manual hook copy without
  # the lib). The cross-repo guard cannot run, which means a `gh pr create
  # --repo <sibling>` command will fall through to the ops-fork diff — exactly
  # the false-positive bug #464 this guard was introduced to prevent.
  # Emit a loud warning so the degradation is visible; do NOT silently revert.
  # Match all four flag forms: --repo VALUE, --repo=VALUE, -R VALUE, -R=VALUE.
  CMD_REPO_PRESENT=$(printf '%s' "$COMMAND" | grep -cE '(^|[[:space:]])(--repo[=[:space:]]|-R[=[:space:]])' || true)
  if [ "${CMD_REPO_PRESENT:-0}" -gt 0 ]; then
    echo "WARN: require-agdr-for-arch-pr.sh: _lib-pr-repo.sh not found at $HOOK_DIR_AGDR — cross-repo guard DEGRADED. A \`gh pr create --repo <sibling>\` command will be evaluated against the current working tree's diff, which may produce false-positive blocks (me2resh/apexyard#464). Ensure _lib-pr-repo.sh is present alongside this hook." >&2
  fi
fi

# ---------------------------------------------------------------------------
# 2b. Spike exemption (apexyard#180).
#
# Spike work is hypothesis-driven, time-boxed, throw-away exploration. AgDRs
# capture decisions that should persist; spikes write disposition memos
# instead. The exemption fires when ANY of:
#
#   (a) the PR title carries `spike(...)` as the conventional-commit type
#   (b) the active ticket marker references a `[Spike]`-prefixed ticket
#   (c) the branch is named `spike/<TICKET-ID>-...`
#
# Code review (Rex) and the security auditor still apply — exemptions are
# surgical, not blanket. See .claude/rules/workflow-gates.md § Spike work.
# ---------------------------------------------------------------------------
spike_pr_exempt() {
  # (a) spike(...) PR title
  if echo "$TITLE" | grep -qE '^spike\([^)]+\)!?:'; then
    return 0
  fi

  # (b) active ticket marker has [Spike] prefix
  local marker_home="${REPO_ROOT}"
  # Walk up to find the ops root. Honours both the v2 `.apexyard-fork`
  # marker and the legacy v1 anchor (onboarding.yaml + apexyard.projects.yaml).
  local hook_dir
  hook_dir="$(cd "$(dirname "$0")" && pwd)"
  if [ -f "$hook_dir/_lib-ops-root.sh" ]; then
    # shellcheck source=/dev/null
    . "$hook_dir/_lib-ops-root.sh"
    local resolved
    resolved=$(resolve_ops_root "$REPO_ROOT")
    [ -n "$resolved" ] && marker_home="$resolved"
  else
    local r="$REPO_ROOT"
    while [ -n "$r" ] && [ "$r" != "/" ]; do
      if [ -f "$r/.apexyard-fork" ]; then
        marker_home="$r"
        break
      fi
      if [ -f "$r/onboarding.yaml" ] && [ -f "$r/apexyard.projects.yaml" ]; then
        marker_home="$r"
        break
      fi
      r=$(dirname "$r")
    done
  fi

  if [ -f "$marker_home/.claude/session/current-ticket" ]; then
    if grep -qE '^title=\[Spike\]' "$marker_home/.claude/session/current-ticket" 2>/dev/null; then
      return 0
    fi
  fi
  if [ -d "$marker_home/.claude/session/tickets" ]; then
    for marker in "$marker_home/.claude/session/tickets"/*; do
      [ -f "$marker" ] || continue
      if grep -qE '^title=\[Spike\]' "$marker" 2>/dev/null; then
        return 0
      fi
    done
  fi

  # (c) branch named spike/...
  local branch
  branch=$(git -C "$REPO_ROOT" branch --show-current 2>/dev/null)
  if echo "$branch" | grep -qE '^spike/'; then
    return 0
  fi

  return 1
}

if spike_pr_exempt; then
  echo "WARN: spike PR detected — require-agdr-for-arch-pr bypassed. AgDRs not required for hypothesis-driven throw-away work; ship a memo on /spike-close instead. See .claude/rules/workflow-gates.md § Spike work." >&2
  exit 0
fi

# ---------------------------------------------------------------------------
# 3. Resolve base branch and compute the PR diff.
#
#    Precedence:
#      a. --base <branch> on the command
#      b. first of: upstream/dev, origin/dev, upstream/main, origin/main
#    If none resolve to a real ref, exit 0 silently — the hook has nothing to
#    evaluate and the PR creation itself will fail more loudly than we can.
# ---------------------------------------------------------------------------

BASE_ARG=$(extract_flag_value '--base|-B' "$COMMAND")
BASE_REF=""

resolve_ref() {
  # Verify a ref exists; echo it if so, else empty.
  local ref="$1"
  if git rev-parse --verify --quiet "$ref" >/dev/null 2>&1; then
    echo "$ref"
  fi
}

if [ -n "$BASE_ARG" ]; then
  # Try upstream/<arg>, origin/<arg>, <arg> in that order.
  for candidate in "upstream/$BASE_ARG" "origin/$BASE_ARG" "$BASE_ARG"; do
    r=$(resolve_ref "$candidate")
    if [ -n "$r" ]; then BASE_REF="$r"; break; fi
  done
fi

if [ -z "$BASE_REF" ]; then
  for candidate in upstream/dev origin/dev upstream/main origin/main main master; do
    r=$(resolve_ref "$candidate")
    if [ -n "$r" ]; then BASE_REF="$r"; break; fi
  done
fi

if [ -z "$BASE_REF" ]; then
  # Can't determine base — silent no-op.
  exit 0
fi

MERGE_BASE=$(git merge-base HEAD "$BASE_REF" 2>/dev/null)
if [ -z "$MERGE_BASE" ]; then
  exit 0
fi

CHANGED_FILES=$(git diff --name-only "$MERGE_BASE"..HEAD 2>/dev/null)
if [ -z "$CHANGED_FILES" ]; then
  # No files changed — nothing to evaluate.
  exit 0
fi

# ---------------------------------------------------------------------------
# 4. Load trigger config.
#    - `.agdr_trigger_paths[]`    → globs (shell case patterns)
#    - `.agdr_trigger_dep_files[]` → literal basenames
#    Both have inline fallbacks if the config lib / defaults file are missing.
# ---------------------------------------------------------------------------

TRIGGER_PATHS=""
TRIGGER_DEP_FILES=""

if [ -f "$REPO_ROOT/.claude/hooks/_lib-read-config.sh" ]; then
  # shellcheck disable=SC1090,SC1091
  . "$REPO_ROOT/.claude/hooks/_lib-read-config.sh"
  TRIGGER_PATHS=$(config_get '.agdr_trigger_paths[]' 2>/dev/null)
  TRIGGER_DEP_FILES=$(config_get '.agdr_trigger_dep_files[]' 2>/dev/null)
fi

# Fallback defaults — kept in sync with .claude/project-config.defaults.json.
if [ -z "$TRIGGER_PATHS" ]; then
  TRIGGER_PATHS='**/domain/**
**/infrastructure/**
**/migrations/**
infrastructure/**
template.yaml
**/*.tf
**/*.tfvars
.github/workflows/**'
fi

if [ -z "$TRIGGER_DEP_FILES" ]; then
  TRIGGER_DEP_FILES='package.json
pyproject.toml
Cargo.toml
go.mod
Gemfile'
fi

# ---------------------------------------------------------------------------
# 5. Decide whether any changed file triggers the arch requirement.
#
# Path match: we translate each glob to a shell `case` pattern. `**` in
# shell-case isn't literally supported but `*` crosses `/` in case patterns
# (POSIX shell), so `*/domain/*` matches the intent of `**/domain/**`.
# ---------------------------------------------------------------------------

matches_glob() {
  # $1 = path, $2 = glob (one per call). Returns 0 if match.
  local path="$1"
  local glob="$2"
  # Rewrite `**` → `*` for shell case. `*/foo/**/bar` → `*/foo/*/bar`.
  # shell case `*` already crosses `/`, so this is close enough for our
  # trigger list (which only uses `**` at path boundaries).
  local sg
  sg=$(echo "$glob" | sed 's|\*\*|*|g')
  # shellcheck disable=SC2254
  case "$path" in
    $sg) return 0 ;;
  esac
  # Also try with a leading `*/` for patterns that start at an arbitrary
  # depth (e.g. `**/domain/**` should match `foo/domain/x.ts` as well as
  # `domain/x.ts`). The rewrite above turned it into `*/domain/*` which
  # needs a leading directory; patch by trying the leading-optional form.
  case "$glob" in
    \*\**)
      local stripped
      stripped=$(echo "$glob" | sed -E 's|^\*\*/||; s|\*\*|*|g')
      # shellcheck disable=SC2254
      case "$path" in
        $stripped) return 0 ;;
      esac
      ;;
  esac
  return 1
}

TRIGGERED_FILES=""
TRIGGERED_DEP_FILES=""

# (a) Path-based triggers.
while IFS= read -r file; do
  [ -z "$file" ] && continue
  while IFS= read -r pat; do
    [ -z "$pat" ] && continue
    if matches_glob "$file" "$pat"; then
      TRIGGERED_FILES="${TRIGGERED_FILES}${file}
"
      break
    fi
  done <<EOF
$TRIGGER_PATHS
EOF
done <<EOF
$CHANGED_FILES
EOF

# (b) Dep-file additions.
#
# For each dep-file listed in config, check whether it's in the changed set.
# If so, decide whether the diff is "add a new dep" vs "version bump only".
#
# JSON dep files (only package.json today): compare the union of `.dependencies`
# + `.devDependencies` + `.peerDependencies` + `.optionalDependencies` keys at
# MERGE_BASE vs HEAD. Any key present at HEAD but not at MERGE_BASE is an
# addition → fire.
#
# Non-JSON dep files (pyproject.toml, Cargo.toml, go.mod, Gemfile): crude
# heuristic — count the number of ADDED lines (`^+` in unified diff) that
# look like a dep declaration and do NOT correspond to a matching REMOVED
# line with the same dep name. A version bump shows up as a matched +/- pair
# on the same dep name; a new dep shows up as a `+` with no counterpart. The
# heuristic is: `grep -E '^\+[^+]' diff | wc -l` > `grep -E '^-[^-]' diff | wc -l`.
# Not perfect — reorderings can false-positive — but it's good enough for the
# "did you *add* something" signal. Projects that need exact parsing can
# install a linter and wire it into CI.
while IFS= read -r depfile; do
  [ -z "$depfile" ] && continue
  # Does the diff actually touch this file (at any depth)?
  TOUCHED=$(echo "$CHANGED_FILES" | grep -E "(^|/)$(printf '%s' "$depfile" | sed -E 's/[.[\\/^$*+?(){}|]/\\&/g')$" || true)
  [ -z "$TOUCHED" ] && continue

  while IFS= read -r file; do
    [ -z "$file" ] && continue
    case "$depfile" in
      package.json)
        BASE_JSON=$(git show "$MERGE_BASE:$file" 2>/dev/null)
        HEAD_JSON=$(git show "HEAD:$file" 2>/dev/null)
        # File may be newly added → BASE_JSON empty → any deps are additions.
        if [ -z "$BASE_JSON" ]; then
          if [ -n "$HEAD_JSON" ] && command -v jq >/dev/null 2>&1; then
            HEAD_KEYS=$(echo "$HEAD_JSON" | jq -r '
              (.dependencies // {}) + (.devDependencies // {}) +
              (.peerDependencies // {}) + (.optionalDependencies // {})
              | keys[]' 2>/dev/null)
            if [ -n "$HEAD_KEYS" ]; then
              TRIGGERED_DEP_FILES="${TRIGGERED_DEP_FILES}${file} (new file, ${HEAD_KEYS:+deps added})
"
            fi
          fi
          continue
        fi
        if command -v jq >/dev/null 2>&1; then
          BASE_KEYS=$(echo "$BASE_JSON" | jq -r '
            (.dependencies // {}) + (.devDependencies // {}) +
            (.peerDependencies // {}) + (.optionalDependencies // {})
            | keys[]' 2>/dev/null | sort -u)
          HEAD_KEYS=$(echo "$HEAD_JSON" | jq -r '
            (.dependencies // {}) + (.devDependencies // {}) +
            (.peerDependencies // {}) + (.optionalDependencies // {})
            | keys[]' 2>/dev/null | sort -u)
          ADDED=$(comm -13 <(echo "$BASE_KEYS") <(echo "$HEAD_KEYS") | tr '\n' ' ')
          ADDED=$(echo "$ADDED" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
          if [ -n "$ADDED" ]; then
            TRIGGERED_DEP_FILES="${TRIGGERED_DEP_FILES}${file} (added: ${ADDED})
"
          fi
        fi
        ;;
      *)
        # Non-JSON heuristic. Pull the unified diff for this file.
        DIFF=$(git diff "$MERGE_BASE"..HEAD -- "$file" 2>/dev/null)
        [ -z "$DIFF" ] && continue
        ADDED_LINES=$(echo "$DIFF" | grep -cE '^\+[^+]' || true)
        REMOVED_LINES=$(echo "$DIFF" | grep -cE '^-[^-]' || true)
        # If strictly more lines added than removed, treat as a probable
        # dep addition (a version bump should be a matched +/- pair).
        if [ "${ADDED_LINES:-0}" -gt "${REMOVED_LINES:-0}" ]; then
          TRIGGERED_DEP_FILES="${TRIGGERED_DEP_FILES}${file} (likely dep addition; +${ADDED_LINES} / -${REMOVED_LINES})
"
        fi
        ;;
    esac
  done <<EOF
$TOUCHED
EOF
done <<EOF
$TRIGGER_DEP_FILES
EOF

# If neither category fired, nothing to enforce.
if [ -z "$TRIGGERED_FILES" ] && [ -z "$TRIGGERED_DEP_FILES" ]; then
  exit 0
fi

# ---------------------------------------------------------------------------
# 6. Body must contain an AgDR reference. Regex is intentionally the same
#    shape the /decide skill generates: AgDR-<digits>-<kebab-slug>.
# ---------------------------------------------------------------------------

if echo "$HAYSTACK" | grep -qE 'AgDR-[0-9]+-[a-z0-9-]+'; then
  exit 0
fi

# ---------------------------------------------------------------------------
# 7. Block with a helpful message.
# ---------------------------------------------------------------------------

{
  echo "BLOCKED: PR diff includes architecture changes but the PR body has no AgDR reference."
  echo
  if [ -n "$TRIGGERED_FILES" ]; then
    echo "Triggering paths (matched agdr_trigger_paths):"
    printf '%s' "$TRIGGERED_FILES" | sed 's/^/  - /' | grep -v '^  - $'
  fi
  if [ -n "$TRIGGERED_DEP_FILES" ]; then
    echo "Triggering dep-file additions (matched agdr_trigger_dep_files):"
    printf '%s' "$TRIGGERED_DEP_FILES" | sed 's/^/  - /' | grep -v '^  - $'
  fi
  cat <<'MSG'

Why this is blocked:
  .claude/rules/agdr-decisions.md calls /decide a HARD STOP before any
  technical decision — library choice, architecture move, new dependency,
  infra shape. Other HARD STOPs in the ruleset (merge approval, ticket-
  first, migration-first) are mechanically enforced at PR time; this one
  closes the gap.

To unblock:
  1. Run /decide to walk through the decision and generate an AgDR file
     at docs/agdr/AgDR-NNNN-{slug}.md
  2. Commit the AgDR on this branch.
  3. Reference the AgDR in the PR body (any occurrence matching
     `AgDR-\d+-[a-z0-9-]+` satisfies the hook).

Escape hatch (rare — e.g. a refactor that moves files through a trigger
path without a new decision, or a dep rename without a semantic change):
  Add this HTML comment anywhere in the body:
    <!-- agdr: not-applicable -->

Trigger paths + dep files are configurable in
.claude/project-config.json via:
  - .agdr_trigger_paths[]     (shell globs)
  - .agdr_trigger_dep_files[] (literal filenames)
See .claude/project-config.defaults.json for the shipped defaults.
MSG
} >&2

exit 2
