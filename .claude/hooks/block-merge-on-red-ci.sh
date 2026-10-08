#!/bin/bash
# CLASS: CONTROL (AgDR-0104 labelling, AgDR-0109). This hook decides on
# STRUCTURED STATE, not on the text of a command: the CI conclusion the forge reports for the PR's HEAD.
# That is what makes it trustworthy where a text-matching backstop like
# warn-review-marker-write.sh is not. Command parsing and GitLab pipeline
# resolution fail closed. GitHub Actions API failures fail open with an
# explicit unverified-CI note (AgDR-0213).
#
# PreToolUse hook on `gh pr merge` / `gh api .../pulls/<N>/merge` AND their
# GitLab counterparts `glab mr merge` / `glab api .../merge_requests/<N>/merge`:
# blocks the merge if reported CI is failing or pending. GitHub Actions API
# failures remain an explicit fail-open exception.
#
# All four merge shapes are covered — see _lib-extract-pr.sh for the parser.
# #47 is why the gh-api-shape bypass was worth closing; #764/#767 added the
# glab shapes to the OTHER three merge gates; this hook was the one sibling
# still hardcoded to `gh pr checks` (#790 — the last non-forge-aware gate).
#
# Enforces .claude/rules/pr-quality.md § "No Red CI Before Merge" —
# "Never merge with red CI - even if the failure is pre-existing or
# unrelated. Fix the pre-existing issue first (separate commit), rebase
# the PR so all checks are green, and only then merge." Was prose-only
# until this hook shipped.
#
# GH PATH
# -------
# Uses `gh pr checks <pr>` which returns one line per check with status.
# Exit codes:
#   0 = all checks passed (and none required are missing)
#   1 = at least one check failed, was cancelled, or skipped; also the
#       no-checks case ("no checks reported on the '<branch>' branch")
#   8 = at least one check is pending
#
# The hook checks Actions runs for the PR head on every GitHub merge.
# It allows green checks only when those runs have also finished with an
# accepted conclusion. The exact no-checks response still allows a repo
# with no CI. Substring match is NOT enough (#1523).
# Blocks:
#   - exit 1 (red CI)
#   - any check with state FAILURE | CANCELLED | TIMED_OUT
#   - the latest run per workflow and event awaiting approval, still running, or
#     completed without success, neutral, or skipped
#
# Pending checks (IN_PROGRESS | QUEUED): BLOCKED. The rule says all checks
# must be green; pending is not green. Wait for CI to finish, then retry.
#
# WRAPPER-SHAPE FORGE FALLBACK (#1121)
# -------------------------------------
# The `tracker_pr_merge` wrapper (#759) resolves its forge from the registry
# via `_forge_kind_for` -> `tracker_kind` -> `_lib-tracker.sh`'s
# `_tracker_project_value`, which reads the per-project `tracker.kind`
# override with `yq` (preferred) or a `python3` + PyYAML fallback. When
# NEITHER tool is installed, that read silently returns nothing and
# `tracker_kind` falls through to the GLOBAL `.tracker.kind` default (`gh`)
# — exactly wrong for a glab-registered project's wrapper call, since the
# wrapper's own text never says which CLI it drives. `_registry_glab_fallback`
# below is a dependency-free (grep/awk only, no yq/PyYAML) second check used
# ONLY when the primary resolver answers "gh" for a wrapper-shape command: it
# scans the registry file directly for an explicit `tracker: kind: glab` on
# the target repo. It can only ever upgrade an ambiguous "gh" to a confirmed
# "glab" — it never downgrades a "glab" answer and never fires for the
# non-wrapper shapes (those dispatch on command text, which is always
# trustworthy). The real fix for the underlying yq/PyYAML-optional gap
# belongs to the shared resolver libs, out of scope here.
#
# GLAB PATH (new, #790)
# ----------------------
# `resolve_ci_status_glab` (see _lib-extract-pr.sh) resolves the GitLab MR's
# head-pipeline status via `glab mr view <iid> --output json`, normalised to
# one of: success | pending | failure | none | "" (unresolvable).
#   Allows: "success"; "none" (MR has no pipeline configured — the glab
#   analog of gh's "no checks reported").
#   Blocks: "pending"; "failure"; "" — an EMPTY status means the pipeline
#   state could not be determined (glab missing, network/auth failure,
#   unparseable response). Fail CLOSED: an unresolvable status is never
#   treated as green, exactly like a red-or-unfetchable gh CI check.

INPUT=$(cat)

# _require_lib <path>: source a REQUIRED library or fail closed.
#
# Without this guard, a missing/unreadable library leaves is_merge_command
# (and the other functions the library defines) undefined. In default
# (non-POSIX) bash, sourcing a missing file with a bare `.` returns 1 and
# the script keeps running — the later `if ! is_merge_command "$COMMAND";
# then exit 0; fi` check then calls an undefined function, bash reports
# "command not found" (exit 127), the negated check reads that as "not a
# merge command", and the hook exits 0. That exit is a clean, deliberate-
# looking 0, not a crash, so the dispatcher's fail-closed wrapper
# (AgDR-0169) cannot see it — this gate silently opens. See
# me2resh/apexyard#1405 review finding H2 and AgDR-0169.
#
# Checking readability with `[ -r ]` BEFORE ever calling `.` also matters
# under `bash --posix` / `POSIXLY_CORRECT=1`: a special builtin such as `.`
# that fails to find its argument ends a non-interactive POSIX-mode shell
# immediately, even inside an `if`/`||` guard around the `.` call itself —
# verified empirically (see AgDR-0169). `[ -r ]` is an ordinary test
# builtin, so it never triggers that behavior; this function never calls
# `.` on a path it has not already confirmed is readable.
#
# This gate does not source _lib-review-markers.sh — it decides on CI
# status, not on approval markers — so only _lib-extract-pr.sh is guarded
# here.
_require_lib() {
  local lib="$1" fn
  shift
  if [ ! -r "$lib" ]; then
    echo "BLOCKED: merge gate cannot load a required library." >&2
    echo "Missing or unreadable: $lib" >&2
    echo "A merge gate that cannot load its own logic fails closed" >&2
    echo "instead of skipping the check. Restore the file and retry." >&2
    exit 2
  fi
  # shellcheck disable=SC1090,SC1091
  if ! . "$lib"; then
    echo "BLOCKED: merge gate failed to load a required library." >&2
    echo "Source failed: $lib" >&2
    echo "A merge gate that cannot load its own logic fails closed" >&2
    echo "instead of skipping the check. Fix the file and retry." >&2
    exit 2
  fi
  for fn in "$@"; do
    if ! command -v "$fn" >/dev/null 2>&1 || ! declare -F "$fn" >/dev/null 2>&1; then
      printf 'BLOCKED: merge gate missing required function %s after sourcing %s. Restore the library and retry.\n' "$fn" "$lib" >&2
      exit 2
    fi
  done
}

# Shared merge-shape detector + PR-number parser (see _lib-extract-pr.sh).
# Handles `gh pr merge <N>`, `gh api repos/<owner>/<repo>/pulls/<N>/merge`,
# `glab mr merge <N>`, and `glab api .../merge_requests/<N>/merge` (#764/#767).
# Sourced BEFORE the jq-based command parse below (moved up from its
# original position after the parse) so is_merge_command is available as
# the jq-independent fallback detector when the parse can't be trusted —
# see #965.
_require_lib "$(dirname "$0")/_lib-extract-pr.sh" \
  is_merge_command is_merge_command_raw _scrub_merge_command _normalize_json_escapes \
  merge_command_uses_variable extract_pr_number resolve_merge_repo \
  resolve_ci_status_glab
# Leading cd-target recovery for shared merge-repo resolution (#687/#1151).
# Optional only for standalone hook-test sandboxes that copy a minimal lib set.
if [ -f "$(dirname "$0")/_lib-pr-repo.sh" ]; then
  . "$(dirname "$0")/_lib-pr-repo.sh"
fi

# _registry_glab_fallback <owner/repo>
# -------------------------------------
# Dependency-free (grep/awk only — no yq, no python3/PyYAML) second check for
# whether the registry EXPLICITLY marks <owner/repo> as `tracker: kind: glab`
# (#1121 — see the WRAPPER-SHAPE FORGE FALLBACK header comment above for why
# this exists). Hook-local by design: it duplicates a narrow slice of
# `_lib-tracker.sh`'s `_tracker_project_value` on purpose, rather than
# touching that shared resolver, so this fix stays scoped to this one hook.
#
# Scans project blocks the same way apexyard.projects.yaml is documented to
# be shaped (apexyard.projects.yaml.example): a top-level `projects:` list
# where each entry is a `- name: ...` block containing a `repo:` field and,
# optionally, a `tracker:` sub-block with a `kind:` field. A block boundary
# is any `- ` list-item line at the SAME indentation as the first one seen —
# this is what keeps a NESTED list (`roles:`, `tags:`) from being mistaken
# for a new project entry, since nested items are always more indented than
# the top-level `- name:` marker.
#
# Echoes "glab" and exits 0 only when the target repo's block contains an
# explicit `kind: glab`; otherwise echoes nothing and exits 1. This can only
# ever confirm "glab" — it never asserts "gh" — so a caller should treat a
# miss as "no additional information", not as "confirmed gh".
_registry_glab_fallback() {
  local repo="${1:-}" registry=""
  [ -n "$repo" ] || return 1

  if command -v portfolio_registry >/dev/null 2>&1; then
    registry=$(portfolio_registry 2>/dev/null)
  fi
  [ -n "$registry" ] || registry="./apexyard.projects.yaml"
  [ -f "$registry" ] || return 1

  local found
  found=$(awk -v target="$repo" '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    function unquote(s,    t, n, c1, cn, sq) {
      sq = sprintf("%c", 39)
      t = s
      sub(/[ \t]*#.*$/, "", t)
      t = trim(t)
      n = length(t)
      if (n >= 2) {
        c1 = substr(t, 1, 1)
        cn = substr(t, n, 1)
        if ((c1 == "\"" && cn == "\"") || (c1 == sq && cn == sq)) {
          t = substr(t, 2, n - 2)
        }
      }
      return t
    }
    BEGIN { item_indent = -1; emitted = 0 }
    {
      raw = $0
      match(raw, /^[ \t]*/)
      ind = RLENGTH
      is_item = (raw ~ /^[ \t]*-[ \t]/)

      if (is_item) {
        if (item_indent == -1) { item_indent = ind }
        if (ind == item_indent) {
          # Flush the block that just ended. When the target glab block is NOT
          # the last registry entry, the match fires here (mid-stream). We must
          # exit WITHOUT letting the END block re-print: awk exit jumps to END,
          # so a bare "print glab; exit" re-satisfies the END condition (block_repo
          # and block_kind are still set) and emits a SECOND glab line, making the
          # caller compare found against "glab\nglab" and MISS. The emitted flag
          # makes END a no-op after a mid-stream hit (the #1121 position fix).
          # NOTE: no apostrophes in these comments — the whole awk program is a
          # single-quoted shell string, so an apostrophe would terminate it.
          if (block_repo == target && block_kind == "glab") { print "glab"; emitted = 1; exit }
          block_repo = ""; block_kind = ""
        }
      }

      line = raw
      sub(/^[ \t]*-[ \t]*/, "", line)
      line = trim(line)
      if (line ~ /^repo:[ \t]*/) {
        v = line; sub(/^repo:[ \t]*/, "", v); block_repo = unquote(v)
      }
      if (line ~ /^kind:[ \t]*/) {
        v = line; sub(/^kind:[ \t]*/, "", v); block_kind = unquote(v)
      }
    }
    END {
      # Only fires for the LAST block (no later item boundary flushed it). The
      # `!emitted` guard prevents a double-print after a mid-stream hit above.
      if (!emitted && block_repo == target && block_kind == "glab") print "glab"
    }
  ' "$registry" 2>/dev/null)

  if [ "$found" = "glab" ]; then
    echo "glab"
    return 0
  fi
  return 1
}

# Parse .tool_input.command via jq. #965: this used to be the ONLY parse
# path, and an empty/failed result — jq missing from PATH, or jq erroring
# on unexpected input — fell straight through to `exit 0`, silently
# ALLOWING the merge command through with NO CI-status check at all. A
# security/quality gate must fail CLOSED when it can't evaluate its own
# precondition, not fail open.
#
# But this hook's PreToolUse matcher is `Bash` (every Bash call this
# session runs, not just merges — see .claude/settings.json), so the fix
# can't be "exit 2 whenever jq is unavailable": that would block every
# unrelated Bash command for the rest of the session the moment jq broke,
# which is worse than the bug it replaces. The resolution below keeps the
# jq-unparseable case a no-op EXCEPT when the raw payload text itself
# looks merge-shaped — in that narrower case we cannot safely let the
# command through, so we fail closed instead.
COMMAND=""
if command -v jq >/dev/null 2>&1; then
  COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
fi

if [ -z "$COMMAND" ]; then
  # jq is missing, OR jq is present but the parse produced nothing — a
  # genuinely empty command (legitimate no-op) or jq choking on
  # malformed/unexpected JSON. Those two cases are indistinguishable from
  # a parsed field alone, so fall back to a parser-independent scan: reuse
  # is_merge_command (plain grep/sed, no jq dependency) directly against
  # the RAW JSON payload text instead of the parsed command. The command
  # text's own words (`gh`, `pr`, `merge`, digits, spaces) survive JSON
  # string-encoding unchanged, so this is the exact same tested
  # merge-shape detector used below — not a second, drift-prone regex.
  #
  # #973: the command's SEPARATORS do not always survive unchanged — a
  # literal tab (or other JSON-escaped whitespace) encodes as a
  # multi-character escape sequence (`\t`, `\uXXXX`) that `is_merge_command`'s
  # `\s+` regex class won't recognise as whitespace. Normalize the small set
  # of escapes that matter BEFORE scanning, so a merge command with
  # JSON-escaped separators is caught exactly like a space-separated one —
  # see `_normalize_json_escapes` in _lib-extract-pr.sh for the decode and
  # why it's only ever applied on this raw-payload path, never on COMMAND.
  #
  # A payload that isn't merge-shaped at all is a genuine no-op — exit 0,
  # unchanged behaviour for the overwhelming majority of Bash calls this
  # hook sees. A payload that DOES look merge-shaped but that we can't
  # safely parse/verify fails CLOSED (exit 2) instead of silently letting
  # an ungated merge through with an unverified CI status.
  if is_merge_command_raw "$(_normalize_json_escapes "$INPUT")"; then
    echo "BLOCKED: CI gate cannot evaluate this command — jq is unavailable or .tool_input.command could not be parsed, but the raw input looks merge-related. Refusing to merge until CI status can be verified. Restore jq (see .claude/hooks/check-jq-installed.sh) and retry." >&2
    exit 2
  fi
  exit 0
fi

if ! is_merge_command "$COMMAND"; then
  exit 0
fi

# Variable-substituted merge (#643): if the PR arg or --repo value is an
# unexpanded shell variable, this hook can't resolve the real target from the
# command text — the old code fell back to the CWD's PR and checked an
# UNRELATED PR's CI (and passed `$REPO` to gh, producing garbage errors). A CI
# gate must not guess. Block with a clear, accurate instruction instead.
if merge_command_uses_variable "$COMMAND"; then
  cat >&2 <<'EOF'
BLOCKED: cannot verify CI on a variable-substituted merge command.

This gate reads the literal command text and can't resolve shell variables
(e.g. `gh pr merge $PR --repo $REPO` or `glab mr merge $MR -R $REPO`) to the
real PR/MR or repo, so it cannot check the correct one's CI status. Re-run
with literal values:

  gh pr merge <number> --repo <owner>/<repo> --squash
  glab mr merge <iid> -R <owner>/<repo>

(Use the actual PR/MR number and owner/repo — not shell variables.)
EOF
  exit 2
fi

# Parse --repo / -R (for `gh pr merge --repo owner/repo` or `glab mr merge -R
# owner/repo`). Uses the shared extractor, which also recovers the repo from a
# `gh api .../pulls/<N>/merge` or `glab api .../merge_requests/<N>/merge` URL
# path so the CI-status check below is still scoped correctly.
CMD_REPO=$(resolve_merge_repo "$COMMAND")

PR_NUMBER=$(extract_pr_number "$COMMAND")

if [ -z "$PR_NUMBER" ]; then
  # Another hook will handle "no PR number" — skip
  exit 0
fi

# Forge dispatch (#790): the command text normally says which CLI it drives —
# the same detector _lib-extract-pr.sh's own resolvers use internally. The
# `tracker_pr_merge` wrapper (#759) is the one shape where that's NOT true by
# design — the wrapper's whole point is that its OWN text never says "gh" or
# "glab" (that choice lives in the registry, resolved at call time via
# `tracker_kind`). Text-based `_forge_from_command` would silently default to
# "gh" for a glab-kind project calling the wrapper, so for that shape ONLY,
# dispatch via the registry (`_forge_kind_for`, the same resolver
# resolve_pr_head/resolve_pr_head_branch already use) instead. Every other
# shape (explicit `gh pr merge` / `gh api` / `glab mr merge` / `glab api`)
# keeps the original text-based dispatch unchanged — this preserves the
# existing #790 test behaviour exactly.
if echo "$COMMAND" | grep -qE '\btracker_pr_merge\b'; then
  FORGE=$(_forge_kind_for "$CMD_REPO")
  # #1121: _forge_kind_for's registry read needs yq or python3+PyYAML; when
  # NEITHER is installed it silently falls through to the global "gh"
  # default. That default is ambiguous here — it could be a genuine gh-kind
  # project, or a glab-kind project whose registry entry just couldn't be
  # read. Cross-check with the dependency-free scan (see
  # _registry_glab_fallback above) whenever the primary answer is "gh": it
  # can only ever confirm "glab", never override a real "glab" result or
  # invent a false positive for a project the registry doesn't explicitly
  # mark as glab.
  if [ "$FORGE" = "gh" ]; then
    REGISTRY_FORGE=$(_registry_glab_fallback "$CMD_REPO")
    if [ "$REGISTRY_FORGE" = "glab" ]; then
      FORGE="glab"
    fi
  fi
else
  FORGE=$(_forge_from_command "$COMMAND")
fi
if [ "$FORGE" = "glab" ]; then
  # --- GitLab path ---
  PIPELINE_STATUS=$(resolve_ci_status_glab "$PR_NUMBER" "$CMD_REPO")

  case "$PIPELINE_STATUS" in
    success)
      exit 0
      ;;
    none)
      echo "NOTE: MR !${PR_NUMBER} has no pipeline configured. Merge-on-red-CI gate is a no-op for this MR." >&2
      exit 0
      ;;
    *)
      # pending | failure | "" (unresolvable) — all three BLOCK. An empty
      # status must never be treated as green: if glab is missing, the
      # network/auth failed, or the response was unparseable, that is a
      # reason to block, not a reason to guess "probably fine".
      STATUS_DESC="${PIPELINE_STATUS:-unresolvable (glab CLI missing, network/auth failure, or unparseable response)}"
      cat >&2 <<MSG
BLOCKED: MR !${PR_NUMBER} has red or unresolvable CI. Cannot merge.

\`glab mr view ${PR_NUMBER}\` reports pipeline status: ${STATUS_DESC}

ApexYard rule (.claude/rules/pr-quality.md § "No Red CI Before Merge"):

  "Never merge with red CI — even if the failure is pre-existing or
  unrelated. Fix the pre-existing issue first (separate commit), rebase
  the PR so all checks are green, and only then merge."

To unblock:

  1. Look at the pipeline: \`glab mr view ${PR_NUMBER} --web\` or
     \`glab ci status\` on the MR's source branch
  2. If the failure is in YOUR change, fix it and push
  3. If the failure is PRE-EXISTING (pipeline was already red on the target
     branch), fix the pre-existing issue in a separate commit, then retry
  4. If the pipeline is PENDING, wait for it to finish, then retry
  5. If the status could not be fetched at all, check glab auth/network and
     retry — this gate fails CLOSED on an unresolvable status
  6. Re-invoke Rex after any new commit (re-review required)
  7. Retry \`glab mr merge ${PR_NUMBER}\`

No exceptions. Not even for "unrelated" failures. Red or unresolvable CI
stays blocking until someone fixes it — that's the whole point of the rule.
MSG
      exit 2
      ;;
  esac
fi

# --- GitHub path ---
# Validate the repo before any gh call receives it. An omitted --repo uses
# the current repository; keep the validated value in a Bash argument array.
GATE_OWNER_REPO="$CMD_REPO"
if [ -z "$GATE_OWNER_REPO" ]; then
  GATE_OWNER_REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null)
fi
# gh accepts [HOST/]OWNER/REPO for --repo (GitHub Enterprise). `gh pr`
# takes the full value. `gh api` paths take OWNER/REPO, with the host in
# --hostname.
GATE_HOST=""
GATE_API_REPO="$GATE_OWNER_REPO"
if [[ "$GATE_OWNER_REPO" == */*/* ]]; then
  GATE_HOST="${GATE_OWNER_REPO%%/*}"
  GATE_API_REPO="${GATE_OWNER_REPO#*/}"
fi
if [[ ! "$GATE_API_REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] ||
   [[ "$GATE_API_REPO" == ./* || "$GATE_API_REPO" == ../* ||
      "$GATE_API_REPO" == */. || "$GATE_API_REPO" == */.. ]] ||
   { [ -n "$GATE_HOST" ] && [[ ! "$GATE_HOST" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]]; }; then
  echo "BLOCKED: PR #${PR_NUMBER} has an invalid owner/repo: ${GATE_OWNER_REPO:-<empty>}. Use a literal [host/]owner/repo and retry." >&2
  exit 2
fi
REPO_ARGS=()
if [ -n "$CMD_REPO" ]; then
  REPO_ARGS=(--repo "$GATE_OWNER_REPO")
fi
API_HOST_ARGS=()
if [ -n "$GATE_HOST" ]; then
  API_HOST_ARGS=(--hostname "$GATE_HOST")
fi

# Query checks. gh pr checks returns text output; we check both the exit
# code and whether the whole trimmed output is the CLI's exact no-checks
# message (#1523 — a substring match wrongly allowed a check NAME that
# contained "no checks reported").
# ${arr[@]+"${arr[@]}"}: bash 3.2 treats an empty "${arr[@]}" as unbound
# under set -u. This form expands to nothing when the array is empty.
CHECKS_OUTPUT=$(gh pr checks "$PR_NUMBER" ${REPO_ARGS[@]+"${REPO_ARGS[@]}"} 2>&1)
CHECKS_RC=$?

# "no checks reported on the 'X' branch" — allow only when BOTH: checks
# exited non-zero, AND the entire trimmed output matches that exact CLI
# message. A substring match is not enough, because a contributor controls
# check names and a `pull_request` run uses the PR's own workflow files
# (#1523).
#
# The Actions query below also runs when checks exit 0. A gated or newly
# queued run can be invisible to `gh pr checks` while other checks pass.
_checks_trimmed="${CHECKS_OUTPUT#"${CHECKS_OUTPUT%%[![:space:]]*}"}"
_checks_trimmed="${_checks_trimmed%"${_checks_trimmed##*[![:space:]]}"}"
# [^[:cntrl:]] and not .: in bash =~, . also matches a newline, so a
# multi-line check list that starts and ends with the right text would
# match. Branch names cannot contain control characters.
_no_checks_re="^no checks reported on the '[^[:cntrl:]]*' branch$"
NO_CHECKS=0
if [ "$CHECKS_RC" -ne 0 ] && [[ "$_checks_trimmed" =~ $_no_checks_re ]]; then
  NO_CHECKS=1
fi

# Workflow runs live in the base repo. Validate the head before using it
# in an API path. A malformed PR head blocks rather than becoming an API fault.
GATE_HEAD_SHA=$(gh pr view "$PR_NUMBER" ${REPO_ARGS[@]+"${REPO_ARGS[@]}"} --json headRefOid --jq '.headRefOid' 2>/dev/null)
if [[ ! "$GATE_HEAD_SHA" =~ ^[0-9a-fA-F]{40}$ ]]; then
  echo "BLOCKED: PR #${PR_NUMBER} has an invalid head SHA. Resolve the PR head and retry." >&2
  exit 2
fi

# Only the exact no-checks response needs a workflow inventory to preserve
# the genuine no-CI note. A failed inventory is an unverified-CI result.
WORKFLOW_COUNT=""
WORKFLOW_ERROR=""
if [ "$NO_CHECKS" = "1" ]; then
  WORKFLOWS_JSON=$(gh api ${API_HOST_ARGS[@]+"${API_HOST_ARGS[@]}"} "repos/${GATE_API_REPO}/actions/workflows?per_page=100" 2>/dev/null)
  WORKFLOW_RC=$?
  if [ "$WORKFLOW_RC" -ne 0 ]; then
    WORKFLOW_ERROR="workflow query failed"
  elif ! printf '%s' "$WORKFLOWS_JSON" | jq -e '
    type == "object" and
    (.total_count | type == "number" and . >= 0 and floor == .) and
    (.workflows | type == "array") and
    all(.workflows[]; type == "object" and (.state | type == "string"))
  ' >/dev/null 2>&1; then
    WORKFLOW_ERROR="workflow response was incomplete or invalid"
  elif [ "$(printf '%s' "$WORKFLOWS_JSON" | jq -r '.total_count')" != "$(printf '%s' "$WORKFLOWS_JSON" | jq -r '.workflows | length')" ]; then
    WORKFLOW_ERROR="workflow response was incomplete or invalid"
  else
    WORKFLOW_COUNT=$(printf '%s' "$WORKFLOWS_JSON" | jq -r '[.workflows[] | select(.state == "active")] | length')
  fi
fi

# One head-filtered request per merge. A partial page cannot prove that
# every run passed, so refuse a merge if the response reports more runs
# than this request returned.
RUNS_JSON=$(gh api ${API_HOST_ARGS[@]+"${API_HOST_ARGS[@]}"} "repos/${GATE_API_REPO}/actions/runs?head_sha=${GATE_HEAD_SHA}&per_page=100" 2>/dev/null)
RUNS_RC=$?
RUNS_ERROR=""
if [ "$RUNS_RC" -ne 0 ]; then
  RUNS_ERROR="run query failed"
elif ! printf '%s' "$RUNS_JSON" | jq -e '
  type == "object" and
  (.total_count | type == "number" and . >= 0 and floor == .) and
  (.workflow_runs | type == "array") and
  (.total_count >= (.workflow_runs | length)) and
  all(.workflow_runs[]; type == "object" and
    (.workflow_id | type == "number") and
    (.run_number | type == "number") and
    (.event | type == "string") and
    (.created_at | type == "string") and
    (.id | type == "number") and
    (.name == null or (.name | type == "string")) and
    (.status | type == "string") and
    has("conclusion") and
    (.conclusion == null or (.conclusion | type == "string")))
' >/dev/null 2>&1; then
  RUNS_ERROR="run response was incomplete or invalid"
fi

# Apply the same latest-run rule to complete and partly invalid responses.
# In an invalid response, only inspect runs whose blocking state and selection
# keys can be read. Missing tie-break fields sort before valid values.
BLOCKING_RUNS=""
if printf '%s' "$RUNS_JSON" | jq -e 'type == "object"' >/dev/null 2>&1; then
  BLOCKING_RUNS=$(printf '%s' "$RUNS_JSON" | jq -r '
  (.workflow_runs | if type == "array" then . else [] end) |
  map(select(type == "object" and
    (.workflow_id | type == "number") and
    (.run_number | type == "number") and
    (.status | type == "string") and
    has("conclusion") and
    (.conclusion == null or (.conclusion | type == "string")))) |
  group_by([.workflow_id, .event]) |
  map(max_by([.run_number,
    (.created_at | if type == "string" then . else "" end),
    (.id | if type == "number" then . else 0 end)]))[] |
  select(.conclusion == "action_required" or .status != "completed" or
    (.conclusion != "success" and .conclusion != "neutral" and .conclusion != "skipped")) |
  # Keep the outer parentheses: jq 1.7 and 1.8 bind `A // B as $x | …`
  # differently, and 1.7 would drop the status line for a named run.
  ((.name | if type == "string" and . != "" then . else null end) //
    ("workflow " + (.workflow_id | tostring))) as $run_name |
  "\($run_name) — status=\(.status), conclusion=\(.conclusion // "none")"
' 2>/dev/null)
  BLOCKING_RUNS_RC=$?
  if [ "$BLOCKING_RUNS_RC" -ne 0 ]; then
    echo "BLOCKED: PR #${PR_NUMBER}: the gate cannot evaluate the head runs. Retry when jq can read the Actions response." >&2
    exit 2
  fi
fi

if [ -n "$BLOCKING_RUNS" ]; then
  if [ -n "$RUNS_ERROR" ]; then
    echo "BLOCKED: PR #${PR_NUMBER}: the Actions runs response was partly invalid (${RUNS_ERROR}) but showed a failing run for head ${GATE_HEAD_SHA}:" >&2
    printf '%s\n' "$BLOCKING_RUNS" >&2
  else
    cat >&2 <<MSG
BLOCKED: PR #${PR_NUMBER} has workflow runs that have not passed for head ${GATE_HEAD_SHA}:
${BLOCKING_RUNS}

To unblock: Approve runs at action_required on the PR Checks tab. Wait for
queued or in-progress runs to finish. Fix failed or cancelled runs, then
retry the merge after each workflow's latest run has a success, neutral, or
skipped conclusion.
MSG
  fi
  exit 2
fi

# Count the returned page independently of full run validation. Even an
# invalid run cannot make an incomplete page safe to merge.
PARTIAL_PAGE=$(printf '%s' "$RUNS_JSON" | jq -r '
  if type == "object" and
     (.total_count | type == "number") and
     (.workflow_runs | type == "array") then
    (.workflow_runs | length) as $page_count |
    select(.total_count > $page_count) |
    "\(.total_count)\t\($page_count)"
  else empty end
' 2>/dev/null)
if [ -n "$PARTIAL_PAGE" ]; then
  IFS="$(printf '\t')" read -r RUN_COUNT PAGE_COUNT <<< "$PARTIAL_PAGE"
  echo "BLOCKED: PR #${PR_NUMBER} has ${RUN_COUNT} head workflow runs, but the Actions API returned only ${PAGE_COUNT}. Review all head runs and retry when the gate can check every run." >&2
  exit 2
fi

if [ -n "$RUNS_ERROR" ]; then
  echo "NOTE: PR #${PR_NUMBER}: CI state could not be checked (Actions API unavailable: ${RUNS_ERROR}). Merge-on-red-CI gate did not verify CI state." >&2
  if [ "$CHECKS_RC" = "0" ] || [ "$NO_CHECKS" = "1" ]; then
    exit 0
  fi
else
  RUN_COUNT=$(printf '%s' "$RUNS_JSON" | jq -r '.total_count')
fi

if [ -n "$WORKFLOW_ERROR" ]; then
  echo "NOTE: PR #${PR_NUMBER}: CI state could not be checked (Actions API unavailable: ${WORKFLOW_ERROR}). Merge-on-red-CI gate did not verify CI state." >&2
  exit 0
fi

if [ "$NO_CHECKS" = "1" ]; then
  if [ "$WORKFLOW_COUNT" = "0" ] && [ "$RUN_COUNT" = "0" ]; then
    echo "NOTE: PR #${PR_NUMBER} has no CI checks configured. Merge-on-red-CI gate is a no-op for this PR." >&2
  elif [ "$RUN_COUNT" = "0" ]; then
    echo "NOTE: PR #${PR_NUMBER} reports no CI checks, though the repo has ${WORKFLOW_COUNT} active workflow(s) — no run matched this head (path or branch filters, most likely). Merge-on-red-CI gate is a no-op for this PR; no CI result validated this head." >&2
  fi
  exit 0
fi

if [ "$CHECKS_RC" = "0" ]; then
  exit 0
fi

# Red CI (exit 1) or unknown non-zero. Emit the raw check output in the
# error message so the user can see exactly which checks are red.
cat >&2 <<MSG
BLOCKED: PR #${PR_NUMBER} has red CI. Cannot merge.

\`gh pr checks ${PR_NUMBER}\` reported failures or pending checks:

$(echo "$CHECKS_OUTPUT" | head -30 | sed 's/^/  /')

ApexYard rule (.claude/rules/pr-quality.md § "No Red CI Before Merge"):

  "Never merge with red CI — even if the failure is pre-existing or
  unrelated. Fix the pre-existing issue first (separate commit), rebase
  the PR so all checks are green, and only then merge."

To unblock:

  1. Look at the failing check logs: \`gh pr checks ${PR_NUMBER} --watch\`
     or click through from https://github.com/{owner}/{repo}/pull/${PR_NUMBER}
  2. If the failure is in YOUR change, fix it and push
  3. If the failure is PRE-EXISTING (CI was already red on main), fix the
     pre-existing issue in a separate commit on this branch, then retry
  4. If checks are PENDING, wait for them to finish, then retry
  5. Re-invoke Rex after any new commit (re-review required)
  6. Retry \`gh pr merge ${PR_NUMBER}\`

No exceptions. Not even for "unrelated" failures. Red CI stays red until
someone fixes it — that's the whole point of the rule.
MSG
exit 2
