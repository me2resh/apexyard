#!/bin/bash
# Non-blocking advisory hook: when a `gh pr create` diff touches a trust-chain
# hook labelled `# CLASS: CONTROL` (the AgDR-0104 typology), print a one-line
# reminder to make sure the change has, or updates, a paired adversarial test.
#
# This is the shipped outcome of me2resh/apexyard#1057. #1057 asked for a
# blocking CI meta-gate that fails when a CONTROL hook has no paired
# adversarial test. AgDR-0117 rejected that gate: every CONTROL hook already
# has adversarial-test coverage today (zero gap to close), the spec'd gate is
# defeatable by construction (an omitted entry in a hand-maintained trust-chain
# list, or a strawman test that merely asserts a token appears), and it would
# duplicate the #871 conformance framework's job. AgDR-0117 instead ships this
# lightweight advisory nudge — the same "text-matching can't be made sound,
# prefer self-discipline + a cheap reminder" lineage as AgDR-0104 and
# AgDR-0111. See docs/agdr/AgDR-0104-trust-chain-controls-vs-backstops.md,
# AgDR-0111-marker-gate-plain-advisory.md, and AgDR-0117 itself.
#
# NOTE ON TAXONOMY: this hook is NOT itself a CONTROL or a BACKSTOP in the
# AgDR-0104 sense — it doesn't gate a merge or decide on structured state, it
# only prints a reminder. That's why it carries no `# CLASS:` header of its
# own; that header is reserved for hooks that are part of the trust chain's
# enforcement machinery.
#
# How the CONTROL set is derived (the load-bearing design choice, per the
# Contrarian's challenge on #1057): NOT a hand-maintained config list, which
# is trivially defeated by omission (add a new CONTROL hook, forget to add it
# to the list, the gate never fires on it). Instead this hook greps every
# `.claude/hooks/*.sh` file for its OWN `# CLASS: CONTROL` header at grep time,
# on every invocation. A hook can only escape detection by removing its own
# CLASS header — which is a loud, reviewable, self-incriminating edit, not a
# silent omission in a separate file.
#
# Behaviour:
#   - Matches ONLY on `gh pr create …`. Silent no-op on every other command.
#   - Computes the diff vs the base branch (parsed from --base; falls back
#     to origin/dev, upstream/dev, origin/main, upstream/main, main, master —
#     same fallback order as require-agdr-for-arch-pr.sh, minus that hook's
#     cross-repo/cd-target machinery, which a BLOCKING gate needs and this
#     advisory nudge does not: an occasional false negative here just means
#     one PR doesn't get a reminder it could have used, not a bypassed gate).
#   - If any changed file is a `.claude/hooks/*.sh` file carrying its own
#     `# CLASS: CONTROL` header, print ONE line to stderr naming the touched
#     hook(s) and reminding the author to add/update a paired adversarial
#     test. Exit 0.
#   - In every other case (no match, unresolvable base, unreadable hooks dir,
#     empty diff) — silent exit 0.
#
# Exit 0 in EVERY path. This hook must never block `gh pr create`.

set -u

INPUT=$(cat)
COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)

[ -z "$COMMAND" ] && exit 0

# Match only `gh pr create …`.
if ! printf '%s' "$COMMAND" | grep -qE '\bgh[[:space:]]+pr[[:space:]]+create\b'; then
  exit 0
fi

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
[ -z "$REPO_ROOT" ] && exit 0

HOOKS_DIR="$REPO_ROOT/.claude/hooks"
[ -d "$HOOKS_DIR" ] || exit 0

gitr() { git -C "$REPO_ROOT" "$@"; }

# ---------------------------------------------------------------------------
# 1. Resolve the base branch and compute the PR's changed files.
# ---------------------------------------------------------------------------

extract_base_flag() {
  # Very small extractor: only needs to recover a simple --base/-B value.
  # Unlike the extractors in require-agdr-for-arch-pr.sh, this hook is
  # advisory-only, so a missed --base value just falls through to the
  # fallback candidate list below — no false-block risk.
  printf '%s' "$COMMAND" | grep -oE -- '(--base|-B)[[:space:]=]+[^[:space:]]+' \
    | head -1 \
    | sed -E 's/^(--base|-B)[[:space:]=]+//' \
    | tr -d "\"'"
}

resolve_ref() {
  local ref="$1"
  gitr rev-parse --verify --quiet "$ref" >/dev/null 2>&1 && printf '%s' "$ref"
}

BASE_ARG=$(extract_base_flag)
BASE_REF=""

if [ -n "$BASE_ARG" ]; then
  for candidate in "origin/$BASE_ARG" "upstream/$BASE_ARG" "$BASE_ARG"; do
    r=$(resolve_ref "$candidate")
    [ -n "$r" ] && { BASE_REF="$r"; break; }
  done
fi

if [ -z "$BASE_REF" ]; then
  for candidate in origin/dev upstream/dev origin/main upstream/main main master; do
    r=$(resolve_ref "$candidate")
    [ -n "$r" ] && { BASE_REF="$r"; break; }
  done
fi

[ -z "$BASE_REF" ] && exit 0

MERGE_BASE=$(gitr merge-base HEAD "$BASE_REF" 2>/dev/null)
[ -z "$MERGE_BASE" ] && exit 0

CHANGED_FILES=$(gitr diff --name-only "$MERGE_BASE"..HEAD 2>/dev/null)
[ -z "$CHANGED_FILES" ] && exit 0

# ---------------------------------------------------------------------------
# 2. Derive the CONTROL set from the hooks' own headers — not a config list.
# ---------------------------------------------------------------------------

CONTROL_HOOKS=$(grep -l '^# CLASS: CONTROL' "$HOOKS_DIR"/*.sh 2>/dev/null | xargs -n1 basename 2>/dev/null)
[ -z "$CONTROL_HOOKS" ] && exit 0

# ---------------------------------------------------------------------------
# 3. Intersect the PR's changed files with the CONTROL set.
# ---------------------------------------------------------------------------

TOUCHED=""
while IFS= read -r file; do
  [ -z "$file" ] && continue
  base=$(basename "$file")
  case "$file" in
    */.claude/hooks/"$base"|.claude/hooks/"$base") : ;;
    *) continue ;;
  esac
  while IFS= read -r ctrl; do
    [ -z "$ctrl" ] && continue
    if [ "$base" = "$ctrl" ]; then
      TOUCHED="${TOUCHED}${base} "
    fi
  done <<CTRL
$CONTROL_HOOKS
CTRL
done <<CHANGED
$CHANGED_FILES
CHANGED

[ -z "$TOUCHED" ] && exit 0

printf 'ADVISORY: this PR touches trust-chain CONTROL hook(s) [%s] — ensure each has/updates a paired adversarial test (a test that actively tries to defeat the control, not just exercise the happy path). See AgDR-0104 / AgDR-0117 (docs/agdr/). Non-blocking — this is a reminder, not a gate.\n' \
  "$(printf '%s' "$TOUCHED" | sed 's/ $//; s/ /, /g')" >&2

exit 0
