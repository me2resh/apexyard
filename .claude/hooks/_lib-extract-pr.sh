#!/bin/bash
# Shared PR-number and repo extraction for the merge-gate hooks:
#   - block-unreviewed-merge.sh
#   - require-design-review-for-ui.sh
#   - require-architecture-review.sh
#   - block-merge-on-red-ci.sh
#
# Not a hook itself (prefixed with `_lib-` so it's never wired as one). Sourced
# by the hooks above via `. "$(dirname "$0")/_lib-extract-pr.sh"`.
#
# WHY THIS EXISTS
# ---------------
# The merge gates originally only matched `gh pr merge <N>`. Incident (#47):
# merges via `gh api repos/<owner>/<repo>/pulls/<N>/merge -X PUT` silently
# bypassed all three gates because neither the matcher nor the PR-number
# extraction knew about the API shape. This helper gives every gate a single,
# tested way to recognise both shapes:
#
#   1. `gh pr merge 42 --squash`                                  → PR is 42
#   2. `gh api repos/owner/repo/pulls/42/merge -X PUT`            → PR is 42
#
# Any tool that edits one of the three merge hooks MUST keep calling this
# helper, not re-implement the parsing inline. That's the whole point.
#
# USAGE
# -----
#   . "$(dirname "$0")/_lib-extract-pr.sh"
#   if ! is_merge_command "$COMMAND"; then exit 0; fi
#   PR_NUMBER=$(extract_pr_number "$COMMAND")
#
# FORGE-AWARENESS (#764)
# ----------------------
# The gates originally spoke only GitHub. A GitLab-forge project (`tracker.kind:
# glab`) merges via `glab mr merge <iid>` — a shape neither the matcher nor this
# helper recognised, so the gates silently did not fire (an ungated-merge hole,
# the forge analog of the #47 `gh api` bypass). This helper now recognises both
# forges' merge shapes and resolves MR/PR state via the matching CLI:
#
#   3. `glab mr merge 42 -R owner/repo`                           → MR is 42
#   4. `glab api projects/owner%2Frepo/merge_requests/42/merge`   → MR is 42
#
# Shape 4 (#767) is the GitLab raw-API merge — the exact forge analog of the #47
# `gh api …/pulls/<N>/merge` bypass. Gating only `glab mr merge` (shape 3) while
# leaving the API passthrough open would re-create #47 on GitLab, so both glab
# shapes are recognised (matched with `Bash(glab api *)` in settings.json, the
# same way the gh CLI shape is paired with `Bash(gh api *)`).
#
# The gh path is unchanged byte-for-byte; glab is additive. Forge selection for
# the CLI-calling resolvers goes through `tracker_kind` from `_lib-tracker.sh`
# (gh + glab coincide with github + gitlab per #762); the shape detectors read
# the command text directly.
#
# CI-STATUS RESOLUTION (#790)
# ----------------------------
# #767 made block-unreviewed-merge.sh forge-aware but left its sibling
# block-merge-on-red-ci.sh hardcoded to `gh pr checks` — the last
# non-forge-aware merge gate. `resolve_ci_status_glab` closes that gap: it
# resolves a GitLab MR's head-pipeline status via `glab mr view --output
# json`, normalised to success | pending | failure | none | "" (unresolvable).
# block-merge-on-red-ci.sh calls it only on the glab path; the gh path keeps
# calling `gh pr checks` directly and is untouched.
#
# THE tracker_pr_merge WRAPPER SHAPE (#759, HIGH finding from Hakim's review
# of the #759 PR)
# ------------------------------------------------------------------------
# #759 gave `/approve-merge` a tracker-agnostic merge function —
# `tracker_pr_merge <owner/repo> <pr> <strategy> [<delete_branch>]` in
# _lib-tracker.sh — so the skill calls ONE function instead of shelling out to
# a literal `gh pr merge` / `glab mr merge`. But these gate hooks match the
# OUTER Bash command text (`.tool_input.command`, the exact string the Bash
# tool receives), not the subprocess a SOURCED SHELL FUNCTION happens to
# invoke internally. `/approve-merge`'s actual Bash call looks like:
#
#   . ".../_lib-tracker.sh"
#   MERGE_RESULT=$(tracker_pr_merge "owner/repo" "42" "squash" true)
#
# — and the literal substrings "gh pr merge" / "gh api" / "glab mr merge" /
# "glab api" never appear in that text (they're inside `_lib-tracker.sh`,
# already-sourced source code, not this command's text). Without a dedicated
# branch, `is_merge_command` returns false, the four merge-gate hooks never
# fire, and the wrapper form sails through completely ungated — the exact #47
# / #767 bypass shape, one level up the call stack (the settings.json `"if":
# "Bash(tracker_pr_merge *)"` matcher entries added alongside this fix are
# what make Claude Code's harness invoke the hook scripts at all for this
# shape; is_merge_command is the SECOND layer that decides whether the hook,
# once invoked, treats the command as a merge).
#
#   5. `tracker_pr_merge "owner/repo" "42" "squash" true`         → PR is 42
#
# The wrapper's positional args are `<owner/repo>` (arg 1) and `<pr>` (arg 2)
# — not a `--repo`/`-R` flag and not a URL path — so `extract_pr_number` and
# `extract_repo_from_command` each gained a dedicated wrapper-arg extraction
# step using `_extract_wrapper_arg` (quoted-or-bare positional-token parsing,
# regex/parameter-expansion only — no `eval` of the command text, ever).

# Lazily source the tracker lib so `tracker_kind` is available for forge
# resolution. Guarded: only source if not already defined and the lib is
# present. tracker_kind defaults to "gh" with no config, preserving gh behaviour.
if ! command -v tracker_kind >/dev/null 2>&1; then
  _lib_extract_pr_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)"
  if [ -n "$_lib_extract_pr_dir" ] && [ -f "$_lib_extract_pr_dir/_lib-tracker.sh" ]; then
    # shellcheck source=/dev/null
    . "$_lib_extract_pr_dir/_lib-tracker.sh"
  fi
fi

# Echoes the forge kind ('gh' | 'glab') for a repo, via tracker_kind. Any
# non-glab kind (gh / none / jira / linear / unknown / unresolved) → 'gh', so
# the GitHub CLI path stays the default. Used by the CLI-calling resolvers
# (resolve_pr_head, resolve_pr_head_branch) which only have the repo, not the
# command text.
_forge_kind_for() {
  local repo="${1:-}" kind="gh"
  if command -v tracker_kind >/dev/null 2>&1; then
    kind=$(tracker_kind "$repo" 2>/dev/null || echo gh)
  fi
  case "$kind" in glab) echo glab ;; *) echo gh ;; esac
}

# Echoes 'glab' if the command text is a GitLab (glab) invocation, else 'gh'.
# Shape-based — used where the command string is in hand (the extractors), so
# no config lookup is needed: the command literally says which CLI it drives.
_forge_from_command() {
  if echo "${1:-}" | grep -qE '\bglab\s+(mr|api)\b'; then echo glab; else echo gh; fi
}

# Echoes the Nth (1-indexed) whitespace-separated positional argument from
# $1, treating a double-quoted or single-quoted span as ONE argument (so
# `"owner/repo"` extracts as `owner/repo`, not split on the slash). Bare
# (unquoted) tokens are split on whitespace as usual.
#
# Pure bash parameter expansion — NO eval, NO external process, NO regex
# backtracking on attacker-controlled text. This is the tokenizer for the
# `tracker_pr_merge <owner/repo> <pr> <strategy> [<delete_branch>]` wrapper
# shape (#759): a best-effort, regex-adjacent positional extractor, not a
# full shell parser — it doesn't handle nested/escaped quotes, matching the
# existing extract_pr_number/extract_repo_from_command discipline of "regex-
# only extraction, sufficient for the shapes these skills actually emit."
_extract_wrapper_arg() {
  local text="$1" n="${2:-1}" i=0 tok
  while [ -n "$text" ]; do
    # Trim leading whitespace.
    while [ -n "$text" ]; do
      case "$text" in
        [[:space:]]*) text="${text#?}" ;;
        *) break ;;
      esac
    done
    [ -z "$text" ] && break
    case "$text" in
      \"*)
        tok="${text#\"}"
        tok="${tok%%\"*}"
        text="${text#\"$tok\"}"
        ;;
      \'*)
        tok="${text#\'}"
        tok="${tok%%\'*}"
        text="${text#\'$tok\'}"
        ;;
      *)
        tok="${text%%[[:space:]]*}"
        text="${text#"$tok"}"
        ;;
    esac
    i=$((i + 1))
    if [ "$i" -eq "$n" ]; then
      echo "$tok"
      return 0
    fi
  done
  echo ""
}

# Returns 0 if $1 looks like a merge command this gate should fire on.
# Matches ANY of:
#   - `gh pr merge ...`
#   - `gh api ... repos/<owner>/<repo>/pulls/<N>/merge ...`
#   - `glab mr merge ...`                                     (#764, GitLab)
#   - `glab api ... merge_requests/<N>/merge ...`             (#767, GitLab raw-API)
#   - `tracker_pr_merge <owner/repo> <pr> ...`                (#759, wrapper)
is_merge_command() {
  local cmd="$1"
  if echo "$cmd" | grep -qE '\bgh\s+pr\s+merge\b'; then
    return 0
  fi
  # `gh api` with a `/pulls/<N>/merge` path anywhere in the command. The path
  # may be quoted, slash-separated, and may include query params.
  if echo "$cmd" | grep -qE '\bgh\s+api\b.*repos/[^/[:space:]]+/[^/[:space:]]+/pulls/[0-9]+/merge\b'; then
    return 0
  fi
  # `glab mr merge ...` — GitLab merge-request merge (#764).
  if echo "$cmd" | grep -qE '\bglab\s+mr\s+merge\b'; then
    return 0
  fi
  # `glab api` with a `/merge_requests/<N>/merge` path — GitLab's raw-API merge
  # passthrough (#767, the forge analog of the #47 `gh api …/pulls/<N>/merge`
  # bypass). The project is a URL-encoded path (`projects/<owner>%2F<repo>`); the
  # MR iid + `/merge` action is what we match. The trailing `\b` is load-bearing:
  # it stops `/merge_ref`, `/merge_requests/<N>` (GET), and `/notes` from
  # false-matching — a false match here would be fail-CLOSED (block), but a
  # false NEGATIVE is fail-open, so the anchor is verified by negative tests.
  if echo "$cmd" | grep -qE '\bglab\s+api\b.*merge_requests/[0-9]+/merge\b'; then
    return 0
  fi
  # `tracker_pr_merge <owner/repo> <pr> <strategy> [<delete_branch>]` — the
  # #759 tracker-agnostic merge wrapper /approve-merge calls instead of
  # shelling out to `gh pr merge`/`glab mr merge` directly. Without this
  # branch the gates never fire on the wrapper form at all — see the HIGH
  # finding writeup in the file header (#759).
  if echo "$cmd" | grep -qE '\btracker_pr_merge\b'; then
    return 0
  fi
  return 1
}

# Echoes the PR number extracted from the command, or empty if none found.
# Tries (in order):
#   1. `gh api .../pulls/<N>/merge` URL path
#   2. `gh pr merge <N>` first numeric arg (strict: must be a bare integer token
#      immediately following `merge`; NOT a digit scraped from a redirection such
#      as `2>&1`, and NOT an unexpanded shell variable such as `$pr` or `$PR`).
#      When the token is a shell variable the function returns empty so the
#      caller's step-3 fallback can invoke `gh pr view`.
#   3. falls back to `gh pr view --json number` (current branch's PR)
#
# BUG #568 — root cause and fix:
#   The old step-2 span `[^|;&]*` included `2>&1` because the `&` lookahead
#   was not anchored before the pipe, causing `grep -oE '[0-9]+'` to return `2`
#   (the stderr fd number) instead of the PR number when the invocation was
#   `gh pr merge $pr --squash 2>&1 | tail -5` and `$pr` was unexpanded at hook
#   evaluation time.
#
#   Fix: strip redirection tokens from the span before the digit search, then
#   require that the first post-`merge` token is a bare integer — not a shell
#   variable, not a flag. If it is a variable or absent, return empty.
extract_pr_number() {
  local cmd="$1"
  local pr=""

  # 1. gh api path extraction — greps the /pulls/<N>/merge segment directly.
  #    The PR number lives in the URL path, so redirections cannot affect it.
  pr=$(echo "$cmd" | grep -oE 'repos/[^/[:space:]]+/[^/[:space:]]+/pulls/[0-9]+/merge' | grep -oE '/pulls/[0-9]+/' | grep -oE '[0-9]+' | head -1)

  # 1b. glab api path extraction — the /merge_requests/<N>/merge segment (#767).
  #     Same URL-path discipline as step 1: the MR iid lives in the path, so
  #     redirections cannot affect it. The `/merge` suffix keeps this from
  #     grabbing an iid out of a non-merge URL (e.g. `/merge_requests/42/notes`).
  if [ -z "$pr" ]; then
    pr=$(echo "$cmd" | grep -oE 'merge_requests/[0-9]+/merge' | grep -oE '[0-9]+' | head -1)
  fi

  # 2. gh pr merge positional arg.
  if [ -z "$pr" ]; then
    # a) Isolate the `gh pr merge …` span up to the first shell separator
    #    (pipe, &&, ;). The [^|;&]* fence keeps us from reading past a piped
    #    follow-up command (e.g. `| tail -5`).
    local span
    span=$(echo "$cmd" | grep -oE '\bgh\s+pr\s+merge\b[^|;&]*')

    # b) Strip all redirection tokens so that `2>&1`, `2>file`, `&>file`,
    #    `>>file`, `>file` etc. cannot contribute digits to the PR search.
    #    Patterns (ordered most-specific first to avoid partial matches):
    #      [0-9]*>&[0-9]*   — fd-to-fd redirections like `2>&1`, `1>&2`
    #      &>[^[:space:]]*  — Bash &> combined redirect
    #      >>[^[:space:]]* — append redirect
    #      >[^[:space:]]*  — overwrite redirect
    local clean_span
    clean_span=$(echo "$span" | sed \
      -e 's/[0-9]*>&[0-9]*/  /g' \
      -e 's/&>[^[:space:]]*/  /g' \
      -e 's/>>[^[:space:]]*/  /g' \
      -e 's/>[^[:space:]]*/  /g')

    # c) After `merge`, take the first whitespace-delimited token.
    #    - If it starts with `$` → unexpanded variable → PR number unknown.
    #      Return empty; step 3 will ask `gh pr view`.
    #    - If it is a bare integer → that is the PR number.
    #    - Anything else (flag, string) → no literal PR number present;
    #      return empty. Do NOT scan further for stray digits — that is
    #      precisely the bug.
    #
    #    Use `grep -oE '\bmerge\b …'` rather than `sed 's/.*\bmerge\b…'`
    #    because BSD sed on macOS does not support \b word boundaries.
    local first_token
    first_token=$(echo "$clean_span" | grep -oE '\bmerge\b[[:space:]]+[^[:space:]]*' | awk 'NR==1 {print $NF}')

    if echo "$first_token" | grep -qE '^\$'; then
      # Unexpanded variable — cannot determine PR number from command text.
      pr=""
    elif echo "$first_token" | grep -qE '^[0-9]+$'; then
      pr="$first_token"
    else
      # No bare integer immediately after merge; leave pr empty.
      pr=""
    fi
  fi

  # 2b. glab mr merge positional arg (#764, GitLab). Same span-fencing and
  #     redirection-stripping discipline as the gh path above.
  if [ -z "$pr" ]; then
    local gspan gclean gtoken
    gspan=$(echo "$cmd" | grep -oE '\bglab\s+mr\s+merge\b[^|;&]*')
    if [ -n "$gspan" ]; then
      gclean=$(echo "$gspan" | sed \
        -e 's/[0-9]*>&[0-9]*/  /g' \
        -e 's/&>[^[:space:]]*/  /g' \
        -e 's/>>[^[:space:]]*/  /g' \
        -e 's/>[^[:space:]]*/  /g')
      gtoken=$(echo "$gclean" | grep -oE '\bmerge\b[[:space:]]+[^[:space:]]*' | awk 'NR==1 {print $NF}')
      if echo "$gtoken" | grep -qE '^[0-9]+$'; then
        pr="$gtoken"
      fi
    fi
  fi

  # 2c. tracker_pr_merge wrapper positional arg (#759): `<pr>` is the SECOND
  #     argument — `tracker_pr_merge <owner/repo> <pr> <strategy> [<del>]`.
  #     Fenced at `)` too (not just `|;&`) since the real call site is
  #     `MERGE_RESULT=$(tracker_pr_merge "..." "..." ... true)` — a command
  #     substitution, so a trailing `)` closes the span. Quoted-or-bare
  #     positional extraction via _extract_wrapper_arg — no eval.
  if [ -z "$pr" ]; then
    local wspan wargs wtoken
    wspan=$(echo "$cmd" | grep -oE '\btracker_pr_merge\b[^|;&)]*')
    if [ -n "$wspan" ]; then
      wargs=$(echo "$wspan" | sed -E 's/^tracker_pr_merge[[:space:]]+//')
      wtoken=$(_extract_wrapper_arg "$wargs" 2)
      if echo "$wtoken" | grep -qE '^[0-9]+$'; then
        pr="$wtoken"
      fi
    fi
  fi

  # 3. Last resort: ask the forge which PR/MR the current branch points at.
  #    Forge-aware (#764): a glab command falls back to `glab mr view`.
  if [ -z "$pr" ]; then
    if [ "$(_forge_from_command "$cmd")" = glab ]; then
      pr=$(glab mr view --output json 2>/dev/null | jq -r '.iid // empty' 2>/dev/null)
    else
      pr=$(gh pr view --json number --jq '.number' 2>/dev/null)
    fi
  fi

  echo "$pr"
}

# Returns 0 if the merge command's PR positional arg OR its --repo value is an
# UNEXPANDED shell variable ($VAR / ${VAR}). (#643)
#
# WHY THIS EXISTS
# ---------------
# Hooks see the LITERAL command string, before the shell expands variables. For
# `gh pr merge $PR --repo $REPO`, the hook cannot know the real PR/repo:
#   - extract_pr_number returns empty for `$PR` (good, #568) but then falls back
#     to `gh pr view` in the CWD — checking a totally UNRELATED PR's CI.
#   - extract_repo_from_command captures the literal `$REPO`, which `gh` then
#     rejects with `expected the "[HOST/]OWNER/REPO" format`.
# Both produce misleading output and can evaluate the wrong PR. A gate that
# can't resolve its target must not guess — callers should BLOCK with a
# "re-run with literal values" message. This helper is that detector.
#
# Matches `$VAR`, `${VAR}` (the leading char after $ / ${ is a letter or _).
# Does NOT match a literal repo/number, and does NOT match `$(...)` command
# substitution as a PR/repo token (those aren't valid PR/repo values anyway).
merge_command_uses_variable() {
  local cmd="$1"

  # PR positional arg: first token after `gh pr merge` (reuse the same span +
  # redirection-stripping discipline as extract_pr_number so `2>&1` etc. don't
  # masquerade as the positional arg).
  local span clean_span first_token
  # Match either forge's merge span: `gh pr merge …` or `glab mr merge …` (#764).
  span=$(echo "$cmd" | grep -oE '\b(gh\s+pr|glab\s+mr)\s+merge\b[^|;&]*')
  clean_span=$(echo "$span" | sed \
    -e 's/[0-9]*>&[0-9]*/  /g' \
    -e 's/&>[^[:space:]]*/  /g' \
    -e 's/>>[^[:space:]]*/  /g' \
    -e 's/>[^[:space:]]*/  /g')
  first_token=$(echo "$clean_span" | grep -oE '\bmerge\b[[:space:]]+[^[:space:]]*' | awk 'NR==1 {print $NF}')
  # Match `$VAR`, `${VAR}`, and the quoted forms `"$VAR"` / `'$VAR'` — agents and
  # operators routinely quote the substitution. The optional leading quote keeps
  # the anchor from being defeated by it.
  if echo "$first_token" | grep -qE '^["'"'"']?\$\{?[A-Za-z_]'; then
    return 0
  fi

  # repo value (same quoted-or-bare variable forms). Covers `--repo` and the
  # short `-R` alias (#764). Searched within clean_span (the fenced merge span),
  # not the whole command, so a trailing unrelated `-R` in a compound command
  # can't be picked up.
  local repo_token
  repo_token=$(echo "$clean_span" | sed -nE 's/.*(--repo|-R)[[:space:]]+([^[:space:]]+).*/\2/p' | head -1)
  if echo "$repo_token" | grep -qE '^["'"'"']?\$\{?[A-Za-z_]'; then
    return 0
  fi

  # tracker_pr_merge wrapper positional args (#759): repo is arg 1, pr is
  # arg 2 — check both for an unexpanded `$VAR`/`${VAR}`, same as the
  # gh/glab positional-arg and --repo/-R checks above. _extract_wrapper_arg
  # returns the literal text between quotes verbatim (no expansion), so a
  # quoted `"$REPO"` still surfaces its leading `$` for this check.
  local wspan wargs wpr wrepo
  wspan=$(echo "$cmd" | grep -oE '\btracker_pr_merge\b[^|;&)]*')
  if [ -n "$wspan" ]; then
    wargs=$(echo "$wspan" | sed -E 's/^tracker_pr_merge[[:space:]]+//')
    wrepo=$(_extract_wrapper_arg "$wargs" 1)
    wpr=$(_extract_wrapper_arg "$wargs" 2)
    if echo "$wrepo" | grep -qE '^\$\{?[A-Za-z_]'; then
      return 0
    fi
    if echo "$wpr" | grep -qE '^\$\{?[A-Za-z_]'; then
      return 0
    fi
  fi

  return 1
}

# Echoes the PR's HEAD SHA as reported by GitHub, or empty on failure.
#
# Why this exists (see #55): merge-gate hooks previously compared approval
# markers against `git rev-parse HEAD` (local HEAD). But `gh pr merge <N>`
# merges the PR's branch on GitHub's side, which is almost never equal to
# the local HEAD (local is usually `main` or a different feature branch).
# That meant every merge required a `gh pr checkout <N> && gh pr merge <N>`
# dance. Tedious and error-prone.
#
# This helper asks GitHub directly for the PR's HEAD via `gh pr view`.
# Works for both the `gh pr merge` and `gh api .../pulls/<N>/merge` shapes.
#
# Usage:
#   PR_HEAD=$(resolve_pr_head "$PR_NUMBER" "$CMD_REPO")
#   # Compare PR_HEAD against marker SHAs instead of git rev-parse HEAD.
#
# Failure modes (returns empty, caller should fall back):
#   - Network error / rate limit / gh auth expired
#   - PR doesn't exist (wrong number, closed, or wrong repo)
#   - GitHub API transient failure
#
# On failure the caller should fall back to `git rev-parse HEAD` with a
# visible warning — better to block a valid merge that the user can retry
# than silently allow a merge on the wrong SHA.
resolve_pr_head() {
  local pr_number="$1"
  local cmd_repo="$2"
  local sha=""

  if [ -z "$pr_number" ]; then
    echo ""
    return
  fi

  # Forge-aware (#764): glab projects resolve the MR HEAD SHA via `glab mr view`.
  # glab's MR JSON exposes the head commit as `.sha` (fallback `.diff_refs.head_sha`
  # on older glab). Any non-glab forge → the unchanged gh path.
  if [ "$(_forge_kind_for "$cmd_repo")" = glab ]; then
    if [ -n "$cmd_repo" ]; then
      sha=$(glab mr view "$pr_number" -R "$cmd_repo" --output json 2>/dev/null | jq -r '.sha // .diff_refs.head_sha // empty' 2>/dev/null)
    else
      sha=$(glab mr view "$pr_number" --output json 2>/dev/null | jq -r '.sha // .diff_refs.head_sha // empty' 2>/dev/null)
    fi
  elif [ -n "$cmd_repo" ]; then
    sha=$(gh pr view "$pr_number" --repo "$cmd_repo" --json headRefOid --jq '.headRefOid' 2>/dev/null)
  else
    sha=$(gh pr view "$pr_number" --json headRefOid --jq '.headRefOid' 2>/dev/null)
  fi

  echo "$sha"
}

# Echoes the PR/MR's HEAD (source) branch name, or empty on failure.
#
# Extracted (#764) from block-unreviewed-merge.sh's inline `gh pr view
# --json headRefName` so the sync-PR `--squash` guard is forge-aware. On glab
# the source branch is `.source_branch`; on gh it is `.headRefName`. Same
# repo-optional shape and silent-empty-on-failure contract as resolve_pr_head.
resolve_pr_head_branch() {
  local pr_number="$1"
  local cmd_repo="$2"
  local branch=""

  if [ -z "$pr_number" ]; then
    echo ""
    return
  fi

  if [ "$(_forge_kind_for "$cmd_repo")" = glab ]; then
    if [ -n "$cmd_repo" ]; then
      branch=$(glab mr view "$pr_number" -R "$cmd_repo" --output json 2>/dev/null | jq -r '.source_branch // empty' 2>/dev/null)
    else
      branch=$(glab mr view "$pr_number" --output json 2>/dev/null | jq -r '.source_branch // empty' 2>/dev/null)
    fi
  elif [ -n "$cmd_repo" ]; then
    branch=$(gh pr view "$pr_number" --repo "$cmd_repo" --json headRefName -q '.headRefName' 2>/dev/null)
  else
    branch=$(gh pr view "$pr_number" --json headRefName -q '.headRefName' 2>/dev/null)
  fi

  echo "$branch"
}

# Echoes a normalized CI/pipeline status for a PR/MR — the glab counterpart of
# `gh pr checks`, used by block-merge-on-red-ci.sh (#790, the last merge gate
# to gain forge-awareness after #767 covered block-unreviewed-merge.sh).
#
# GitHub's `gh pr checks` returns per-check text + an exit code the caller
# parses directly — there is no equivalent normalization needed there, so this
# function is glab-only; the gh path in block-merge-on-red-ci.sh is untouched.
#
# Returns one of:
#   success  — the MR's head pipeline passed
#   pending  — the pipeline is still running/queued/gated on a manual job
#   failure  — the pipeline failed, was cancelled, or was skipped
#   none     — the MR has no pipeline configured (legitimate no-CI state,
#              the glab analog of gh's "no checks reported")
#   ""       — the status could not be determined: glab missing, a non-zero
#              glab exit code, empty stdout, or a non-empty response that
#              isn't a valid MR object (auth-error envelope, HTML error
#              page, truncated/garbage JSON, a bare scalar or array — none
#              of these carry an `.iid`). The caller MUST fail CLOSED on
#              empty — an unresolvable status is never treated as green,
#              exactly like red-or-unfetchable CI must never silently pass
#              on the gh path.
#
# GitLab's MR API exposes the pipeline attached to the MR's HEAD SHA as
# `head_pipeline` (current API); `pipeline` is the older/deprecated
# single-pipeline field some GitLab/glab versions still populate, kept as a
# fallback. Status values per GitLab's Pipeline API: created,
# waiting_for_resource, preparing, pending, running, success, failed,
# canceled, skipped, manual, scheduled.
resolve_ci_status_glab() {
  local pr_number="$1"
  local cmd_repo="$2"
  local json status rc has_iid

  if [ -z "$pr_number" ]; then
    echo ""
    return
  fi

  if [ -n "$cmd_repo" ]; then
    json=$(glab mr view "$pr_number" -R "$cmd_repo" --output json 2>/dev/null)
  else
    json=$(glab mr view "$pr_number" --output json 2>/dev/null)
  fi
  rc=$?

  # Fail closed on a non-zero glab exit code, mirroring the gh path's
  # CHECKS_RC discipline — the exit code is the authoritative signal
  # when glab supplies one, so don't rely on stdout emptiness alone (a
  # non-zero exit can still print something to stdout).
  if [ "$rc" -ne 0 ] || [ -z "$json" ]; then
    echo ""
    return
  fi

  # Require the response to actually be a valid MR object (i.e. it has an
  # `.iid`) before treating an absent pipeline as the legitimate no-CI
  # `none` state. `jq -e` exits non-zero on a parse failure AND when the
  # queried value is null/absent, so this single check rejects every
  # non-MR shape in one place: garbage/non-JSON, truncated JSON, a bare
  # scalar or array, and JSON error envelopes like
  # `{"message":"401 Unauthorized"}` or an HTML error page glab passed
  # through unparsed (none of these carry an `.iid`). A genuine MR
  # response — with or without a pipeline — always has one.
  if ! has_iid=$(echo "$json" | jq -e -r '.iid' 2>/dev/null) || [ -z "$has_iid" ]; then
    echo ""
    return
  fi

  # json is now confirmed to be a real MR object, so a missing/null
  # pipeline field below is the legitimate "no CI configured" case, not
  # an unparseable response — deliberately NOT using `jq -e` here: it
  # would exit non-zero for the `empty`/`null` result this case is
  # supposed to reach.
  status=$(echo "$json" | jq -r '.head_pipeline.status // .pipeline.status // empty' 2>/dev/null)

  case "$status" in
    "" | null)
      # Valid MR object (iid confirmed above) with no pipeline object —
      # MR genuinely has no CI configured.
      echo "none"
      ;;
    success)
      echo "success"
      ;;
    failed | canceled | cancelled | skipped)
      echo "failure"
      ;;
    running | pending | created | waiting_for_resource | preparing | scheduled | manual)
      echo "pending"
      ;;
    *)
      # Unrecognised/future GitLab status value — fail closed (treat as
      # blocking) rather than silently allow an unknown state through.
      echo "pending"
      ;;
  esac
}

# Echoes the owner/repo extracted from the merge command, or empty if not found.
#
# This is a SIBLING function to extract_pr_number — same parsing approach,
# repo-extraction only. Kept separate so the existing extract_pr_number
# contract is not disturbed (it is used widely; callers that don't need the
# repo are unaffected).
#
# Recognises:
#   1. `gh api repos/<owner>/<repo>/pulls/<N>/merge ...`  — repo from URL path
#   1b. `glab api projects/<owner>%2F<repo>/merge_requests/<N>/merge ...` — repo
#       from the URL-encoded project path (#767)
#   2. `gh pr merge ... --repo <owner>/<repo> ...`        — repo from --repo flag
#   3. Falls back to `gh pr view --json headRepository`   — current branch's PR
#
# Returns empty if the repo cannot be determined.
extract_repo_from_command() {
  local cmd="$1"
  local repo=""

  # 1. gh api path extraction.
  repo=$(echo "$cmd" | grep -oE 'repos/[^/[:space:]]+/[^/[:space:]]+/pulls/[0-9]+/merge' \
    | sed -nE 's|repos/([^/]+/[^/]+)/pulls/.*|\1|p' | head -1)

  # 1b. glab api path extraction (#767). GitLab's API takes the project as a
  #     single URL-encoded path segment — `projects/<owner>%2F<repo>` (nested
  #     subgroups become `<a>%2F<b>%2F<repo>`). There are no literal slashes in
  #     the encoded segment, so [^/[:space:]]+ captures the whole project; then
  #     decode %2F/%2f back to `/` so the result matches the owner/repo form the
  #     markers and `glab mr view -R` expect.
  if [ -z "$repo" ]; then
    repo=$(echo "$cmd" | grep -oE 'projects/[^/[:space:]]+/merge_requests/[0-9]+/merge' \
      | sed -nE 's|projects/([^/]+)/merge_requests/.*|\1|p' | head -1)
    if [ -n "$repo" ]; then
      repo=$(echo "$repo" | sed -e 's/%2[Ff]/\//g')
    fi
  fi

  # 2. Repo flag on the merge command: gh/glab `--repo` or the short `-R` alias
  #    (both gh and glab accept `-R`) (#764). Search ONLY within the merge-command
  #    span (fenced at the first shell separator, like extract_pr_number) so a
  #    trailing unrelated `-R` in a compound command — e.g. `... && grep -R foo` —
  #    cannot be mistaken for the merge target's repo.
  if [ -z "$repo" ]; then
    local mspan
    mspan=$(echo "$cmd" | grep -oE '\b(gh\s+pr|glab\s+mr)\s+merge\b[^|;&]*')
    repo=$(echo "$mspan" | sed -nE 's/.*(--repo|-R)[[:space:]]+([^[:space:]]+).*/\2/p' | head -1)
  fi

  # 2b. tracker_pr_merge wrapper positional arg (#759): `<owner/repo>` is the
  #     FIRST argument — `tracker_pr_merge <owner/repo> <pr> <strategy> [<del>]`.
  #     Same fencing-at-`)` discipline as extract_pr_number's wrapper step
  #     (the real call site is a `$(...)` command substitution).
  if [ -z "$repo" ]; then
    local wspan wargs
    wspan=$(echo "$cmd" | grep -oE '\btracker_pr_merge\b[^|;&)]*')
    if [ -n "$wspan" ]; then
      wargs=$(echo "$wspan" | sed -E 's/^tracker_pr_merge[[:space:]]+//')
      repo=$(_extract_wrapper_arg "$wargs" 1)
    fi
  fi

  # 3. Last resort: ask the forge which repo the current branch's PR/MR belongs
  #    to. Forge-aware (#764): a glab command falls back to `glab repo view`.
  if [ -z "$repo" ]; then
    if [ "$(_forge_from_command "$cmd")" = glab ]; then
      repo=$(glab repo view --output json 2>/dev/null | jq -r '.full_name // empty' 2>/dev/null)
    else
      repo=$(gh pr view --json headRepository --jq '.headRepository.nameWithOwner' 2>/dev/null)
    fi
  fi

  echo "$repo"
}
