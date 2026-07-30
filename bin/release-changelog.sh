#!/usr/bin/env bash
# bin/release-changelog.sh — Generate a CHANGELOG section from git log between two refs.
#
# Used by the /release skill (AgDR-0076) to automate the changelog-generation
# step. Emits markdown to stdout; never writes files (callers decide where to put it).
#
# Environment variables (all required):
#   PREV_TAG   — the previous release tag (e.g. v3.2.0); used as the start of
#                git log range. Pass "NONE" if there is no previous tag.
#   HEAD_REF   — the end of the git log range (e.g. upstream/dev or a branch name)
#   VERSION    — the new version string (e.g. v3.3.0)
#   DATE       — the release date in YYYY-MM-DD format
#
# Optional:
#   REPO_REMOTE    — the git remote whose repo this release is being cut for
#                    (default: upstream). Used for two things: as the base of
#                    the git log range (see below), and — since #1077 — as the
#                    source PR_LOOKUP_REPO derives from. Set this to whichever
#                    remote your OWN fork's dev/main actually lives on (e.g.
#                    "origin") when cutting an independent release from an
#                    adopter fork — see PR_LOOKUP_REPO below.
#   PR_LOOKUP_REPO — owner/repo used to resolve an UNSCOPED commit's trailing
#                    PR number back to the issue it actually closes. Only
#                    consulted for commits with no `type(#N):` scope (#1056)
#                    — see "Closes resolution" below. Best-effort: a `gh`
#                    failure of any kind (missing binary, auth, rate limit,
#                    or an unreachable forge) always falls back to today's
#                    behaviour and never aborts.
#
#                    Default (#1077): derived from REPO_REMOTE's own git
#                    remote URL, NOT hardcoded — apexyard is built to be
#                    forked, and every fork's own PR numbers must be resolved
#                    against ITS OWN repo, not upstream's (a fork resolving
#                    its own PR #12 against me2resh/apexyard's PR #12 would
#                    emit whatever unrelated issue upstream's #12 happens to
#                    close). If REPO_REMOTE can't be resolved to an owner/repo
#                    shape at all (no such remote, or an unparseable URL),
#                    PR_LOOKUP_REPO is left EMPTY and the lookup is skipped
#                    entirely — "prefer a missing close over a wrong close":
#                    a missing close is an annoyance fixed by hand; a wrong
#                    close silently reaches into an unrelated issue. Set this
#                    explicitly to override derivation (still supported).
#
#                    PR_LOOKUP_TIMEOUT — seconds to bound each `gh pr view`
#                    call (default: 10). Prefers GNU `timeout`, falls back to
#                    macOS `gtimeout`, degrades to unbounded if neither exists
#                    (#1078) — an unresponsive forge must never stall a
#                    release cut indefinitely; a release cut walks this path
#                    once per unscoped commit in range.
#
# Output format (matches the existing CHANGELOG.md convention):
#
#   ## [VERSION] — DATE
#
#   <release description line> (omitted if empty)
#
#   ### Added (feat)
#   - (#NN) <subject> — <short-sha>
#   ...
#   ### Fixed (fix)
#   - (#NN) <subject> — <short-sha>
#   ...
#   ### Changed (refactor / chore / docs / style / perf / build / ci / test)
#   - (#NN) <subject> — <short-sha>
#   ...
#   ### Breaking
#   - <subject> — <short-sha>
#   ...
#   ### Closes
#   - Closes #N
#   - Closes #M
#   ...
#
# Closes resolution (#1056):
#   GitHub's `Closes` keyword only auto-closes the reference IMMEDIATELY
#   FOLLOWING it — a single "Closes #A, #B, #C" line only ever closes #A, so
#   the section above emits one "- Closes #N" bullet per reference instead.
#
#   Which number goes in that bullet depends on whether the commit subject
#   carries a conventional-commit SCOPE: `fix(#1042): ...` — by apexyard
#   convention the scope IS the issue number, used directly. A subject with
#   no scope, e.g. `docs: ... (#1045)`, only has GitHub's squash-appended
#   trailing PR number — that is NOT an issue, so it is resolved via a
#   best-effort `gh pr view` lookup of the PR's own body for a closing-keyword
#   reference (Closes/Fixes/Resolves/Refs #N), falling back to the PR number
#   itself if nothing resolves or the forge can't be reached.
#
# Exit codes:
#   0 — success (even if the commit list is empty; that is a valid patch release)
#   1 — missing required env var or git command failure

set -euo pipefail

# ── Validate required env vars ──────────────────────────────────────────────

for var in PREV_TAG HEAD_REF VERSION DATE; do
  if [ -z "${!var:-}" ]; then
    echo "ERROR: $var is required but not set." >&2
    echo "Usage: PREV_TAG=v3.2.0 HEAD_REF=upstream/dev VERSION=v3.3.0 DATE=2026-06-21 bash bin/release-changelog.sh" >&2
    exit 1
  fi
done

REPO_REMOTE="${REPO_REMOTE:-upstream}"

# ── Build the git log range ──────────────────────────────────────────────────

if [ "$PREV_TAG" = "NONE" ]; then
  LOG_RANGE="${HEAD_REF}"
else
  # AgDR-0094 (#872): prefer the RECORDED cut point over inferring one. Since
  # the fix landed, `/release` writes a `Released-From: <dev-sha>` trailer into
  # the release squash commit — that sha IS the exact dev tip the release was
  # cut from, so TRAILER..HEAD_REF is deterministic and immune to both the
  # #737 over-count and the #872 late-sync under-count (a late `/release-sync`
  # merge can no longer mis-anchor the boundary, because we're not inferring
  # it from sync-commit position anymore). Only look at PREV_TAG's own commit
  # message — that's the squash commit the trailer was written into.
  TRAILER_SHA=$(git log -1 --pretty=format:'%(trailers:key=Released-From,valueonly,separator=%x0A)' "$PREV_TAG" 2>/dev/null \
                  | tail -n 1 | tr -d '[:space:]' || true)

  if [ -n "$TRAILER_SHA" ] && git cat-file -e "${TRAILER_SHA}^{commit}" 2>/dev/null; then
    LOG_RANGE="${TRAILER_SHA}..${HEAD_REF}"
  else
    # No trailer (pre-AgDR-0094 release, or a mangled/unknown sha) — fall back
    # to the #737 sync-boundary heuristic below, unchanged.
    #
    # #737: PREV_TAG is a *squash* commit on main. Under the release-cut model
    # the individual commits it squashed live on HEAD_REF (dev) but are NOT
    # ancestors of the tag — so a naive PREV_TAG..HEAD_REF range (and even
    # merge-base(PREV_TAG,dev)..dev) surfaces EVERY already-released commit,
    # massively over-counting (v4.1.0 reported 102 feats / 263 commits for a
    # ~1-feature delta). The correct start is the POST-SYNC BOUNDARY: after each
    # release, `/release-sync` lands a "sync: merge main into dev after <ver>"
    # commit (and its "...sync/main-to-dev-after-<ver>" PR merge) on dev. Commits
    # AFTER the most recent such marker are exactly the unreleased delta.
    # Patterns are VERSION-ANCHORED so they only match real sync commits, never a
    # prose mention of the convention in some other commit body (e.g. this very
    # fix's commit, or a doc PR) — an unanchored 'sync/main-to-dev-after' would
    # let a later commit hijack the boundary and DROP unreleased work (#749 review).
    #
    # KNOWN LIMITATION this heuristic cannot fix (why AgDR-0094 exists): if the
    # matching `/release-sync` merges LATE — landing near dev's tip, after many
    # newer commits — this still anchors on that late marker and silently drops
    # everything merged before it (#872). The trailer above is the real fix;
    # this stays as the fallback for releases cut before it existed.
    SYNC=$(git log "$HEAD_REF" --max-count=1 --pretty=format:'%H' \
             --grep='^sync: merge main into dev after v[0-9]' \
             --grep='sync/main-to-dev-after-v[0-9]' 2>/dev/null || true)
    if [ -n "$SYNC" ]; then
      LOG_RANGE="${SYNC}..${HEAD_REF}"
    else
      # No sync boundary on dev (first release under the model, or sync skipped):
      # best available fallback is the merge-base, then the raw tag range.
      BASE=$(git merge-base "$PREV_TAG" "$HEAD_REF" 2>/dev/null || true)
      LOG_RANGE="${BASE:-$PREV_TAG}..${HEAD_REF}"
    fi
  fi
fi

# ── Expose the resolved range to the caller (#1002) ──────────────────────────
# The /release skill's count-mismatch guard used to compare the changelog's
# entry count against `git rev-list --count upstream/main..upstream/dev` —
# structurally wrong under the release-cut squash model, where main..dev never
# shrinks (see #1002). The guard should compare against the SAME range this
# script actually generated the changelog from. Printed to stderr (not
# stdout) so it never pollutes the changelog markdown callers capture.
echo "RELEASE_CHANGELOG_RANGE=${LOG_RANGE}" >&2

# ── Extract commits ──────────────────────────────────────────────────────────
# Format: <short-sha> <subject>
# We use %h (abbreviated sha) and %s (subject) so merge commits are included.

COMMITS=$(git log "$LOG_RANGE" --pretty=format:'%h %s' 2>/dev/null || true)

# ── Classify commits ─────────────────────────────────────────────────────────

added_lines=()
fixed_lines=()
changed_lines=()
breaking_lines=()
closes_nums=()

# Extract PR number from subject: "Merge pull request #NN from ..." or "(#NN)" in subject
extract_pr_num() {
  local subject="$1"
  # Merge commit format: "Merge pull request #NNN from ..."
  if echo "$subject" | grep -qE 'Merge pull request #[0-9]+'; then
    echo "$subject" | grep -oE '#[0-9]+' | head -1
    return
  fi
  # Conventional commit with PR ref: "feat(#NNN): ..." or "feat: something (#NNN)"
  if echo "$subject" | grep -qE '\(#[0-9]+\)'; then
    echo "$subject" | grep -oE '#[0-9]+' | head -1
    return
  fi
  echo ""
}

# Does the subject carry a conventional-commit SCOPE holding the issue
# number, i.e. "type(#N): ..." (optionally with a breaking "!") right at the
# start? By apexyard convention (git-conventions.md) that scope IS the issue
# number — nothing to resolve. Anything else — no scope at all, or only a
# trailing "(#N)" GitHub appends on squash-merge — is a PR number, not an
# issue (#1056).
has_scope_issue() {
  local subject="$1"
  echo "$subject" | grep -qE '^[a-z]+\(#[0-9]+\)!?:'
}

# Best-effort: resolve a trailing PR number back to the ISSUE it actually
# closes/references, by reading the PR's own body for a closing-keyword
# reference (#1056). Every failure path — no `gh` on PATH, auth failure, rate
# limit, an unresolvable/underivable target repo (#1077), a hung request
# (#1078), or (the exact live failure that motivated this) a DNS blip on
# api.github.com — degrades to printing nothing, so the caller falls back to
# the PR number itself. A release cut must never abort because the forge
# was briefly unreachable, or hang because it never answered at all. Always
# returns 0 so `set -e` can never trip on it.

# Derive PR_LOOKUP_REPO from the ACTUAL remote this release is being cut for
# (#1077), rather than hardcoding it. See the file header for the full
# rationale. An explicit PR_LOOKUP_REPO (env var already set by the caller)
# always wins over derivation.
_derive_pr_lookup_repo() {
  local url
  url=$(git remote get-url "$REPO_REMOTE" 2>/dev/null) || return 0
  echo "$url" | sed -nE 's|.*[:/]([^/:]+/[^/]+)\.git$|\1|p; s|.*[:/]([^/:]+/[^/]+)$|\1|p' | head -1
}

if [ -z "${PR_LOOKUP_REPO:-}" ]; then
  PR_LOOKUP_REPO=$(_derive_pr_lookup_repo)
fi

resolve_issue_from_pr() {
  local pr_num="$1"  # numeric, no leading '#'
  local body ref to

  if ! command -v gh >/dev/null 2>&1; then
    echo ""
    return 0
  fi

  # #1077 — no confidently-derived repo means no query at all. Guessing a
  # repo here (e.g. falling back to a hardcoded default) is exactly the
  # defect this fixes; degrade like every other failure mode below instead.
  if [ -z "$PR_LOOKUP_REPO" ]; then
    echo ""
    return 0
  fi

  # #1078 — bound the call so an unresponsive forge can't stall a release
  # cut indefinitely. Prefers GNU `timeout`, then macOS `gtimeout`; degrades
  # to unbounded (today's pre-#1078 behaviour) if neither is on PATH — same
  # posture as every other best-effort fallback in this function.
  to=""
  if command -v timeout >/dev/null 2>&1; then
    to="timeout -k 2 ${PR_LOOKUP_TIMEOUT:-10}"
  elif command -v gtimeout >/dev/null 2>&1; then
    to="gtimeout -k 2 ${PR_LOOKUP_TIMEOUT:-10}"
  fi

  if ! body=$($to gh pr view "$pr_num" --repo "$PR_LOOKUP_REPO" --json body -q .body 2>/dev/null); then
    echo ""
    return 0
  fi

  ref=$(echo "$body" | grep -oiE '(Closes|Fixes|Resolves|Refs) #[0-9]+' | head -1 | grep -oE '#[0-9]+' || true)
  echo "$ref"
  return 0
}

# Strip conventional-commit prefix from a subject for cleaner display
strip_cc_prefix() {
  local subject="$1"
  # Remove "type(scope): " or "type: " prefix
  echo "$subject" | sed -E 's/^[a-z]+(\([^)]*\))?!?: //'
}

while IFS= read -r line; do
  [ -z "$line" ] && continue

  short_sha="${line%% *}"
  subject="${line#* }"

  # Skip merge commits for "Merge branch" (sync commits) — only keep "Merge pull request"
  if echo "$subject" | grep -qE '^Merge branch '; then
    continue
  fi

  # Skip release commits themselves
  if echo "$subject" | grep -qE '^release(\([^)]*\))?!?:'; then
    continue
  fi

  # Skip sync commits
  if echo "$subject" | grep -qE '^sync(\([^)]*\))?!?:'; then
    continue
  fi

  pr_num=$(extract_pr_num "$subject")
  display_subject=$(strip_cc_prefix "$subject")

  # Remove trailing PR reference like "(#NNN)" from end of display subject
  display_subject=$(echo "$display_subject" | sed -E 's/ \(#[0-9]+\)$//')

  # Build the display line
  if [ -n "$pr_num" ]; then
    entry="- ($pr_num) $display_subject — $short_sha"
    num_only="${pr_num#\#}"

    # #1056 — the DISPLAY line always shows $pr_num as extracted above (a
    # scoped commit's issue number, or an unscoped commit's trailing PR
    # number) unchanged. The Closes section is different: an unscoped
    # commit's only "(#N)" is a PR number, not an issue, and must be resolved
    # back to the issue that PR actually references before it goes in Closes
    # — otherwise the release closes a PR (a no-op) and leaves the real issue
    # open, which is exactly the defect this fixes.
    if has_scope_issue "$subject"; then
      closes_num="$num_only"
    else
      resolved=$(resolve_issue_from_pr "$num_only")
      if [ -n "$resolved" ]; then
        closes_num="${resolved#\#}"
      else
        closes_num="$num_only"
      fi
    fi
    closes_nums+=("$closes_num")
  else
    entry="- $display_subject — $short_sha"
  fi

  # Classify by conventional-commit type
  if echo "$subject" | grep -qE '^[a-z]+(\([^)]*\))?!:'; then
    # Breaking change (any type with !)
    breaking_lines+=("$entry")
  elif echo "$subject" | grep -qE '^feat(\([^)]*\))?:'; then
    added_lines+=("$entry")
  elif echo "$subject" | grep -qE '^fix(\([^)]*\))?:'; then
    fixed_lines+=("$entry")
  elif echo "$subject" | grep -qE '^(refactor|chore|docs|style|perf|build|ci|test)(\([^)]*\))?:'; then
    changed_lines+=("$entry")
  elif echo "$subject" | grep -qE '^Merge pull request'; then
    # Merge commits for PRs are captured above via pr_num extraction;
    # the commit itself shows up under the type of the PR's own commit.
    # Skip duplicate merge-commit entries.
    continue
  else
    # Unknown type — put in Changed
    changed_lines+=("$entry")
  fi

done <<< "$COMMITS"

# ── Infer release description ─────────────────────────────────────────────────

if [ "${#breaking_lines[@]}" -gt 0 ]; then
  bump_type="Major release"
elif [ "${#added_lines[@]}" -gt 0 ]; then
  bump_type="Minor release"
else
  bump_type="Patch release"
fi

feat_count="${#added_lines[@]}"
fix_count="${#fixed_lines[@]}"
desc_parts=()
[ "$feat_count" -gt 0 ] && desc_parts+=("${feat_count} feature$([ "$feat_count" -gt 1 ] && echo 's' || echo '')")
[ "$fix_count" -gt 0 ] && desc_parts+=("${fix_count} fix$([ "$fix_count" -gt 1 ] && echo 'es' || echo '')")
[ "${#changed_lines[@]}" -gt 0 ] && desc_parts+=("${#changed_lines[@]} improvement$([ "${#changed_lines[@]}" -gt 1 ] && echo 's' || echo '')")

if [ "${#desc_parts[@]}" -gt 0 ]; then
  # NB: `${arr[*]}` only joins on the FIRST character of IFS, even when IFS is
  # set to a multi-char string like ', ' — that dropped the space and produced
  # "2 features,13 fixes,14 improvements." on the v5.2.0 cut (#1002). Join
  # explicitly instead of relying on IFS-based array expansion.
  joined=""
  for part in "${desc_parts[@]}"; do
    if [ -z "$joined" ]; then
      joined="$part"
    else
      joined="$joined, $part"
    fi
  done
  release_desc="$bump_type — ${joined}."
else
  release_desc="$bump_type."
fi

# ── Emit the CHANGELOG section ───────────────────────────────────────────────

echo "## [$VERSION] — $DATE"
echo ""
echo "$release_desc"

if [ "${#added_lines[@]}" -gt 0 ]; then
  echo ""
  echo "### Added (feat)"
  echo ""
  for l in "${added_lines[@]}"; do echo "$l"; done
fi

if [ "${#fixed_lines[@]}" -gt 0 ]; then
  echo ""
  echo "### Fixed (fix)"
  echo ""
  for l in "${fixed_lines[@]}"; do echo "$l"; done
fi

if [ "${#changed_lines[@]}" -gt 0 ]; then
  echo ""
  echo "### Changed (refactor / chore / docs)"
  echo ""
  for l in "${changed_lines[@]}"; do echo "$l"; done
fi

if [ "${#breaking_lines[@]}" -gt 0 ]; then
  echo ""
  echo "### Breaking"
  echo ""
  for l in "${breaking_lines[@]}"; do echo "$l"; done
fi

if [ "${#closes_nums[@]}" -gt 0 ]; then
  echo ""
  echo "### Closes"
  echo ""
  # #1056 — one "- Closes #N" bullet per reference, deduplicated and sorted.
  # GitHub only honours the reference IMMEDIATELY FOLLOWING a closing
  # keyword, so the old single "Closes #A, #B, #C" line auto-closed at most
  # #A — every reference after the first was silently inert. Repeating the
  # keyword (one bullet each) makes every reference its own closing directive.
  unique_nums=$(printf '%s\n' "${closes_nums[@]}" | sort -un)
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    echo "- Closes #${n}"
  done <<< "$unique_nums"
fi
