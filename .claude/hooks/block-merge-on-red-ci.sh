#!/bin/bash
# CLASS: CONTROL (AgDR-0104 labelling, AgDR-0109). This hook decides on
# STRUCTURED STATE, not on the text of a command: the CI conclusion the forge reports for the PR's HEAD.
# That is what makes it trustworthy where a text-matching backstop like
# warn-review-marker-write.sh is not. Keep it fail-closed: if it cannot
# evaluate its precondition it must block, never allow (AgDR-0104).
#
# PreToolUse hook on `gh pr merge` / `gh api .../pulls/<N>/merge` AND their
# GitLab counterparts `glab mr merge` / `glab api .../merge_requests/<N>/merge`:
# blocks the merge if CI is failing, pending, or unresolvable.
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
# GH PATH (unchanged, byte-identical to pre-#790 behaviour)
# -----------------------------------------------------------
# Uses `gh pr checks <pr>` which returns one line per check with status.
# Exit codes:
#   0 = all checks passed (and none required are missing)
#   1 = at least one check failed, was cancelled, or skipped
#   8 = no checks at all
#
# The hook allows:
#   - exit 0 (all green)
#   - exit 8 if the repo has no CI (gh pr checks returns "no checks" — allow)
# Blocks:
#   - exit 1 (red CI)
#   - any check with state FAILURE | CANCELLED | TIMED_OUT
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

# Shared merge-shape detector + PR-number parser (see _lib-extract-pr.sh).
# Handles `gh pr merge <N>`, `gh api repos/<owner>/<repo>/pulls/<N>/merge`,
# `glab mr merge <N>`, and `glab api .../merge_requests/<N>/merge` (#764/#767).
# Sourced BEFORE the jq-based command parse below (moved up from its
# original position after the parse) so is_merge_command is available as
# the jq-independent fallback detector when the parse can't be trusted —
# see #965.
. "$(dirname "$0")/_lib-extract-pr.sh"

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
  if is_merge_command "$(_normalize_json_escapes "$INPUT")"; then
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
CMD_REPO=$(extract_repo_from_command "$COMMAND")
REPO_FLAG=""
if [ -n "$CMD_REPO" ]; then
  REPO_FLAG="--repo $CMD_REPO"
fi

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

# --- GitHub path (unchanged, byte-identical to pre-#790 behaviour) ---
# Query checks. gh pr checks returns text output; we check both the exit code
# and a "no checks reported" substring — the latter is how gh reports the
# genuinely-unchecked case regardless of exit code version.
CHECKS_OUTPUT=$(gh pr checks "$PR_NUMBER" $REPO_FLAG 2>&1)
CHECKS_RC=$?

# "no checks reported on the 'X' branch" — legitimate no-CI state. Allow.
# Projects without CI (or branches without the expected workflow wiring)
# hit this path. Log a single-line note so the user knows the gate was a no-op.
if echo "$CHECKS_OUTPUT" | grep -q "no checks reported"; then
  echo "NOTE: PR #${PR_NUMBER} has no CI checks configured. Merge-on-red-CI gate is a no-op for this PR." >&2
  exit 0
fi

if [ "$CHECKS_RC" = "0" ]; then
  # All green — allow
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
