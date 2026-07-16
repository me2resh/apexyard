#!/usr/bin/env bash
# Publishes per-harness conformance status badges + green-streak counters
# to the orphan `conformance-badge` branch, as shields.io "endpoint" JSON
# (https://shields.io/badges/endpoint-badge) — no extra PAT, no external
# badge service account, just GITHUB_TOKEN's contents:write on this repo.
#
# WHY AN ORPHAN BRANCH, NOT gh-pages OR A GIST
# ----------------------------------------------
# - No extra secret to provision: the default GITHUB_TOKEN already has
#   contents:write on this repo when the job grants it (see
#   .github/workflows/conformance.yml's `badge:` job permissions). A gist
#   or a separate badge-hosting repo would need a second PAT with broader
#   scope than this workflow otherwise needs — more secret surface for a
#   cosmetic feature.
# - An orphan branch (no shared history with dev/main) keeps the badge
#   JSON's commit churn (one commit per scheduled run, daily) out of the
#   framework's real history — it never shows up in `git log dev`.
# - shields.io's endpoint badge format reads a raw JSON URL directly:
#     https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/<owner>/<repo>/conformance-badge/<harness>.json
#   No badge-hosting service account, no webhook, no API to poll —
#   shields.io fetches the raw file itself on every badge render, so the
#   badge is always "live-pulled" per the AC without this script needing
#   to push anywhere except git.
#
# WHAT THIS SCRIPT DOES
# ----------------------
# 1. Queries the GitHub Actions API for this run's matrix job conclusions
#    (one job per harness: opencode / pi / codex).
# 2. For each harness: updates a green_streak counter — increments on a
#    'success' conclusion, RESETS TO 0 on anything else (failure,
#    cancelled, skipped — a flake resets the counter, per the AC's
#    "green-continuous" definition; see docs/conformance-ci.md).
# 3. Writes <harness>.json (shields.io endpoint schema) + a streak state
#    file per harness to the conformance-badge branch and commits them.
# 4. Cursor is NOT computed here — it has no matrix job. Its badge is a
#    static, hand-authored grey "manual" endpoint, checked in once and
#    left alone by this script (see the Cursor block below), satisfying
#    the AC's "Cursor shows as documented-manual, never proven".
#
# GREEN-CONTINUOUS THRESHOLD: 3 (see docs/conformance-ci.md). Exposed as
# GREEN_CONTINUOUS_THRESHOLD so the badge label can flip to "proven" only
# once a harness's streak reaches it — the badge script computes and
# displays the number; the harness-agnostic doc/headline flip itself
# remains a deliberate, separate human decision (same posture as the
# rebrand trigger in docs/harnesses/README.md).
#
# DISPATCH-PATH STREAK GUARD (me2resh/apexyard#880): streak counters only
# ever advance (or reset) on a `github.event_name == 'schedule'` run, passed
# in as EVENT_NAME. A `workflow_dispatch` — whether it drives all three
# harnesses or, via the `harness` input, just one — is a no-op for every
# harness's streak file and badge JSON. This closes a streak-inflation bug:
# a single-harness dispatch leaves the other two matrix jobs reporting a
# trivial `success` conclusion (conformance.yml's "Skip non-selected
# harness" step sets SELECTED=false and exits 0 without running a real
# gated turn), and without this guard the publisher counted that clean skip
# toward "(proven)" as if a real scheduled turn had run. See
# docs/conformance-ci.md § "The green-continuous rule".

set -euo pipefail

GREEN_CONTINUOUS_THRESHOLD=3
BADGE_BRANCH="conformance-badge"
HARNESSES=(opencode pi codex)

: "${GH_TOKEN:?GH_TOKEN must be set}"
: "${RUN_ID:?RUN_ID must be set}"
: "${REPO:?REPO must be set}"
: "${EVENT_NAME:?EVENT_NAME must be set (pass github.event_name)}"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# ---------------------------------------------------------------------------
# 1. Fetch this run's per-matrix-job conclusions.
# ---------------------------------------------------------------------------
jobs_json="$(gh api "repos/$REPO/actions/runs/$RUN_ID/jobs" --paginate 2>/dev/null || echo '{"jobs":[]}')"

conclusion_for() {
  local harness="$1"
  # Matrix job names render as "conformance / <matrix.harness>" per the
  # `name:` field in conformance.yml's `conform` job.
  printf '%s' "$jobs_json" | jq -r --arg name "conformance / $harness" '
    [.jobs[] | select(.name == $name)] | .[0].conclusion // "unknown"
  '
}

# ---------------------------------------------------------------------------
# 2. Clone (or create) the orphan conformance-badge branch into a scratch
#    worktree, so this doesn't disturb the caller's checkout of dev/main.
# ---------------------------------------------------------------------------
git clone --quiet "https://x-access-token:${GH_TOKEN}@github.com/${REPO}.git" "$WORKDIR/badge-repo"
cd "$WORKDIR/badge-repo" || exit 1

if git ls-remote --exit-code --heads origin "$BADGE_BRANCH" >/dev/null 2>&1; then
  git checkout --quiet "$BADGE_BRANCH"
else
  git checkout --quiet --orphan "$BADGE_BRANCH"
  git rm -rf --quiet . >/dev/null 2>&1 || true
fi

git config user.email "conformance-ci@apexyard.bot"
git config user.name "apexyard-conformance-ci"

CHANGED=0

if [ "$EVENT_NAME" = "schedule" ]; then
  for harness in "${HARNESSES[@]}"; do
    conclusion="$(conclusion_for "$harness")"

    streak_file="streak-${harness}.txt"
    prev_streak=0
    [ -f "$streak_file" ] && prev_streak="$(cat "$streak_file" 2>/dev/null || echo 0)"
    case "$prev_streak" in ''|*[!0-9]*) prev_streak=0 ;; esac

    if [ "$conclusion" = "success" ]; then
      new_streak=$((prev_streak + 1))
      color="brightgreen"
      message="green"
    else
      new_streak=0
      color="red"
      message="red (${conclusion})"
    fi

    if [ "$new_streak" -ge "$GREEN_CONTINUOUS_THRESHOLD" ]; then
      message="green x${new_streak} (proven)"
    fi

    # shields.io endpoint badge schema: https://shields.io/badges/endpoint-badge
    cat > "${harness}.json" <<JSON
{
  "schemaVersion": 1,
  "label": "conformance: ${harness}",
  "message": "${message}",
  "color": "${color}"
}
JSON
    printf '%s' "$new_streak" > "$streak_file"

    echo "${harness}: conclusion=${conclusion} streak=${prev_streak}->${new_streak}"
    git add "${harness}.json" "$streak_file"
    CHANGED=1
  done
else
  # Dispatch-path streak guard (me2resh/apexyard#880) — see file header.
  # Deliberately skip every harness's streak file and badge JSON: neither a
  # dispatched harness's real result nor a non-dispatched harness's trivial
  # skip-success is a scheduled run, and "(proven)" is defined as N
  # consecutive *scheduled* green runs, not N consecutive green runs of any
  # origin.
  for harness in "${HARNESSES[@]}"; do
    echo "${harness}: conclusion=$(conclusion_for "$harness") (EVENT_NAME='${EVENT_NAME}', not 'schedule' — streak/badge left untouched)"
  done
fi

# ---------------------------------------------------------------------------
# 3. Cursor's badge is static and hand-authored, not computed — it has no
#    matrix job (see workflow header + docs/conformance-ci.md). Seed it
#    once if absent; never overwrite an operator's edit to it afterward.
# ---------------------------------------------------------------------------
if [ ! -f "cursor.json" ]; then
  cat > cursor.json <<'JSON'
{
  "schemaVersion": 1,
  "label": "conformance: cursor",
  "message": "documented-manual (not proven)",
  "color": "lightgrey"
}
JSON
  git add cursor.json
  CHANGED=1
fi

if [ "$CHANGED" -eq 1 ] && ! git diff --cached --quiet; then
  git commit --quiet -m "chore: conformance badge update (run ${RUN_ID})"
  git push --quiet origin "$BADGE_BRANCH"
  echo "Published badge JSON to the ${BADGE_BRANCH} branch."
else
  echo "No badge changes to publish."
fi
