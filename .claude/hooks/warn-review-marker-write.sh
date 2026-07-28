#!/bin/bash
# PreToolUse hook — fires when a Write tool call or a Bash command targets a
# review-marker file (*-rex.approved, *-ceo.approved, *-security.approved,
# *-architecture.approved) under .claude/session/reviews/.
#
# CLASS: BACKSTOP — NOT THE CONTROL  (AgDR-0104 labelling, AgDR-0109 §1)
# ----------------------------------------------------------------------
# This hook is ADVISORY. It warns; it never blocks (exit 0 always).
#
# THE control that protects merge integrity is, and remains:
#
#   1. The per-PR human merge approval (/approve-merge), and
#   2. block-unreviewed-merge.sh comparing each marker's SHA against the
#      PR's HEAD *as reported by the forge* — structured state this hook
#      cannot see and a local file write cannot fake.
#
# WHY THIS IS NOT A CONTROL. It decides by pattern-matching the TEXT of a
# shell command, and AgDR-0104 established that such a gate "cannot be made
# sound — the ways to express a path ($VAR, $(…), concat, here-doc, symlink,
# printf) are unbounded." Four rounds of patches (#962, #1000, #1011, #1026)
# confirmed it empirically, in BOTH directions at once.
#
# ACCEPTED LIMIT — one known shape is NOT detected, and that is deliberate:
#
#   - Split path:  S=.claude/session/reviews; printf x > "$S/<…>-rex.approved"
#     Neither matcher sees it: the literal check needs the whole path in one
#     token, and the indirection heuristic keys on `review_marker_path`, the
#     reviews/ dir, or a variable NAMED *marker* — a variable called `S`
#     matches none. Filed as #1026 and left open on purpose.
#
# Do NOT close it with a fifth pattern. #1026 asks for exactly that restraint,
# because the next spelling (command substitution, printf-concatenation, a
# symlinked directory) would still pass. The ways to express a path are
# unbounded; a substring matcher will always be one spelling behind.
#
# For the avoidance of doubt, these three ARE detected and DO warn — earlier
# rounds closed them, and cases 20/23/27 and 35-39 pin that. Don't cite them
# as evidence the hook sees nothing:
#
#   - Variable indirection (#962)   - Interpreter heredoc   - BSD/GNU sed -i
#
# The point is not that detection is hopeless. It is that detection is
# unreliable in BOTH directions, so the consequence of a match must be a
# warning rather than a block.
#
# The symmetric limit is over-firing: the text of a command that merely
# MENTIONS a marker — a grep pattern, a commit message, a code review, a
# JSON payload, this comment block — is indistinguishable from one that
# writes it. That is why exit 0 is the right answer even on a match.
#
# HISTORY
# -------
# #728 made this hook's banner "unmissable" (VIOLATION framing, per-marker-type
# messaging) but kept it purely advisory (exit 0 always) — reasoning that the
# harness provides no per-agent-type signal (CLAUDE_CODE_CHILD_SESSION is set
# identically for every sub-agent, sanctioned reviewer or not), so a shell
# hook cannot reliably distinguish "the real code-reviewer is writing this"
# from "a build agent is impersonating the code-reviewer".
#
# #843 found the residual gap: the banner alone doesn't stop the write, and
# twice (PRs #835, #842) a build-class sub-agent — which cannot nest the
# Agent tool to spawn the real reviewer — resolved auto-code-review.sh's
# "Invoke Rex NOW" instruction by impersonating Rex itself: posting a fake
# review and writing the *-rex.approved marker.
#
# THE FIX (#843): rather than trying to distinguish agent *identity* (the
# #728 blocker), gate on agent *provenance via session state* instead — a
# **active-reviewer session marker** at .claude/session/active-reviewer that
# the orchestrator (or one of /code-review, /security-review, /design-review)
# writes immediately before spawning the sanctioned reviewer, one line:
# `<owner>/<repo>#<pr>:<kind>`. A write to *-rex.approved / *-security.approved
# / *-architecture.approved without that marker was BLOCKED (exit 2) from #843
# until #1026 returned the hook to advisory — see "#1026 — BACK TO ADVISORY"
# below. The (repo, pr, kind) match still decides whether the banner fires:
#
#   .claude/session/active-reviewer contains:  me2resh/apexyard#843:rex
#   allows a write to:                         me2resh__apexyard__843-rex.approved
#   blocks a write to:                         me2resh__apexyard__843-security.approved  (kind mismatch)
#   blocks a write to:                         me2resh__apexyard__844-rex.approved        (pr mismatch)
#
# A build-class sub-agent — spawned to implement a ticket, with no reason to
# ever see an active-reviewer marker set for its own PR — is blocked with a
# message telling it to stop and hand back to the orchestrator.
#
# #962 — RESOLVED-TARGET DETECTION (closes the prior KNOWN LIMITATION)
# ----------------------------------------------------------------------
# #843's detection matched the LITERAL marker suffix as a plain substring of
# the Bash command TEXT. Two consequences fell out of that:
#
#   1. FALSE NEGATIVE (security-relevant): the sanctioned reviewers' own
#      documented idiom builds the marker path via a shell variable —
#      `REX_MARKER=$(review_marker_path "$REPO" "$PR" rex "$MARKER_HOME")`
#      then `printf '%s\n' "$SHA" > "$REX_MARKER"` — where the literal
#      `-rex.approved` suffix never appears anywhere in the command text.
#      A build agent forging by copying that exact idiom evaded the gate
#      entirely: no active-reviewer marker required, no block.
#   2. FALSE POSITIVE: a harmless READ of a marker path that happens to
#      spell out the literal filename (`cat .claude/session/reviews/…
#      -security.approved`) tripped the same substring match and was
#      wrongly refused, even though nothing was being written.
#
# THE FIX: detect on the RESOLVED WRITE, not a literal-path substring —
# reusing `_lib-detect-bash-write.sh` (the same helper require-active-
# ticket.sh's Bash matcher already uses for the identical class of problem,
# see me2resh/apexyard#151):
#
#   - `bash_command_appears_to_write` distinguishes a genuine write
#     (redirection, tee, sed -i, an embedded interpreter with a write
#     keyword, …) from a plain read (cat/grep/head) — closing the false
#     positive. A literal-path match is now gated ONLY when the command is
#     also an actual write.
#   - When the command performs a write but carries no literal marker path,
#     `_is_marker_plausible_indirect` looks for the documented indirection
#     idiom itself — a `review_marker_path` call, a `.claude/session/
#     reviews/` mention, an `active-reviewer` mention, or a write target
#     whose variable NAME follows the established *_MARKER convention
#     (REX_MARKER, CEO_MARKER, SECURITY_MARKER, ARCH_MARKER, …). Any of
#     those, combined with a real write, is treated as a plausible marker
#     write and gated — closing the false negative.
#   - Best-effort role (`_extract_marker_role`) and PR-number
#     (`_extract_marker_pr`) extraction reads the SAME `review_marker_path`
#     call's own positional arguments — the role and PR-number arguments
#     are conventionally literal in the reviewers' documented usage (see
#     code-reviewer.md / solution-architect.md), even though the RESULT of
#     the call is assigned to a variable. When the role can't be resolved
#     at all, the write is still gated — no literal `c_kind` in a
#     well-formed `active-reviewer` marker can ever equal an unresolved
#     empty string, so an unresolvable marker write FAILS CLOSED by
#     construction rather than by a special case.
#
# This does NOT weaken the pre-#962 literal-path detection — it remains the
# first check tried, unchanged — it only (a) requires that check to
# co-occur with an actual write (fixing the read false-positive) and (b)
# adds a second, indirection-aware detection path alongside it (fixing the
# write false-negative). If `_lib-detect-bash-write.sh` is missing for any
# reason, this hook falls back to the original #843 literal-substring-only
# behaviour (conservative — the pre-existing false-positive-on-read
# limitation re-applies, but nothing new is weakened).
#
# *-ceo.approved KEEPS its original #728 advisory-only behaviour (never
# blocks) — it has its own structured-field defence in
# block-unreviewed-merge.sh (sha= / approved_by=user / skill_version=) and is
# written by a human-invoked skill (/approve-merge), not a reviewer agent.
#
# Legacy bare-number marker filenames (pre-#485 repo-qualifier, e.g.
# `843-rex.approved` with no `<owner>__<repo>__` prefix) are still
# recognised — the repo component of the active-reviewer check is skipped
# for those (can't recover a repo from a bare filename), but the pr + kind
# match still applies. The same skip-when-unresolvable philosophy extends
# to #962's indirect-resolution path: when the PR number or repo can't be
# recovered from the command text, that comparison is skipped, but kind
# (rex vs security vs architecture) is ALWAYS required to match — and an
# unresolved kind can never match, so under-resolution fails closed, not
# open.
#
# THREAT MODEL: same as every other marker in this framework (see
# .claude/rules/pr-workflow.md). Local session state, gitignored, converts
# invisible inference into visible, checkable file existence. Claude can
# still fabricate the active-reviewer marker by hand — that is a visible,
# auditable, grep-able rule violation, same order of magnitude as forging
# the marker directly used to be. The mechanical gate exists to remove the
# INDUCED failure mode (auto-code-review.sh's banner telling a build agent
# to do the impossible), not to defend against a deliberately adversarial
# agent. #962's resolved-target detection narrows the surface further but
# makes the same non-claim: a sufficiently adversarial agent that avoids
# every keyword/naming signal this hook looks for is not mechanically
# stopped — the load-bearing defences remain the per-PR human-approver nod
# and the orchestrator running a real, separate reviewer pass.
#
# #873 trimmed the BLOCKED banner's orchestrator branch: since the sanctioned
# reviewer writes the marker via the variable form (now DETECTED by #962,
# see above — no longer a blind spot), the only caller who used to land on
# this banner via a literal-path write was doing the induced-forgery case.
# Printing a copy-pasteable `printf > active-reviewer` recipe there handed a
# working marker-set command to the agent we least want holding one. The
# banner points the orchestrator at the matching skill (/code-review,
# /security-review, /design-review) instead — same skills that already own
# the marker's set/clear lifecycle (see auto-code-review.sh's #843 banner for
# the sibling fix this mirrors).
#
# Wired in .claude/settings.json PreToolUse for:
#   matcher: Write    (catches direct file writes)
#   matcher: Bash     (catches shell redirections, echo >, printf, tee, etc.)
#
# #974 hardened _active_reviewer_allows() further: a malformed on-disk
# active-reviewer marker (empty kind after a trailing colon) combined with
# an unresolved indirect-write role could satisfy `[ "" = "" ]` and
# incorrectly ALLOW the write — the exact "total ambiguity" case the #962
# comment assumed was already fail-closed. Both sides of the kind
# comparison are now guarded explicitly for non-empty before it runs.
#
# #1000 — NARROW DETECTION TO ACTUAL WRITE INTENT (three false positives,
# one real session, one day)
# ----------------------------------------------------------------------
# #962's indirect-write detector scanned the WHOLE COMMAND TEXT for
# marker-shaped substrings whenever the command "appeared to write"
# anything at all. That is broader than the threat it defends against
# (forging a *.approved file's CONTENT) and produced three real false
# blocks in one session:
#
#   1. `rm -f .claude/session/active-reviewer` — the orchestrator's own
#      documented cleanup step (code-review/SKILL.md § 0) — got matched
#      because the command "appears to write" (rm is a file-mover) and
#      the command text mentions "active-reviewer". But `rm` can only
#      DELETE; it can never forge marker CONTENT. Fix: a command whose
#      ONLY write-like signal is deletion (`bash_command_is_deletion_only`
#      — the same helper require-active-ticket.sh already uses for the
#      identical "rm can't add content" reasoning) is no longer treated
#      as a write for THIS gate. This incidentally closes a second,
#      related false block too: `grep -nE "approved|rm -f|active-reviewer"`
#      is a purely READ-ONLY command, but the `|`-preceded "rm " substring
#      INSIDE its own quoted pattern argument satisfies the shared
#      matcher's `[;&|(]`-anchored file-mover regex (which can't see
#      quoting). Since no OTHER write family matches either case,
#      `bash_command_is_deletion_only` returns true for both — one
#      exemption closes both.
#
#   2. Writing to a NON-marker path (a scratchpad file) whose CONTENT
#      happens to mention a marker-shaped variable — e.g. a review body
#      written via heredoc that quotes the hook's own `$marker` token in
#      prose — tripped the `\$\{?[a-z_]*marker[a-z_]*\}?` substring scan
#      even though the write's actual TARGET was nowhere near
#      .claude/session/reviews/. Fix: judge the RESOLVED WRITE TARGET(S)
#      first, via `bash_extract_write_targets` (the plural extractor #886
#      already added for gate-bypass safety). A real write target that's
#      a clean literal path AND isn't marker-shaped is conclusive — no
#      marker is being touched. The broader indirection scan
#      (`_is_marker_plausible_indirect`) only runs as a fallback: no
#      target was extractable at all, or an extracted target is itself
#      variable-derived (so it *might* still resolve to a marker) — and
#      even then, over TEXT with heredoc BODY content stripped out first
#      (`_strip_heredoc_bodies`), so payload prose can no longer
#      masquerade as destination code. This does NOT touch the sanctioned
#      reviewer idiom (`REX_MARKER=$(review_marker_path ...); printf ... >
#      "$REX_MARKER"`) — that idiom's target IS a *_MARKER-named variable,
#      matched directly per-target, same detection as before.
#
#   3. The literal "active-reviewer" substring signal (previously one of
#      _is_marker_plausible_indirect's OR-conditions) was ALSO found to
#      block the orchestrator's own documented SET step (code-review/
#      SKILL.md § 0's `printf '%s\n' "<owner>/<repo>#<pr>:rex" >
#      "$ops_root/.claude/session/active-reviewer"`) — role can never
#      resolve for that write (no `review_marker_path` call in it), so it
#      hit the same fail-closed-on-unresolved-role path as a real forgery
#      attempt. Checked whether this signal was actually load-bearing: it
#      was not — the IDENTICAL write via the Write tool (file_path =
#      ".../active-reviewer") was never matched by this hook at all
#      (`_is_marker_target`'s pattern requires the reviews/ dir + an
#      -approved suffix, which active-reviewer's path never has), so a
#      Write-tool-based forgery of active-reviewer sailed through ungated
#      on both sides of #1000. The Bash-only substring match was
#      inconsistent swiss cheese that blocked the legitimate flow without
#      closing the actual hole — removed. Per this hook's own pre-existing
#      THREAT MODEL note (above): forging active-reviewer by hand remains
#      a visible/auditable rule violation, not a technically-prevented
#      one — unchanged by #1000, just now consistent across both tool
#      shapes instead of blocking Bash only.
#
# What did NOT change: a genuine indirect marker write with an unresolved
# role or PR still fails closed exactly as #962/#974/#977/#992
# established — the per-target *_MARKER-convention match, the
# `review_marker_path`-call role/PR extraction, and the fail-closed
# _active_reviewer_allows() guards are all unchanged. #1000 narrows what
# counts as "a write worth judging" and "where to look for the marker
# signal" — it does not loosen what happens once something IS judged to
# be one.
#
# #1026 — BACK TO ADVISORY (AgDR-0111; supersedes #843's promotion and
#         AgDR-0109's block-on-resolved-target decision)
# ---------------------------------------------------------------------------
# The paragraph above ("still fails closed") is exactly what #1026 reverses.
# Failing closed on an UNRESOLVED role/PR sounds cautious, but the evidence
# says it protects nothing: in one session it produced 13 false positives
# across 2 hooks, and every single one reported `detected role: unresolved`.
# It blocked a read-only grep (marker path was in the search PATTERN), a
# `git commit` (path was in the MESSAGE), a code reviewer writing its own
# review prose, /approve-merge's own documented `tracker_pr_merge` step, and
# a JSON payload being piped to another program — from which it extracted the
# role as the literal garbage string `…__7777-rex.approved"}}`.
#
# AgDR-0104's "a gate that can't evaluate its precondition must block"
# governs *is this resolved action authorised* — not *is there an action
# here at all*. Blocking a grep declines jurisdiction over a non-event; it
# does not admit an unverified merge. AgDR-0109 works through this at length.
#
# WHY REMOVING THE BLOCK IS SAFE — #843's ROOT CAUSE IS ALREADY FIXED:
#
#   - #843 happened because auto-code-review.sh told build sub-agents to
#     "Invoke Rex NOW", which they cannot do (no nested Agent tool), so they
#     forged the marker to comply. That banner now addresses sub-agents
#     explicitly and tells them to stop and hand back — the inducement is
#     gone, and this block was belt-and-braces on a repaired cause.
#   - The banner below still tells a build agent to stop. That deterrent is
#     retained in full; only the exit code changes.
#   - block-unreviewed-merge.sh still refuses any merge whose marker SHA does
#     not match forge-reported HEAD, and a human still approves every merge.
#
# AgDR-0109 chose "block only on a confidently-resolved target"; #1026 goes
# to plain advisory instead, because the resolver demonstrably emits garbage
# roles — keeping ANY text matcher in a blocking path preserves the defect
# class at higher cost. Recorded in AgDR-0109's changelog.
#
# References: #728, #843, #873, #957, #962, #974, #1000, #1015, #1026, #1032,
#             AgDR-0062, AgDR-0104, AgDR-0109,
#             .claude/rules/pr-workflow.md § "Build agents cannot self-review"

set -u

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"

# Source the bash-write detector (#962). Same helper require-active-
# ticket.sh's Bash matcher uses for the identical "does this command
# actually write" question — see me2resh/apexyard#151. Missing library is
# handled gracefully: fall back to the pre-#962 literal-substring-only
# behaviour rather than bricking the hook (HAVE_BDW_LIB=0 below).
HAVE_BDW_LIB=0
if [ -f "$HOOK_DIR/_lib-detect-bash-write.sh" ]; then
  # shellcheck source=/dev/null
  . "$HOOK_DIR/_lib-detect-bash-write.sh"
  HAVE_BDW_LIB=1
fi

_is_marker_target() {
  local text="$1"
  # Match any path ending with a review-marker filename under the reviews dir:
  #   *-rex.approved          — Rex gate marker (BLOCKING, #843)
  #   *-security.approved     — Security Reviewer gate marker (BLOCKING, #843)
  #   *-architecture.approved — Solution Architect gate marker (BLOCKING, #843)
  #   *-ceo.approved          — CEO gate marker (advisory-only, unchanged)
  echo "$text" | grep -qE '\.claude/session/reviews/[^[:space:]"'"'"']+-(rex|ceo|security|architecture)\.approved'
}

# _is_marker_plausible_indirect TEXT (#962, narrowed #1000)
#
# True when TEXT plausibly targets a review marker via the documented
# indirection idiom:
#   REX_MARKER=$(review_marker_path "$REPO" "$PR" rex "$MARKER_HOME")
#   printf '%s\n' "$SHA" > "$REX_MARKER"
#
# Signals (any one is sufficient):
#   - a `review_marker_path` call anywhere in TEXT
#   - a literal `.claude/session/reviews/` directory mention (without a full
#     matched filename — e.g. a directory-only reference, or a path built
#     via concatenation rather than a single contiguous literal)
#   - a write-target-shaped variable name following the established
#     *_MARKER convention this codebase's reviewers use (REX_MARKER,
#     CEO_MARKER, SECURITY_MARKER, ARCH_MARKER, ARCHITECTURE_MARKER, …)
#
# #1000 removed the bare `active-reviewer` mention as a signal here — it
# was never load-bearing (see the #1000 header comment, point 3) and was
# blocking both the orchestrator's documented cleanup AND set steps for
# that unrelated session marker. Forging *.approved marker CONTENT is
# this function's job; managing active-reviewer is not.
#
# Called two ways (both #1000):
#   - per WRITE TARGET (a short string) — the primary, precise path
#   - as a fallback over the whole, UNSTRIPPED command — only when no clean
#     literal target was found, or an extracted target is itself
#     variable-derived
#
# #1000-REX-ROUND-2 (Rex's PR #1011 review, finding 3): an earlier version
# of this fix stripped heredoc BODY content before running the fallback
# scan, reasoning that heredoc content is always DATA, never destination-
# determining code. That reasoning is correct for a heredoc fed to a plain
# data-writing command (`cat > file <<EOF`) but WRONG for a heredoc fed to
# an INTERPRETER (`python3 <<EOF`, `node <<EOF`, `bash <<EOF`) — there the
# body IS the code that names the write destination, and interpreter
# writes yield no extractable target in the first place (see
# `_bdw_match_python_heredoc` / `_bdw_match_node_heredoc` / etc. in the
# shared lib — they detect the write but extraction can't recover a
# target). Stripping the body before the fallback ran removed the ONLY
# evidence left to scan, so `python3 <<EOF ... open("<marker>","w")... EOF`
# went from BLOCKED (pre-#1000) to silently ALLOWED — a marker-creation
# bypass. Verified: removing the strip (scanning the raw, unstripped
# command here) returns all three interpreter-heredoc shapes to BLOCKED,
# and all 36 existing tests — including the scratchpad-heredoc false
# positive this strip was originally written for (case 31) — still pass.
# Case 31 was never carried by the strip: its target
# (`/tmp/scratch/review-body.md`) is a clean, non-marker literal, so the
# per-target loop already resolves it as conclusive and never reaches this
# fallback at all. The strip was solving an already-solved problem while
# opening a new one — removed rather than special-cased per interpreter,
# since enumerating every interpreter (and `bash <<EOF` isn't even one of
# the shared lib's named interpreter matchers) is a losing race.
_is_marker_plausible_indirect() {
  local text="$1"
  if echo "$text" | grep -qE 'review_marker_path|\.claude/session/reviews/'; then
    return 0
  fi
  echo "$text" | grep -qiE '\$\{?[a-z_]*marker[a-z_]*\}?'
}

# _extract_marker_role COMMAND (#962)
#
# Best-effort role extraction from a `review_marker_path <repo> <pr> <role>
# [marker_home]` call embedded in COMMAND. The call's own arguments are
# conventionally literal in the reviewers' documented usage even when the
# call's RESULT is assigned to a variable (see code-reviewer.md,
# solution-architect.md) — so the role can be recovered even though the
# eventual write target cannot. Echoes rex|ceo|security|architecture, or
# nothing if no such call (or no recognisable role argument) is found.
# #1032: take the role only when it is UNAMBIGUOUS across every
# review_marker_path call in the command. Taking the FIRST call's role was
# wrong: the documented /approve-merge flow READS the rex marker to verify it,
# then WRITES the ceo marker. First-call-wins reported `rex` for a ceo write,
# so the read poisoned the write's classification — and while this hook still
# blocked, that mis-read routed a ceo write (advisory) down the rex path
# (blocking) and hard-blocked the skill's own documented step.
#
# When the calls disagree we genuinely cannot tell which one is the write, so
# echo nothing and let the banner say "unresolved" rather than assert a role
# that may be the one merely being read.
_extract_marker_role() {
  local cmd="$1" roles
  roles=$(echo "$cmd" | grep -oE 'review_marker_path[^;&|)]*' \
    | grep -oE '\b(rex|ceo|security|architecture)\b' | sort -u)
  [ -z "$roles" ] && return 1
  [ "$(echo "$roles" | grep -c '')" -gt 1 ] && return 1
  echo "$roles"
}

# _extract_marker_pr COMMAND (#962)
#
# Best-effort PR-number extraction from the SAME `review_marker_path` call
# — the {number} positional argument is conventionally a literal integer at
# the point a reviewer or skill actually invokes it (a placeholder filled in
# with the real PR number, per code-reviewer.md / solution-architect.md).
# Echoes the first bare digit-run found in the call, or nothing.
# #1032: same unambiguous-only rule as _extract_marker_role above. A verify
# read and a write in one command normally name the SAME pr, so this usually
# still resolves — it only declines when the command genuinely spans two.
_extract_marker_pr() {
  local cmd="$1" prs
  prs=$(echo "$cmd" | grep -oE 'review_marker_path[^;&|)]*' \
    | grep -oE '\b[0-9]+\b' | sort -u)
  [ -z "$prs" ] && return 1
  [ "$(echo "$prs" | grep -c '')" -gt 1 ] && return 1
  echo "$prs"
}

MATCHED=0
MARKER_TYPE=""
TARGET=""
TARGET_PR=""
TARGET_REPO=""
RESOLVED_VIA="literal"   # "literal" | "indirect" — which detection path matched

case "$TOOL_NAME" in
  Write)
    # Write's file_path is always a literal, harness-resolved string — never
    # a shell expression a variable could hide — so the read/write ambiguity
    # and indirection concerns below don't apply here. Unchanged from #843.
    FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
    if _is_marker_target "$FILE_PATH"; then
      MATCHED=1
      TARGET="$FILE_PATH"
    fi
    ;;
  Bash)
    COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)

    if [ "$HAVE_BDW_LIB" = "1" ]; then
      IS_WRITE=1
      bash_command_appears_to_write "$COMMAND" || IS_WRITE=0

      # #1000 point 1: a command whose ONLY write-like signal is deletion
      # (rm, with no redirection/tee/sed-i/cp/mv/dd/install/interpreter-
      # write also present) cannot FORGE marker content — it can only
      # remove a file. `bash_command_is_deletion_only` is the same helper
      # require-active-ticket.sh already uses for the identical "rm can't
      # add content" reasoning. This also incidentally closes the
      # `grep -nE "approved|rm -f|active-reviewer"` read-only false
      # positive — see the #1000 header comment for why both collapse to
      # the same exemption.
      if [ "$IS_WRITE" = "1" ] && bash_command_is_deletion_only "$COMMAND"; then
        IS_WRITE=0
      fi

      if [ "$IS_WRITE" = "1" ]; then
        # #1000 point 2: judge the RESOLVED WRITE TARGET(S) first, not the
        # command's prose — see the #1000-REX-ROUND-2 note on
        # _is_marker_plausible_indirect for why no text-stripping happens
        # here (heredoc-stripping was tried and reverted: it opened an
        # interpreter-heredoc bypass without closing anything the
        # target-based logic wasn't already closing).
        WRITE_TARGETS=$(bash_extract_write_targets "$COMMAND")
        HAS_VAR_TARGET=0

        # #1000-REX-ROUND-2 finding 4: `sed -i` / `awk -i inplace` have a
        # known-fragile positional-argument extraction heuristic (BSD
        # `sed -i ''` in particular — see the fuller comment below, where
        # this flag is consumed). Computed up front so it can widen BOTH
        # the immediate literal re-check AND the general fallback trigger,
        # not just the first — a variable-indirected marker path (case24's
        # `$DIR/mystery.approved` shape) combined with a BSD sed -i
        # mis-extraction would otherwise still slip past both checks.
        IS_EXTRACTION_FRAGILE=0
        echo "$COMMAND" | grep -qE '\bsed[[:space:]]+([^|;&]*[[:space:]])?-i\b|\bawk[[:space:]]+[^|;&]*-i[[:space:]]+inplace\b' && IS_EXTRACTION_FRAGILE=1

        if [ -n "$WRITE_TARGETS" ]; then
          while IFS= read -r wt; do
            [ -z "$wt" ] && continue
            case "$wt" in *'$'*) HAS_VAR_TARGET=1 ;; esac
            if [ "$MATCHED" != "1" ] && _is_marker_target "$wt"; then
              # A real extracted write target is a literal marker path —
              # unambiguous, regardless of what else the command's text
              # says elsewhere (#962 behaviour, now target-scoped).
              MATCHED=1
              TARGET="$wt"
              RESOLVED_VIA="literal"
            elif [ "$MATCHED" != "1" ] && _is_marker_plausible_indirect "$wt"; then
              # The write target ITSELF is a *_MARKER-named variable (the
              # sanctioned reviewer idiom) or names the reviews/ dir — e.g.
              # REX_MARKER=$(review_marker_path ...); printf ... > "$REX_MARKER"
              MATCHED=1
              RESOLVED_VIA="indirect"
            fi
          done <<EOF_TARGETS
$WRITE_TARGETS
EOF_TARGETS
        fi

        # #1000-REX-ROUND-2 (Rex's PR #1011 review, finding 4): the
        # "a clean literal, non-marker, non-variable extracted target is
        # conclusive" shortcut above assumes bash_extract_write_target's
        # positional heuristic got the target RIGHT. For `sed -i` it can
        # be WRONG rather than merely empty: BSD's two-token form
        # (`sed -i '' 's/a/b/' <file>`, or the unquoted `sed -i '' s/a/b/
        # <file>`) makes the extractor return the SED EXPRESSION as "the
        # target" — a literal, non-marker, non-variable string that then
        # makes the extractor's wrong answer look conclusive and skips
        # the REAL marker file the command actually mutates in place.
        # Demonstrated: `sed -i '' s/aa/bb/ <marker>` rewrites a stale
        # marker's SHA to the current HEAD, defeating the "new commits
        # invalidate approval" property this whole gate exists to
        # protect. GNU `sed -i` (single-token form) returns EMPTY targets
        # instead and already reaches the general fallback below — this
        # is specific to the extraction-fragile two-token form.
        #
        # Scoped narrowly via IS_EXTRACTION_FRAGILE (computed above from a
        # pattern mirroring `_bdw_match_sed_inplace`/`_bdw_match_awk_
        # inplace`, duplicated here rather than imported so the shared
        # library stays untouched, per the #1000 blast-radius containment
        # call) — NOT applied to every write: a plain `echo "mentions
        # <marker path> for context" > /tmp/notes.txt` must stay allowed
        # (#1000 point 2) — that's a real target the per-target loop
        # already resolved as conclusive, and it isn't a sed/awk in-place
        # edit.
        if [ "$MATCHED" != "1" ] && [ "$IS_EXTRACTION_FRAGILE" = "1" ] && _is_marker_target "$COMMAND"; then
          MATCHED=1
          TARGET=$(echo "$COMMAND" | grep -oE '\.claude/session/reviews/[^[:space:]"'"'"']+-(rex|ceo|security|architecture)\.approved' | head -1)
          RESOLVED_VIA="literal"
        fi

        if [ "$MATCHED" != "1" ] && { [ -z "$WRITE_TARGETS" ] || [ "$HAS_VAR_TARGET" = "1" ] || [ "$IS_EXTRACTION_FRAGILE" = "1" ]; }; then
          # Fallback broader scan — only reached when (a) no target was
          # extractable at all (an embedded interpreter with an opaque
          # write target this library can't parse), (b) at least one
          # extracted target is itself variable-derived (e.g.
          # `$DIR/mystery.approved`, built from a variable that a PRIOR
          # statement — not the target text itself — assigns from a
          # reviews-dir literal) and so might still resolve to a marker
          # even though the target text alone didn't say so, or (c) the
          # command is from an extraction-fragile family (sed -i / awk -i
          # inplace) whose "target" the immediate check above already
          # tried and failed to confirm as literal — covers the combined
          # shape (b)+(c), e.g. a BSD `sed -i` mutating a
          # variable-indirected marker path, where neither check alone
          # would catch it. Runs over the raw, unstripped command
          # (#1000-REX-ROUND-2) — a fully literal, non-marker,
          # non-variable target from a non-fragile family is treated as
          # conclusive and never reaches this fallback.
          if _is_marker_plausible_indirect "$COMMAND"; then
            MATCHED=1
            RESOLVED_VIA="indirect"
          fi
        fi

        if [ "$MATCHED" = "1" ] && [ "$RESOLVED_VIA" = "indirect" ]; then
          MARKER_TYPE=$(_extract_marker_role "$COMMAND")
          TARGET_PR=$(_extract_marker_pr "$COMMAND")
          TARGET="<resolved via variable/function indirection; detected role: ${MARKER_TYPE:-unresolved}, pr: ${TARGET_PR:-unresolved}>"
        fi
      fi
    else
      # Library unavailable — fall back to the pre-#962 literal-substring
      # check with no read/write distinction (conservative: re-applies the
      # known false-positive-on-read limitation, but doesn't newly weaken
      # anything that was previously caught). #1000's target-based
      # narrowing depends on this same library, so it is unavailable here
      # too — unchanged fallback, matching case25's locked-in behaviour.
      if _is_marker_target "$COMMAND"; then
        MATCHED=1
        TARGET=$(echo "$COMMAND" | grep -oE '\.claude/session/reviews/[^[:space:]"'"'"']+-(rex|ceo|security|architecture)\.approved' | head -1)
        RESOLVED_VIA="literal"
      fi
    fi
    ;;
esac

if [ "$MATCHED" != "1" ]; then
  exit 0
fi

if [ "$RESOLVED_VIA" = "literal" ]; then
  MARKER_BASENAME=$(basename "$TARGET")
  MARKER_TYPE=$(printf '%s' "$MARKER_BASENAME" | sed -E 's/^.*-(rex|ceo|security|architecture)\.approved$/\1/')
fi

# --- Configurable human-approver DISPLAY title (me2resh/apexyard#957) ---
# DISPLAY ONLY: substitutes the printed word for the human per-PR merge
# approver in the CEO banner below. Does NOT affect the marker filename
# (still "-ceo.approved") or any gate logic. Default "CEO" is a
# zero-behaviour-change no-op.
# shellcheck source=/dev/null
. "$HOOK_DIR/_lib-read-config.sh" 2>/dev/null || true
if command -v config_get_or >/dev/null 2>&1; then
  APPROVER_TITLE=$(config_get_or '.review_markers.human_approver_title' 'CEO')
else
  APPROVER_TITLE="CEO"
fi
[ -z "$APPROVER_TITLE" ] && APPROVER_TITLE="CEO"

# --- CEO marker: unchanged #728 advisory-only behaviour (never blocks). ---
if [ "$MARKER_TYPE" = "ceo" ]; then
  cat >&2 <<BANNER
======================================================================
[apexyard] VIOLATION WARNING: Unauthorized review-marker write detected
======================================================================

You are about to write a *-ceo.approved review marker (filename stays
"-ceo.approved" regardless of the configured approver title below).

  *-ceo.approved must be written ONLY by the /approve-merge skill
  on an explicit per-PR ${APPROVER_TITLE} approval. It carries structured
  provenance fields (approved_by=user, skill_version=2) that cannot be
  fabricated casually.

  Who may write this marker:
    the /approve-merge skill, which since #1042 only a HUMAN can invoke
    (disable-model-invocation: true)

WHY THIS MATTERS
  Writing this file yourself satisfies the merge gate's FILENAME check
  but NOT its INTENT. block-unreviewed-merge.sh independently validates
  the structured fields before any merge is allowed, so a hand-written
  marker without those fields is still rejected at merge time.

  You have no path to this marker, and that is deliberate: the invocation
  IS the approval, so it must come from a human. Tell the ${APPROVER_TITLE}
  the PR is ready and ask them to run /approve-merge <pr>. Do not try to
  produce the marker some other way.

======================================================================
BANNER
  exit 0
fi

# --- rex / security / architecture (or an unresolved #962 indirect role):
#     BLOCKING gate on the active-reviewer marker. ---

# Resolve MARKER_HOME the same way every other review-marker hook does
# (ops fork root, not necessarily the current repo's git toplevel — see
# me2resh/apexyard#229/#230).
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
OPS_ROOT=""
if [ -f "$HOOK_DIR/_lib-ops-root.sh" ]; then
  # shellcheck source=/dev/null
  . "$HOOK_DIR/_lib-ops-root.sh"
  OPS_ROOT=$(resolve_ops_root "${REPO_ROOT:-$PWD}")
fi
MARKER_HOME="${OPS_ROOT:-${REPO_ROOT:-.}}"

ACTIVE_REVIEWER_MARKER="$MARKER_HOME/.claude/session/active-reviewer"

if [ "$RESOLVED_VIA" = "literal" ]; then
  # Parse the (repo, pr) this write targets from the marker's own filename.
  # Repo-qualified (post-#485): <owner>__<repo>__<pr>-<role>.approved
  # Legacy bare:                <pr>-<role>.approved
  PREFIX="${MARKER_BASENAME%-${MARKER_TYPE}.approved}"
  if printf '%s' "$PREFIX" | grep -qE '^[0-9]+$'; then
    TARGET_PR="$PREFIX"
    TARGET_REPO=""
  else
    TARGET_PR=$(printf '%s' "$PREFIX" | grep -oE '[0-9]+$')
    TARGET_REPO=$(printf '%s' "$PREFIX" | sed -E "s/__${TARGET_PR}\$//" | sed 's/__/\//')
  fi
fi
# else (RESOLVED_VIA=indirect): TARGET_PR was already best-effort set (may
# be empty) by _extract_marker_pr above; TARGET_REPO stays empty — a repo
# slug is essentially never a literal argument to review_marker_path in
# real usage (always a variable), so there's nothing reliable to recover.
# Same "skip when unresolvable" fallback the legacy bare-marker-filename
# case already uses below.

_active_reviewer_allows() {
  # Returns 0 (allow) iff the active-reviewer marker exists and its
  # <repo>#<pr>:<kind> content matches this write's (repo, pr, role).
  #
  # #974: the #962 comment this replaced claimed fail-closed-on-empty-
  # MARKER_TYPE was automatic — "no well-formed active-reviewer marker can
  # ever have an empty kind field, so `[ "$c_kind" = "$MARKER_TYPE" ]` can
  # never succeed". True for a WELL-FORMED marker, but a MALFORMED one on
  # disk (a stray trailing colon: "owner/repo#42:" with nothing after it)
  # parses to an empty c_kind below. Pair that with this write's own role
  # being unresolved too (MARKER_TYPE="" — the #962 indirect path when
  # _extract_marker_role finds no literal rex/ceo/security/architecture
  # token in the review_marker_path(...) call), and the equality check
  # collapses to `[ "" = "" ]` — TRUE — incorrectly ALLOWING the write.
  # Guard both sides explicitly: an empty resolved role, on EITHER side,
  # can never be treated as a match.
  [ -n "$MARKER_TYPE" ] || return 1

  [ -f "$ACTIVE_REVIEWER_MARKER" ] || return 1
  local content
  content=$(tr -d '[:space:]' < "$ACTIVE_REVIEWER_MARKER" 2>/dev/null)
  [ -n "$content" ] || return 1

  case "$content" in
    *'#'*':'*) : ;;
    *) return 1 ;;
  esac

  local c_repo c_rest c_pr c_kind
  c_repo="${content%%#*}"
  c_rest="${content#*#}"
  c_pr="${c_rest%%:*}"
  c_kind="${c_rest#*:}"

  [ -n "$c_kind" ] || return 1
  [ "$c_kind" = "$MARKER_TYPE" ] || return 1
  # Fail closed when the write's target PR can't be resolved from the marker
  # filename (#977). A marker path whose prefix carries no PR number (e.g. a
  # non-qualified `foo-rex.approved`, or a variable-derived name that matched
  # the marker regex but resolved no digits) leaves TARGET_PR empty. Skipping
  # the PR-equality check there would let such a write match ANY active-reviewer
  # marker of the same kind — regardless of which PR that review is for —
  # breaking the gate's per-PR binding on the indirect path. The sanctioned
  # reviewer flow always writes a repo/PR-qualified marker (via
  # review_marker_path), so its TARGET_PR always resolves; failing closed here
  # costs the legitimate path nothing. Mirrors the empty-kind guard shape above.
  [ -n "$TARGET_PR" ] || return 1
  [ "$c_pr" != "$TARGET_PR" ] && return 1
  # Repo check only when the target filename encodes a repo (post-#485
  # qualified marker). Legacy bare markers, and #962 indirect writes where
  # the repo couldn't be recovered, skip this comparison.
  if [ -n "$TARGET_REPO" ] && [ -n "$c_repo" ] && [ "$c_repo" != "$TARGET_REPO" ]; then
    return 1
  fi
  return 0
}

if _active_reviewer_allows; then
  exit 0
fi

# Map the marker role to the skill that manages its active-reviewer marker
# lifecycle (set at skill entry, cleared after the review is posted — see
# .claude/skills/{code-review,security-review,design-review}/SKILL.md § 0).
case "$MARKER_TYPE" in
  rex) REVIEW_SKILL="code-review" ;;
  security) REVIEW_SKILL="security-review" ;;
  architecture) REVIEW_SKILL="design-review" ;;
  *) REVIEW_SKILL="code-review" ;;
esac

cat >&2 <<MSG
======================================================================
[apexyard] WARNING: review-marker write with no active-reviewer marker
======================================================================

This command looks like it writes a *-${MARKER_TYPE:-<unresolved>}.approved review marker,
and no matching active-reviewer session marker is set.

Target:  ${TARGET}
Expected active-reviewer marker: ${ACTIVE_REVIEWER_MARKER}
  (must contain: <owner>/<repo>#${TARGET_PR:-<pr>}:${MARKER_TYPE:-<role>})

IF YOU ARE A BUILD-CLASS SUB-AGENT (backend-engineer, frontend-engineer,
platform-engineer, product-manager, data-engineer, ui-designer, ux-designer,
tech-lead, etc.): STOP. Do NOT write this file. You cannot nest the Agent
tool to spawn the real reviewer, so any "review" you produce here is the
author reviewing their own work — the exact failure this warning exists to
stop (see .claude/rules/pr-workflow.md § "Build agents cannot self-review").
Report your build results plainly and hand back to the orchestrator.

IF YOU ARE THE ORCHESTRATOR: run the review through the /${REVIEW_SKILL}
skill on this PR:

     /${REVIEW_SKILL} ${TARGET_PR:-<pr>}

The skill sets the active-reviewer session marker, spawns the sanctioned
reviewer, and clears the marker for you — you should NOT set that marker
by hand. A SessionStart sweep also clears stale markers left by an
interrupted session.

IF THIS COMMAND DOES NOT WRITE A MARKER — a grep whose pattern mentions one,
a commit message, a review, a payload passed to another program — this is a
false positive. Proceed; nothing is blocked. Do NOT reword the command to
silence this warning: obfuscating around a security banner is indistinguishable
from evading it, and the warning is not what protects the merge.

This is a BACKSTOP, not the control (AgDR-0109). Merge integrity rests on the
per-PR human approval and on block-unreviewed-merge.sh matching each marker's
SHA against the PR's forge-reported HEAD — neither of which a local file write
can fake.
======================================================================
MSG
exit 0
