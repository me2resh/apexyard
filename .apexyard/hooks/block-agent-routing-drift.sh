#!/bin/bash
# Pre-commit + pre-push drift guard for .apexyard/agents/*.md routing.
#
# Per AgDR-0050 § Axis 4 + ticket #351 PR 2 — the sibling to
# apply-agent-routing.sh. The sync hook REWRITES agent-file model: lines
# at SessionStart from the adopter's agent-routing.yaml; this guard
# REFUSES to let those rewrites escape to a commit (which would leak the
# adopter's private routing choices to the public fork on push).
#
# Mechanism:
#   - Fires on `git commit -m` AND `git push` (per the matcher entries
#     in .claude/settings.json)
#   - For each staged (commit) or to-be-pushed (push) .apexyard/agents/*.md
#     file:
#       1. Read its current model: line
#       2. Compare against the framework default — first preference is
#          the snapshot at .apexyard/agents/.framework-defaults.json
#          (written by the sync hook on the most recent SessionStart);
#          fallback is `git show dev:.apexyard/agents/<name>.md` (works
#          on forks tracking upstream/dev), then `git show
#          upstream/main:...`, then `git show HEAD:...`
#       3. If different AND the file does NOT carry the escape-hatch
#          comment "# routing-config:override <reason>" anywhere in
#          frontmatter or body, BLOCK with a clear self-correction
#          message naming the file + actual + expected models
#       4. Silent + exit 0 on no drift
#
# Escape hatch: when the operator INTENTIONALLY wants to change the
# framework default (e.g. switching QA from haiku → sonnet across the
# whole framework, not just for one adopter), they add the comment
# `# routing-config:override <reason>` to the agent file and the guard
# accepts the new default. The comment is deliberately visible — it
# documents WHY the framework default changed and ships with the PR.
#
# Like check-secrets.sh + block-private-refs-in-public-repos.sh, this
# is a mechanical backstop against routine-but-damaging leaks. Self-
# discipline is the primary defence (adopters know not to commit
# routing-rewritten agent files); the hook catches the case where the
# agent had the rewritten file right in front of it during `git add`
# and didn't actively suppress it.

set -u

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)

if [ -z "$COMMAND" ]; then
  exit 0
fi

# Only fire on commit or push.
IS_COMMIT=0
IS_PUSH=0
if echo "$COMMAND" | grep -qE '\bgit\s+commit\b'; then
  IS_COMMIT=1
elif echo "$COMMAND" | grep -qE '\bgit\s+push\b'; then
  IS_PUSH=1
else
  exit 0
fi

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
if [ -z "$REPO_ROOT" ]; then
  exit 0
fi

# Walk up to find ops fork root (same shape as the other gates).
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT=""
if [ -f "$HOOK_DIR/_lib-ops-root.sh" ]; then
  # shellcheck source=/dev/null
  . "$HOOK_DIR/_lib-ops-root.sh"
  ROOT=$(resolve_ops_root "$REPO_ROOT")
else
  cur="$REPO_ROOT"
  while [ -n "$cur" ] && [ "$cur" != "/" ]; do
    if [ -f "$cur/.apexyard-fork" ]; then ROOT="$cur"; break; fi
    if [ -f "$cur/onboarding.yaml" ] && [ -f "$cur/apexyard.projects.yaml" ]; then ROOT="$cur"; break; fi
    cur=$(dirname "$cur")
  done
fi

if [ -z "$ROOT" ]; then
  exit 0
fi

AGENTS_DIR="$ROOT/.apexyard/agents"
[ -d "$AGENTS_DIR" ] || exit 0

# -----------------------------------------------------------------------------
# Discover candidate files: staged on commit; in to-be-pushed commits on push.
# -----------------------------------------------------------------------------
get_candidate_files() {
  if [ "$IS_COMMIT" -eq 1 ]; then
    # Staged adds + modifies (renames + copies follow under R/C).
    git -C "$ROOT" diff --cached --name-only --diff-filter=ACMR 2>/dev/null \
      | grep -E '^\.apexyard/agents/[^/]+\.md$' || true
    return 0
  fi
  if [ "$IS_PUSH" -eq 1 ]; then
    # Files modified in unpushed commits on the current branch. Use the
    # upstream tracking ref if available; fall back to origin/<branch>;
    # fall back to dev as a last-resort baseline.
    cur_branch=$(git -C "$ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null)
    upstream_ref=$(git -C "$ROOT" rev-parse --abbrev-ref "@{upstream}" 2>/dev/null || true)
    base=""
    if [ -n "$upstream_ref" ]; then
      base="$upstream_ref"
    elif git -C "$ROOT" rev-parse --verify "origin/$cur_branch" >/dev/null 2>&1; then
      base="origin/$cur_branch"
    elif git -C "$ROOT" rev-parse --verify dev >/dev/null 2>&1; then
      base="dev"
    fi
    if [ -z "$base" ]; then
      # Brand-new branch with no comparable base — fall back to the last
      # 5 commits (better than nothing without false-positiving).
      git -C "$ROOT" diff --name-only HEAD~5..HEAD 2>/dev/null \
        | grep -E '^\.apexyard/agents/[^/]+\.md$' || true
      return 0
    fi
    git -C "$ROOT" diff --name-only "$base..HEAD" 2>/dev/null \
      | grep -E '^\.apexyard/agents/[^/]+\.md$' || true
  fi
}

CANDIDATES=$(get_candidate_files | sort -u)
if [ -z "$CANDIDATES" ]; then
  exit 0
fi

DEFAULTS_FILE="$AGENTS_DIR/.framework-defaults.json"

# -----------------------------------------------------------------------------
# Resolve the framework-default model: for an agent. Tries (in order):
#   1. Snapshot at .apexyard/agents/.framework-defaults.json (written by
#      apply-agent-routing.sh on the most recent SessionStart)
#   2. dev:.apexyard/agents/<name>.md frontmatter
#   3. upstream/main:.apexyard/agents/<name>.md frontmatter
#   4. HEAD:.apexyard/agents/<name>.md frontmatter (last-resort — handles
#      brand-new agent files where dev hasn't been tracked yet)
#
# Empty string when nothing resolves (silent allow — better than false
# positive on a hook whose drift baseline is unknowable).
# -----------------------------------------------------------------------------
framework_default_for() {
  local agent_name="$1"
  local m=""

  # 1. Snapshot file.
  if [ -f "$DEFAULTS_FILE" ]; then
    # Cheap key lookup: "<name>":"<value>"  (json format from sync hook).
    m=$(grep -oE "\"${agent_name}\":\"[^\"]+\"" "$DEFAULTS_FILE" 2>/dev/null \
        | head -1 \
        | sed -E 's/.*:"([^"]+)"/\1/')
    if [ -n "$m" ]; then
      echo "$m"
      return 0
    fi
  fi

  # 2. dev baseline.
  if git -C "$ROOT" rev-parse --verify dev >/dev/null 2>&1; then
    m=$(git -C "$ROOT" show "dev:.apexyard/agents/${agent_name}.md" 2>/dev/null \
        | awk '/^---/{count++; next} count==1 && /^model:/ {sub(/^model:[[:space:]]*/, ""); print; exit}')
    [ -n "$m" ] && { echo "$m"; return 0; }
  fi

  # 3. upstream/main baseline.
  if git -C "$ROOT" rev-parse --verify upstream/main >/dev/null 2>&1; then
    m=$(git -C "$ROOT" show "upstream/main:.apexyard/agents/${agent_name}.md" 2>/dev/null \
        | awk '/^---/{count++; next} count==1 && /^model:/ {sub(/^model:[[:space:]]*/, ""); print; exit}')
    [ -n "$m" ] && { echo "$m"; return 0; }
  fi

  # 4. HEAD baseline (handles brand-new agent file in this commit).
  m=$(git -C "$ROOT" show "HEAD:.apexyard/agents/${agent_name}.md" 2>/dev/null \
      | awk '/^---/{count++; next} count==1 && /^model:/ {sub(/^model:[[:space:]]*/, ""); print; exit}')
  [ -n "$m" ] && echo "$m"
}

# -----------------------------------------------------------------------------
# Read the CURRENT (staged) model: line from a candidate file. We prefer
# staged content (commit shape) so a working-tree edit that's not yet
# staged doesn't false-trigger the gate.
# -----------------------------------------------------------------------------
current_model_for() {
  local rel="$1"
  if [ "$IS_COMMIT" -eq 1 ]; then
    git -C "$ROOT" show ":$rel" 2>/dev/null \
      | awk '/^---/{count++; next} count==1 && /^model:/ {sub(/^model:[[:space:]]*/, ""); print; exit}'
  else
    # Push: read from HEAD (the commit we're about to push).
    git -C "$ROOT" show "HEAD:$rel" 2>/dev/null \
      | awk '/^---/{count++; next} count==1 && /^model:/ {sub(/^model:[[:space:]]*/, ""); print; exit}'
  fi
}

# -----------------------------------------------------------------------------
# Detect the escape-hatch comment. Format: "# routing-config:override <reason>"
# Looked for anywhere in the file (frontmatter or body). The reason is
# free-text and not validated.
# -----------------------------------------------------------------------------
has_escape_hatch() {
  local rel="$1"
  local content=""
  if [ "$IS_COMMIT" -eq 1 ]; then
    content=$(git -C "$ROOT" show ":$rel" 2>/dev/null)
  else
    content=$(git -C "$ROOT" show "HEAD:$rel" 2>/dev/null)
  fi
  echo "$content" | grep -qE '^[[:space:]]*#[[:space:]]*routing-config:override[[:space:]]+\S'
}

DRIFT_FOUND=""
DRIFT_DETAILS=""

while IFS= read -r rel; do
  [ -z "$rel" ] && continue
  agent_name=$(basename "$rel" .md)
  current=$(current_model_for "$rel")
  expected=$(framework_default_for "$agent_name")

  # No expected baseline (e.g. brand-new agent file) — allow.
  if [ -z "$expected" ]; then
    continue
  fi
  # No current value (file doesn't have a model: line) — allow; out of
  # scope for this guard.
  if [ -z "$current" ]; then
    continue
  fi
  if [ "$current" = "$expected" ]; then
    continue
  fi
  # Drift detected — check for the escape hatch before blocking.
  if has_escape_hatch "$rel"; then
    continue
  fi

  DRIFT_FOUND=1
  DRIFT_DETAILS="${DRIFT_DETAILS}  $rel — model: $current  (framework default: $expected)
"
done <<< "$CANDIDATES"

if [ -z "$DRIFT_FOUND" ]; then
  exit 0
fi

cat >&2 <<MSG
BLOCKED: agent-file model: drift detected.

$DRIFT_DETAILS
Your routing config is leaking into the agent file — this should NEVER
happen because adopter overrides come from agent-routing.yaml, not from
edits to the committed agent file. The SessionStart sync hook
(apply-agent-routing.sh, AgDR-0050 § Axis 4) rewrites the agent file's
model: line at session start from your YAML override — but those
rewrites must stay LOCAL to the working tree, never committed.

To unblock:

  (a) Revert the model: line back to the framework default on the
      file(s) above (commands at the bottom of this message). The sync
      hook will RE-APPLY your agent-routing.yaml override on the next
      session — your routing choice is preserved.

  (b) If this is an INTENTIONAL framework-default change (rare; e.g.
      switching the framework's QA Engineer default from haiku to
      sonnet, or adding a brand-new agent), add the escape-hatch
      comment to the agent file's frontmatter or body:

          # routing-config:override <reason>

      The reason is free-text — write a sentence explaining why the
      framework default is changing. The comment ships with the PR and
      makes the deliberate-change visible.

Revert commands (run from the ops-fork root):

  # Restore the file to the framework default (dev baseline):
  git checkout dev -- <file>

  # OR, hand-edit the model: line back to the framework default and
  # restage:
  \$EDITOR <file>          # change model: line back to the default
  git add <file>

See AgDR-0050 § Axis 4 for the design and
.apexyard/rules/leak-protection.md for the broader leak-prevention pattern.
MSG

exit 2
