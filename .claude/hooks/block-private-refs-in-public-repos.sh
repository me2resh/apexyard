#!/bin/bash
# Blocks issue/PR/comment creation on a public framework repo when the title
# or body references any registered private project from the fork's
# apexyard.projects.yaml.
#
# The leak vector: an agent diagnoses a framework bug while working inside a
# private project, then files the upstream ticket with "discovered during
# <private-project> rebuild". Once filed, the project's name is indexed
# forever on a public issue tracker.
#
# Fires on PreToolUse Bash for the five gh shapes that write to a remote
# tracker:
#   - gh issue create --repo <repo>
#   - gh pr create --repo <repo>
#   - gh issue comment <n> --repo <repo>
#   - gh pr comment <n> --repo <repo>
#   - gh api repos/<owner>/<repo>/{issues,pulls}[...]
#
# Behaviour:
#   - Target repo not public-class → exit 0 silently.
#   - apexyard.projects.yaml missing → exit 0 silently (no scrub list).
#   - Body empty (no title + no body + no body-file) → exit 0 silently.
#   - Skip marker `<!-- private-refs: allow -->` in body → exit 0 with a
#     single-line warning to stderr.
#   - Match against any registered project `name`, `repo`, `workspace`, or
#     an `<owner>/<repo>#<N>` reference to a registered repo → exit 2 with a
#     message naming each leaked token and suggesting abstract replacements.
#
# Configuration (future): a `.claude/project-config.json` may override
# `leak_protection.public_framework_repos` and `leak_protection.skip_marker`.
# For now the defaults are inlined below.

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)

if [ -z "$COMMAND" ]; then
  exit 0
fi

# ---------------------------------------------------------------------------
# 1. Match the five covered gh shapes. If the command is anything else,
#    silently exit 0.
# ---------------------------------------------------------------------------

IS_GH_SUBCMD=0      # gh issue create | gh pr create | gh issue comment | gh pr comment
IS_GH_API=0         # gh api .../issues | .../pulls

if echo "$COMMAND" | grep -qE '\bgh\s+issue\s+create\b'; then IS_GH_SUBCMD=1; fi
if echo "$COMMAND" | grep -qE '\bgh\s+pr\s+create\b'; then IS_GH_SUBCMD=1; fi
if echo "$COMMAND" | grep -qE '\bgh\s+issue\s+comment\b'; then IS_GH_SUBCMD=1; fi
if echo "$COMMAND" | grep -qE '\bgh\s+pr\s+comment\b'; then IS_GH_SUBCMD=1; fi
if echo "$COMMAND" | grep -qE '\bgh\s+api\b.*\b(issues|pulls)\b'; then IS_GH_API=1; fi

if [ "$IS_GH_SUBCMD" -eq 0 ] && [ "$IS_GH_API" -eq 0 ]; then
  exit 0
fi

# ---------------------------------------------------------------------------
# 2/3. Determine whether this write targets a PUBLIC / framework-class repo.
#
#    CLASS-BASED, not positional (me2resh/apexyard#1068, round 2 — security
#    review of the round-1 fix). The membership-check logic in this block
#    is unchanged since round 2 and was independently re-verified sound in
#    round 3's review. Round 3 fixed a SEPARATE bug one level upstream of
#    this block — the write-segment ANCHOR itself could return empty for
#    a write step 1 had already classified as one, which skipped this
#    whole block via the empty-segment exit below. See the large comment
#    inside `find_write_segment` for that fix.
#
#    Round 1 anchored on the matched write invocation and took the FIRST
#    `--repo` value found after it, replacing dev's greedy "last `--repo`
#    on the line wins". That closed the reported bypass (a chained SECOND
#    gh call, or a trailing comment, mentioning `--repo` AFTER the real
#    write) but OPENED the mirror hole: a `--repo`-shaped token embedded in
#    an EARLIER flag's quoted value — e.g. inside `--title` — now won
#    instead of the real flag, because it appears first in raw text.
#    Verified against the actual `upstream/dev` blob at the commit this
#    branch forked from (not reasoned from theory): both
#        gh issue create --title "use --repo priv/x here" --repo pub/y --body "leak"
#        gh issue create --body "run with --repo priv/x for leak" --repo pub/y --title "T"
#    BLOCK on dev (its last-wins happens to land on the real, later flag
#    for this shape) and LEAKED (exit 0, nothing scanned) on round 1. So the
#    round-1 code comment claiming this was "a pre-existing weakness of the
#    previous implementation too" was WRONG — dev did not have this hole;
#    round 1 introduced it. Recorded here so the mistake isn't repeated:
#    every "pre-existing" claim in this file must cite the check that
#    proved it against the actual dev blob, not be reasoned from the shape
#    of the code (AgDR-0113).
#
#    Neither "first after anchor" (round 1) nor "last on the line" (dev)
#    can be made sound, because BOTH are positional: they commit to picking
#    ONE occurrence and trust it to be the real one, and a `--repo`-shaped
#    string can appear anywhere in a flag's free-text VALUE regardless of
#    where the real flag sits.
#
#    The fix is class-based instead of positional: within the write segment
#    (the substring starting at the leftmost recognised write invocation —
#    `gh issue create`, `gh pr create`, `gh issue comment`, `gh pr comment`,
#    `gh api` — so nothing BEFORE the write's own subcommand is in scope),
#    check whether ANY known public-class repo is named as a `--repo` value
#    or a `repos/<owner>/<repo>` URL path, ANYWHERE in that segment. If one
#    is, the write is treated as targeting it — regardless of whether that
#    mention sits before or after other flags, or inside another flag's
#    quoted text. This does not try to determine the ONE true target the
#    way round 1 and dev both did; it asks a narrower, answerable question:
#    "is a public repo plausibly this write's target?" A false YES only
#    ever leads to MORE scanning (the safe direction); it can never cause
#    an unscanned public write, which is the property both prior
#    approaches lacked.
#
#    Deliberate tradeoff, chosen consciously: a single Bash call chaining
#    TWO real writes — one to a private repo, one to a public repo — now
#    scans the private write's title/body too, because the public repo's
#    slug is present somewhere in the combined segment. That is over-
#    blocking, not under-blocking, and is the explicit bar for this fix:
#    fail in the safe direction. (See test 27 in the test file, which
#    intentionally flips from a no-op to a block under this change.)
#
#    Residual (documented, not solved here — command-text matching cannot
#    be made fully sound per AgDR-0104), VERIFIED against the real
#    `upstream/dev` blob rather than assumed:
#      - Two REAL writes chained in one Bash call, where a LEAK sits in an
#        EARLIER write's title/body and a LATER write's --repo names a
#        DIFFERENT (non-public) repo, can still go unscanned: this hook
#        (both before and after this fix) extracts only ONE title/body
#        across the whole command, not per-invocation, so a segment-wide
#        "any public repo present" YES does not guarantee the extracted
#        title/body belongs to the SAME invocation that produced the YES.
#        Confirmed against the real dev blob with a synthetic registry:
#            gh issue create --repo <public> --title "A" --body "<leak>" \
#              && gh issue create --repo <private> --title "B" --body "clean"
#        returns rc=0 (no scan) on dev exactly as it does on this branch —
#        genuinely pre-existing, not introduced here. Closing it requires
#        per-invocation title/body extraction, which is a materially larger
#        change than this bug fix's scope.
#      - `--repo=owner/name` (the `=`-joined form `gh` also accepts) is not
#        recognised by either the flag-form or the api-path-form check
#        above — a write using it resolves no target at all and the hook
#        exits 0. Verified against the real dev blob: it does the same
#        (rc=0), so this is a pre-existing gap, not a regression. Not
#        fixed here — flagging it as a documented, tested gap (case 31 in
#        the test file) rather than silently leaving it undiscovered.
#      - Four further gaps, each spot-checked against the real dev blob
#        and confirmed ALLOW there too (dev, round 2, and round 3 alike —
#        none introduced or widened by this PR): a repo slug in different
#        CASE (`ME2RESH/APEXYARD`), a slug immediately followed by a shell
#        operator with no separating whitespace (`--repo owner/repo&&gh
#        ...`), a `gh api` REST path carrying a `?query` suffix, and the
#        `--repo=` equals form above. Not fixed here — one follow-up
#        ticket to cover all four, rather than four separate ones.
# ---------------------------------------------------------------------------

find_write_segment() {
  # Prints the substring of $1 starting at the leftmost recognised write
  # invocation, or nothing if none is found. Everything BEFORE that point
  # is out of scope for --repo/repos-path candidates: a flag cannot belong
  # to a gh invocation that hasn't started yet in the raw text.
  #
  # me2resh/apexyard#1068 round 3 (security review) — the anchor here used
  # to be `(^|[[:space:]])gh`, with a code comment claiming it "mirrors"
  # step 1's `\bgh` (GNU grep -E). It does NOT: `\b` is a WORD boundary — it
  # fires wherever a word character (`gh`'s `g`) is preceded by a NON-word
  # character, which includes `;`, `&`, `|`, `(`, `$` as well as
  # whitespace. `[[:space:]]` only covers the whitespace case. So step 1
  # and this anchor DISAGREED on `;gh …`, `&&gh …`, `|gh …`, and — the
  # shape that matters most, because it is a routine agent idiom, not a
  # crafted exploit — `out=$(gh …)` (capturing a created issue/PR URL).
  # Step 1 classified all four as a write (matched `\bgh`); this anchor
  # found no match, `find_write_segment` returned empty, and the hook
  # exited 0 at the empty-segment check below having scanned NOTHING.
  # Because the segment finder runs BEFORE content extraction, this also
  # silently defeated the truncation-refusal fix a few hundred lines down:
  # `out=$(gh issue create --repo pub --body "leak" && gh pr list --repo
  # other)` — which correctly REFUSES unwrapped — exits 0 once wrapped in
  # `$(...)`, because the segment is empty before extraction ever runs.
  #
  # Verified, not assumed (the mistake AgDR-0113 exists to catch, and the
  # rule extends to equivalence claims about two expressions, not only to
  # "pre-existing" claims about behaviour) — and verified with a body
  # whose leak token is NOT the first word, because an earlier check
  # against a frontloaded body ("zebrafish leak") masked the exact
  # distinction that matters here: dev has no truncation detection at
  # all, so a leak token that happens to land in the truncated fragment
  # dev DOES manage to read gets caught by accident, hiding the real gap.
  #
  # `;gh …`, `&&gh …`, `|gh …` all BLOCK on the real `upstream/dev` blob
  # and LEAKED (exit 0, nothing scanned) on the round-2 HEAD this
  # replaces — genuine regressions this fix closes.
  #
  # `out=$(gh …)` is DIFFERENT and does not fit the same sentence: it
  # ALSO leaks on dev (rc=0, "found during zebrafish rebuild" truncates to
  # "found" and the leak is never reached) — pre-existing on dev, not a
  # round-2 regression, because dev's extraction has no notion of
  # truncation failure at all. This fix still closes it, but as a
  # byproduct of the segment now being non-empty so the (round 1/2)
  # truncation-refusal mechanism gets a chance to run on it — an
  # improvement over dev's behaviour on this shape, not a restoration of
  # parity with it.
  #
  # Fix: `(^|[^A-Za-z0-9_.-])` before "gh" is a hand-rolled word boundary
  # that actually matches what `\b` matches — anything that is NOT a word
  # character (alnum, `_`) immediately before "gh", which now correctly
  # includes `;`, `&`, `|`, `(`, `$`, in addition to whitespace and start
  # of string — while still rejecting "gh" as a bare substring of an
  # unrelated word (e.g. "high api" contains the literal text "gh api" but
  # is not a gh invocation, and `h` immediately before the `g` is a word
  # character, so the boundary correctly does not fire there).
  local cmd="$1"
  printf '%s' "$cmd" | awk '
    { buf = (NR == 1 ? $0 : buf "\n" $0) }
    END {
      s = buf
      anchor_re = "(^|[^A-Za-z0-9_.-])gh[[:space:]]+(issue[[:space:]]+(create|comment)([[:space:]]|$)|pr[[:space:]]+(create|comment)([[:space:]]|$)|api([[:space:]]|$))"
      if (!match(s, anchor_re)) { exit }
      print substr(s, RSTART)
    }
  '
}

WRITE_SEGMENT=$(find_write_segment "$COMMAND")

if [ -z "$WRITE_SEGMENT" ]; then
  # No recognised write invocation found — the hook has nothing to
  # evaluate. Default gh behaviour (current-dir repo) is safe to ignore
  # here: the hook is a backstop against cross-repo leaks, not a universal
  # scrubber.
  exit 0
fi

# Sources for the public-repo list (in order):
#   1. `.claude/project-config.*.json` → `leak_protection.public_framework_repos[]`
#      (read via the shared config lib landed in apexyard#109)
#   2. Shipped default: `me2resh/apexyard`
#   3. Auto-detected: whatever the fork's `upstream` remote resolves to
#      (unless `leak_protection.auto_detect_upstream` is set to `false`).
#
# Load the shared config reader if available. The hook still works without
# it — falls through to the shipped defaults.
REPO_ROOT_FOR_CONFIG=$(git rev-parse --show-toplevel 2>/dev/null)
if [ -n "$REPO_ROOT_FOR_CONFIG" ] && [ -f "$REPO_ROOT_FOR_CONFIG/.claude/hooks/_lib-read-config.sh" ]; then
  # shellcheck disable=SC1090,SC1091
  . "$REPO_ROOT_FOR_CONFIG/.claude/hooks/_lib-read-config.sh"
  CONFIG_REPOS=$(config_get '.leak_protection.public_framework_repos[]' 2>/dev/null | tr '\n' ' ')
  AUTO_DETECT_UPSTREAM=$(config_get_or '.leak_protection.auto_detect_upstream' 'true')
fi

PUBLIC_REPOS="${CONFIG_REPOS:-me2resh/apexyard}"

if [ "${AUTO_DETECT_UPSTREAM:-true}" != "false" ]; then
  UPSTREAM_URL=$(git remote get-url upstream 2>/dev/null)
  if [ -n "$UPSTREAM_URL" ]; then
    # Parse github.com/<owner>/<repo>(.git)? from either SSH or HTTPS form.
    UPSTREAM_SLUG=$(echo "$UPSTREAM_URL" | sed -nE 's|.*github\.com[:/]([^/]+/[^/]+)(\.git)?$|\1|p' | sed -E 's/\.git$//')
    if [ -n "$UPSTREAM_SLUG" ]; then
      PUBLIC_REPOS="$PUBLIC_REPOS $UPSTREAM_SLUG"
    fi
  fi
fi

# Class-based membership check: does the write segment name ANY known
# public repo as a --repo/-R value or a repos/<owner>/<repo> path,
# anywhere? First match wins arbitrarily — it is used only for messaging
# (the ${TARGET_REPO} interpolated into the BLOCKED text below) and for
# the target's-own-name exemption in step 8; the security property here
# is the YES/NO membership test, not which specific match produced it.
#
# `-R` is `gh`'s own documented short form of `--repo` (`gh help issue
# create` lists `-R, --repo [HOST/]OWNER/REPO`), on the same footing as
# the `-t`/`-b` short forms this hook already recognises for title/body —
# so recognising it here closes an inconsistency rather than adding scope
# (me2resh/apexyard#1068 round 3).
TARGET_REPO=""
for r in $PUBLIC_REPOS; do
  esc=$(printf '%s' "$r" | sed -E 's/[][\\/.^$*+?(){}|]/\\&/g')
  # --repo/-R flag form: the slug, optionally quoted, terminated by a
  # matching quote, whitespace, or end of segment.
  if printf '%s' "$WRITE_SEGMENT" | grep -qE -- "(--repo|-R)[[:space:]]+[\"']?${esc}([\"'[:space:]]|\$)"; then
    TARGET_REPO="$r"
    break
  fi
  # gh api shape: repos/<owner>/<repo> URL path, same boundary treatment
  # plus `/` for a trailing path segment (.../issues, .../pulls).
  if printf '%s' "$WRITE_SEGMENT" | grep -qE -- "(^|[^A-Za-z0-9_.-])repos/${esc}([/[:space:]\"'>]|\$)"; then
    TARGET_REPO="$r"
    break
  fi
done

if [ -z "$TARGET_REPO" ]; then
  # No known public repo is named as this write's target — the hook has
  # nothing to evaluate.
  exit 0
fi

# ---------------------------------------------------------------------------
# 4. Locate apexyard.projects.yaml (walk up from CWD to find the fork root).
# ---------------------------------------------------------------------------

REGISTRY=""
r="$PWD"
while [ -n "$r" ] && [ "$r" != "/" ]; do
  if [ -f "$r/apexyard.projects.yaml" ]; then
    REGISTRY="$r/apexyard.projects.yaml"
    break
  fi
  parent=$(dirname "$r"); [ "$parent" = "$r" ] && break; r="$parent"
done

if [ -z "$REGISTRY" ]; then
  exit 0
fi

# ---------------------------------------------------------------------------
# 5. Extract the title + body text that will land on the public tracker.
#    Supports --title, --body, --body-file, -F, -b, -t, and `gh api`-style
#    `-F body=@file` / `-f body=...`.
# ---------------------------------------------------------------------------

extract_flag_value() {
  # $1 = python-flag regex (e.g. --title | -t). Matches (possibly multi-line):
  #   --title "value with spaces"
  #   --title 'value'
  #   --title value
  #
  # Quoted-value regex is GREEDY and anchored on the next flag boundary
  # (whitespace + `--<letter>`) or end-of-string. The earlier sed form
  # `[^"]*` truncated at the first embedded double quote
  # (me2resh/apexyard#227); for the leak-protection hook that's a real
  # security tail — a body with an embedded `"` could let private refs in
  # the back half slip past the gate. awk + greedy + boundary anchor
  # gives us multi-line consumption and correct termination in one shot.
  # $3 = trim mode. Default "last" (greedy retention, for leak DETECTION).
  # Pass "first" for the conservative subset the skip-marker check needs —
  # see the SCOPE ASYMMETRY note below.
  #
  # INVARIANT for anyone adding a caller: any consumer that makes an
  # ALLOW / bypass decision MUST pass "first". Detection consumers take the
  # default. The default is deliberately the detection-safe one, which means
  # a new allow-path caller that forgets $3 silently gets the superset — and
  # a superset is fail-OPEN in that direction. Read the asymmetry note before
  # adding a call site.
  local flag_re="$1"
  local cmd="$2"
  local mode="${3:-last}"
  printf '%s' "$cmd" | awk -v FLAG_RE="$flag_re" -v SQ="'" -v MODE="$mode" '
    # Truncate CHUNK at its LAST occurrence of delimiter D.
    #
    # A regex sub() cannot do this job (me2resh/apexyard#1046). POSIX ERE
    # substitution is leftmost-longest, so the previous
    #   sub("\"([[:space:]]+--[a-zA-Z].*)?$", "", chunk)
    # found the EARLIEST quote that happened to be followed by ` --<letter>`
    # and deleted from there to end-of-string. A body containing an embedded
    # quote and, later, any double-dash token was therefore amputated at the
    # quote, and everything after it went unscanned — a silent fail-open on a
    # leak gate. Both conditions had to co-occur, which is why the originally
    # filed single-condition repro did not reproduce.
    #
    # Scanning backwards is exact rather than heuristic: match() already
    # anchored the region on the real closing delimiter, and the only thing
    # that can follow it is the boundary ` --<letter>` or trailing space,
    # neither of which contains a delimiter. So the last D in CHUNK IS the
    # closing delimiter, including when the body legitimately ends in one.
    #
    # This deliberately does NOT touch the greedy match() anchors above it.
    # Widening those was tried in #1040 and rejected: it reopened #227 across
    # every boundary character (9 failures vs 5 — measurably worse than no
    # fix). The anchor was never the defect; the trim was.
    function trim_to_last(chunk, d,    i) {
      for (i = length(chunk); i >= 1; i--) {
        if (substr(chunk, i, 1) == d) return substr(chunk, 1, i - 1)
      }
      return chunk
    }
    # SCOPE ASYMMETRY (me2resh/apexyard#1046, caught in security review).
    #
    # Retaining a SUPERSET is fail-closed for leak DETECTION — scanning more
    # than the body can only over-block. It is fail-OPEN for the skip MARKER,
    # because a wider scan gives `<!-- private-refs: allow -->` more places to
    # be found. Concretely, `--body "<private>" --label "<marker>"` blocked
    # before this fix and bypassed after it: the greedy match legitimately
    # cannot tell where the body ends, so the marker rode in on the
    # over-capture.
    #
    # So the two consumers need opposite trims. Detection uses "last" (the
    # superset). The marker check uses "first" — the pre-fix earliest-
    # qualifying cut, which is a SUBSET and therefore fail-closed in the
    # bypass direction. "first" is deliberately the OLD, buggy-for-detection
    # behaviour: its under-capture is precisely the property that makes it
    # correct here.
    function trim_mode(chunk, d) {
      if (MODE != "first") return trim_to_last(chunk, d)
      # `--?` here, NOT `--`. A single-dash flag is the same flag: `-l` IS
      # `--label`. Keying the conservative cut on a double dash closed
      # `--label "<marker>"` and left `-l "<marker>"` open, so the subset
      # silently became a superset again for the short spellings.
      #
      # `--?` and NOT `-{1,2}`, which is what this originally used: `{n,m}`
      # is an ERE interval and awk support for it is not universal (mawk
      # 1.3.3 lacks it; BWK awk only gained it around 2019; gawk 3.x needed
      # --re-interval). Where it is unsupported the pattern is treated
      # LITERALLY, the cut then fires only at end-of-chunk, and this branch
      # silently degrades back toward the superset — reopening the very
      # bypass it exists to close, on some machines and not others. That is
      # the same silent-failure class as the bug this hook is fixing, so the
      # dependency is not worth carrying when `--?` is exactly equivalent.
      #
      # Safe by construction: a more aggressive cut yields a SMALLER subset,
      # and smaller is fail-closed for the marker consumer. This branch is
      # never reached by leak detection, which always uses "last", so it
      # cannot affect #227/#1039 behaviour.
      sub(d "([[:space:]]+--?[a-zA-Z].*)?$", "", chunk)
      sub(d "[[:space:]]*$", "", chunk)
      return chunk
    }
    { buf = (NR == 1 ? $0 : buf "\n" $0) }
    END {
      s = buf
      # Double-quoted value: greedy `(.*)` anchored on next flag or EOS.
      re = "(" FLAG_RE ")[[:space:]]+\"(.*)\"([[:space:]]+--[a-zA-Z]|[[:space:]]*$)"
      if (match(s, re)) {
        chunk = substr(s, RSTART, RLENGTH)
        sub("^(" FLAG_RE ")[[:space:]]+\"", "", chunk)
        print trim_mode(chunk, "\"")
        exit
      }
      # Single-quoted value: same greedy + anchor treatment. This branch had
      # the identical leftmost-longest defect and is fixed the same way; it is
      # not mentioned in #1046 but leaks on the single-quoted equivalent of the
      # same command shape.
      re = "(" FLAG_RE ")[[:space:]]+" SQ "(.*)" SQ "([[:space:]]+--[a-zA-Z]|[[:space:]]*$)"
      if (match(s, re)) {
        chunk = substr(s, RSTART, RLENGTH)
        sub("^(" FLAG_RE ")[[:space:]]+" SQ, "", chunk)
        print trim_mode(chunk, SQ)
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

# extract_path_flag FLAG_RE COMMAND  (me2resh/apexyard#1039)
#
# A PATH-valued flag is not a CONTENT-valued flag, and they need opposite
# parsing strategies. Conflating them is what caused #1039:
#
#   CONTENT (--title / --body): may be multi-line and may contain literally
#     anything — quotes, pipes, semicolons, markdown tables. Extraction must
#     be GREEDY and terminate only on a real flag boundary, or an embedded
#     quote truncates the body and the tail goes unscanned. That is exactly
#     the leak #227 fixed, so extract_flag_value above stays as it is.
#
#   PATH (--body-file / -F): a filesystem path. It never contains a quote
#     character, so extraction must be NON-GREEDY — stop at the FIRST
#     closing quote. Greedy matching over a path is what made
#     `--body-file "/p/b.md" 2>&1 | tail` fall through to the unquoted
#     branch and come back as `"/p/b.md"`, quotes attached. `[ -f ]` was
#     then false, the body was never read, and this hook exits 0 on an
#     empty scan — a silent leak.
#
# An earlier attempt at #1039 widened extract_flag_value's anchor to accept
# shell operators. That fixed the path case and BROKE the content case:
# `sub()` is leftmost-first and each alternative ends in `.*`, so a body
# containing a quote followed by ` |` truncated there. A markdown table row
# ending in a quoted term is exactly that shape — and a Glossary table is
# mandatory in this framework's own issue bodies. Splitting the two
# extractors is the correct fix; widening the shared one is not.
#
# Non-greedy `[^"]*` here is safe precisely because paths cannot contain
# quotes — the same construct that was WRONG for content.
extract_path_flag() {
  local flag_re="$1"
  local cmd="$2"
  printf '%s' "$cmd" | awk -v FLAG_RE="$flag_re" -v SQ="'" '
    { buf = (NR == 1 ? $0 : buf "\n" $0) }
    END {
      s = buf
      # Double-quoted path: stop at the first closing quote. Allows spaces
      # in the path; a quote inside a path is not a supported shape.
      re = "(" FLAG_RE ")[[:space:]]+\"[^\"]*\""
      if (match(s, re)) {
        chunk = substr(s, RSTART, RLENGTH)
        sub("^(" FLAG_RE ")[[:space:]]+\"", "", chunk)
        sub("\"$", "", chunk)
        print chunk
        exit
      }
      # Single-quoted path: same treatment.
      re = "(" FLAG_RE ")[[:space:]]+" SQ "[^" SQ "]*" SQ
      if (match(s, re)) {
        chunk = substr(s, RSTART, RLENGTH)
        sub("^(" FLAG_RE ")[[:space:]]+" SQ, "", chunk)
        sub(SQ "$", "", chunk)
        print chunk
        exit
      }
      # Unquoted path: a single whitespace-delimited token.
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

# ---------------------------------------------------------------------------
# me2resh/apexyard#1068 (follow-on) — a chained shell command (or a trailing
# comment) after a quoted --title/--body value has no representation in
# extract_flag_value's greedy match(): the closing quote is real (there is
# no other quote to try), but what follows it is neither a real `--flag`
# nor end-of-string, so BOTH quoted branches fail to match at all. The
# function then falls through to the UNQUOTED branch, which greedily grabs
# the leading quote character plus exactly one whitespace-delimited token
# — e.g. `--body "found during zebrafish rebuild" && gh pr list --repo x`
# silently returns `"found` as the body. The truncation looks like ordinary
# (non-empty) content, so nothing downstream flags it, and the hook would
# scan a haystack missing everything after the first word.
#
# This was reachable only once the TARGET_REPO fix above stopped the hook
# from exiting at step 3 on these exact commands — before that fix, a
# chained/trailing `--repo` always mis-resolved the target as non-public
# and the hook never reached content extraction at all.
#
# Widening extract_flag_value's terminator set to recognise shell operators
# was tried and rejected for the sibling bug this same file documents
# above (#1040 reopened #227; the #1039r2 tests a few hundred lines down
# assert that a LONE `|`, `;`, `&`, etc. embedded in legitimate body prose
# must NOT be treated as a terminator). Anything general enough to accept
# "a new command starts here" is exactly as good at truncating a body that
# legitimately contains that same text as prose. So this does not attempt
# to parse the chain — it detects the FAILURE signature structurally
# instead: a value returned by extract_flag_value can begin with a raw `"`
# or `'` ONLY via this unquoted fallback firing on a quote-opened value it
# could not safely close. Refuse rather than scan a haystack known to be
# truncated — same fail-closed shape as BODY_FILE_UNREADABLE below, and
# the same "over-block, never silently scan nothing" instruction #1068
# gave for this whole fix.
#
# Why this check is sound rather than another AgDR-0104 pattern guess (a
# distinction raised in code review and worth stating explicitly): it
# detects the FAILURE, not the ATTACK. Both quoted branches in
# extract_flag_value strip their own opening delimiter before returning —
# look at the `sub(/^--title[[:space:]]+"/, ...)` / `sub("^--body...` calls
# above — so a successful quoted-branch match can NEVER hand back a value
# starting with a raw quote character. A leading raw quote is therefore
# structurally unreachable through the success path; it is an INVARIANT of
# the extractor (only the degenerate unquoted fallback can produce it),
# not a heuristic guess about what a bypass attempt looks like in command
# text. That is the same reason this hook does not try to name which
# specific project leaked when it hits this branch: fabricating a
# "project name: X" from content it never actually finished reading would
# be indistinguishable, in an audit trail, from a real detection. Refusing
# to claim a specific finding it cannot back is the more honest posture
# when the read itself is known-incomplete.
case "$TITLE" in
  \"*|\'*) TITLE_TRUNCATED=1 ;;
  *) TITLE_TRUNCATED=0 ;;
esac
case "$BODY" in
  \"*|\'*) BODY_TRUNCATED=1 ;;
  *) BODY_TRUNCATED=0 ;;
esac

if [ "$TITLE_TRUNCATED" -eq 1 ] || [ "$BODY_TRUNCATED" -eq 1 ]; then
  cat >&2 <<EOF
======================================================================
[apexyard] BLOCKED: could not safely determine where a --title/--body value ends
======================================================================

This command targets a PUBLIC framework repo (${TARGET_REPO}), but a
quoted --title or --body value is followed by text this hook does not
recognise as a valid terminator (a real flag, or end of command).

The most likely cause: a second command chained after the write with
&& / ; / |, or a trailing shell comment (me2resh/apexyard#1068). Example:

  gh issue create --repo ${TARGET_REPO} --title "T" --body "..." && gh pr list --repo other/repo

Extraction cannot safely tell where the quoted value ends in that shape,
so it refuses rather than scan a value it cannot rule out is truncated.

Fix: run the write as its own, unchained Bash call.
======================================================================
EOF
  exit 2
fi

# Conservative (subset) extraction, used ONLY for the skip-marker check in
# step 6. See the SCOPE ASYMMETRY note in extract_flag_value: the greedy
# extraction above is fail-closed for detection but fail-OPEN for the bypass
# marker, because over-capture hands the marker extra places to appear.
TITLE_STRICT=$(extract_flag_value '--title|-t' "$COMMAND" first)
BODY_STRICT=$(extract_flag_value '--body|-b' "$COMMAND" first)

# --body-file <path> / -F <path> (only when -F's value is NOT a key=val pair,
# because `gh api -F body=@file` uses the same flag letter).
# #1039: a path, so use the non-greedy path extractor — NOT the greedy
# content extractor above, whose flag-boundary anchor cannot terminate a
# quoted path followed by a shell operator.
BODY_FILE=$(extract_path_flag '--body-file' "$COMMAND")
if [ -z "$BODY_FILE" ]; then
  # gh pr create / gh issue create: -F <path>
  F_VAL=$(echo "$COMMAND" | sed -nE "s/.*(^|[[:space:]])-F[[:space:]]+\"([^\"]*)\".*/\2/p" | head -1)
  if [ -z "$F_VAL" ]; then
    F_VAL=$(echo "$COMMAND" | sed -nE "s/.*(^|[[:space:]])-F[[:space:]]+'([^']*)'.*/\2/p" | head -1)
  fi
  if [ -z "$F_VAL" ]; then
    F_VAL=$(echo "$COMMAND" | sed -nE "s/.*(^|[[:space:]])-F[[:space:]]+([^[:space:]]+).*/\2/p" | head -1)
  fi
  # Only treat as a body-file path if it does NOT look like key=value.
  if [ -n "$F_VAL" ] && ! echo "$F_VAL" | grep -q '='; then
    BODY_FILE="$F_VAL"
  fi
fi

# #1039 — DISTINGUISH "no body-file" FROM "body-file I could not read".
#
# These used to share a code path: an unreadable path left the content
# empty, and the empty-haystack short-circuit below then exited 0. That
# made every parsing gap a SILENT LEAK — the operator saw a successful
# `gh issue create` with no sign the scan had been skipped.
#
# Defence in depth, and the more important half of this fix: the path
# extractor above closes the shapes we know about, this makes the whole
# CLASS fail closed. A future parsing gap blocks loudly instead of leaking.
BODY_FILE_CONTENT=""
BODY_FILE_UNREADABLE=0
if [ -n "$BODY_FILE" ]; then
  if [ -f "$BODY_FILE" ]; then
    BODY_FILE_CONTENT=$(cat "$BODY_FILE" 2>/dev/null)
    # Readable-but-unslurpable (permissions, race): treat as unreadable.
    if [ -z "$BODY_FILE_CONTENT" ] && [ -s "$BODY_FILE" ]; then
      BODY_FILE_UNREADABLE=1
    fi
  else
    BODY_FILE_UNREADABLE=1
  fi
fi

# `gh api` body field: -F body=@file or -f body='text' or -F body='text'.
#
# me2resh/apexyard#1070 — this block also now:
#   1. recognises the LONG forms of -f/-F — `--raw-field` (alias of -f) and
#      `--field` (alias of -F). `gh api --help` documents both pairs as
#      exact equivalents; a hook that only knows the short spelling has a
#      trivially-taken bypass (an operator, or an agent that copies an
#      example straight out of `gh api --help`, spells it out in full). Same
#      class of gap `-R`/`--repo` closed in #1068 round 3 above.
#   2. fails CLOSED on `-F/--field body=@<path>` when the path is not a
#      readable file, mirroring the `--body-file` fix from #1039 exactly —
#      that shape used to fall through to the literal-`body=` branch below,
#      which cannot match a `body=@path` token either, so API_BODY stayed
#      empty and the write fell open at the empty-haystack short-circuit.
#   3. fails CLOSED on `--input <file>` / `--input -` outright, rather than
#      attempting to parse it. `--input` replaces the ENTIRE request body:
#      `--input -` reads from STDIN, which is invisible to a PreToolUse hook
#      (it only ever sees the command string), and `--input <file>` hands
#      gh a raw JSON (or other) payload rather than one known field, so
#      pulling `body`/`title` out of it correctly means parsing an
#      arbitrary, endpoint-specific document — exactly the "enumerate one
#      more shape" treadmill AgDR-0104 says command-text matching cannot
#      win. No attempt is made to distinguish the two cases; both are
#      content this hook cannot honestly claim to have scanned, so both
#      refuse rather than publish unscanned.
API_BODY=""
API_BODY_UNREADABLE=0
API_INPUT_UNPARSEABLE=0
if [ "$IS_GH_API" -eq 1 ]; then
  if echo "$COMMAND" | grep -qE -- '(^|[[:space:]])--input([[:space:]]|=)'; then
    API_INPUT_UNPARSEABLE=1
  fi

  # Handle -F/--field body=@<path> (file ref) and -f/-F/--raw-field/--field
  # body=<literal>.
  API_BODY_PATH=$(echo "$COMMAND" | sed -nE "s/.*(-F|--field)[[:space:]]+body=@([^[:space:]\"']+).*/\2/p" | head -1)
  if [ -n "$API_BODY_PATH" ]; then
    if [ -f "$API_BODY_PATH" ]; then
      API_BODY=$(cat "$API_BODY_PATH" 2>/dev/null)
      # Readable-but-unslurpable (permissions, race): treat as unreadable,
      # same guard #1039 uses for BODY_FILE_UNREADABLE below.
      if [ -z "$API_BODY" ] && [ -s "$API_BODY_PATH" ]; then
        API_BODY_UNREADABLE=1
      fi
    else
      API_BODY_UNREADABLE=1
    fi
  else
    # Literal body=... — may be quoted. Strip surrounding quotes.
    API_BODY=$(echo "$COMMAND" | sed -nE "s/.*(-f|-F|--field|--raw-field)[[:space:]]+body=\"([^\"]*)\".*/\2/p" | head -1)
    if [ -z "$API_BODY" ]; then
      API_BODY=$(echo "$COMMAND" | sed -nE "s/.*(-f|-F|--field|--raw-field)[[:space:]]+body='([^']*)'.*/\2/p" | head -1)
    fi
    if [ -z "$API_BODY" ]; then
      API_BODY=$(echo "$COMMAND" | sed -nE "s/.*(-f|-F|--field|--raw-field)[[:space:]]+body=([^[:space:]]+).*/\2/p" | head -1)
    fi
  fi

  # Also pick up a `title` field on api-shape issue creation.
  if [ -z "$TITLE" ]; then
    API_TITLE=$(echo "$COMMAND" | sed -nE "s/.*(-f|-F|--field|--raw-field)[[:space:]]+title=\"([^\"]*)\".*/\2/p" | head -1)
    if [ -z "$API_TITLE" ]; then
      API_TITLE=$(echo "$COMMAND" | sed -nE "s/.*(-f|-F|--field|--raw-field)[[:space:]]+title='([^']*)'.*/\2/p" | head -1)
    fi
    if [ -z "$API_TITLE" ]; then
      API_TITLE=$(echo "$COMMAND" | sed -nE "s/.*(-f|-F|--field|--raw-field)[[:space:]]+title=([^[:space:]]+).*/\2/p" | head -1)
    fi
    TITLE="$API_TITLE"
  fi
fi

# Concatenate all candidate text. A newline between each part keeps
# line-anchored regexes honest.
HAYSTACK=$(printf '%s\n%s\n%s\n%s\n' "$TITLE" "$BODY" "$BODY_FILE_CONTENT" "$API_BODY")

# #1039 — a body-file was named but could not be read. Refuse rather than
# scan an empty haystack: we cannot call the content clean when we never
# saw it, and this hook writes to a PUBLIC tracker. Checked BEFORE the
# empty-input short-circuit below, which would otherwise swallow this case.
if [ "$BODY_FILE_UNREADABLE" -eq 1 ]; then
  cat >&2 <<EOF
======================================================================
[apexyard] BLOCKED: body-file named but not readable
======================================================================

  --body-file / -F path: ${BODY_FILE}

This command targets a PUBLIC framework repo, but the body file could not
be read, so its contents were never scanned for private project
references. Allowing the write would mean asserting the body is clean
without having looked at it.

Common causes:
  - the path does not exist, or is relative to a different directory
  - a typo in the path
  - the file is written in a LATER tool call than the one running this
    command (a PreToolUse hook blocks the whole call, so a heredoc that
    creates the file alongside the gh command never runs)

Fix the path and retry — that is the only way past this block.

The <!-- private-refs: allow --> skip marker does NOT apply here, and
earlier versions of this message wrongly suggested it did. That marker is
read out of body content this hook has actually scanned; it cannot be read
out of a file that could not be opened. There is deliberately no bypass for
an unreadable body: the marker means "I looked, and this reference is
intentional", which is not a claim anyone can make about unread bytes.
======================================================================
EOF
  exit 2
fi

# me2resh/apexyard#1070 — `gh api ... --input <file|->` replaces the ENTIRE
# request body with content this hook does not parse (see the comment above
# where API_INPUT_UNPARSEABLE is set, near the top of the IS_GH_API block).
# Checked BEFORE the empty-haystack short-circuit below, same placement as
# BODY_FILE_UNREADABLE just above and for the identical reason: an empty
# HAYSTACK must never read as "scanned clean" when it is actually "never
# looked at".
if [ "$API_INPUT_UNPARSEABLE" -eq 1 ]; then
  cat >&2 <<EOF
======================================================================
[apexyard] BLOCKED: gh api --input body cannot be scanned
======================================================================

This command targets a PUBLIC framework repo (${TARGET_REPO}) and supplies
its request body via --input, which this hook does not parse.

  - --input - reads the body from STDIN, which a PreToolUse hook cannot
    see at all — it only ever sees the command string.
  - --input <file> reads the body from a file, but the content is a raw
    JSON (or other) request payload rather than one known field —
    correctly pulling a body/title string out of it would mean parsing an
    arbitrary, endpoint-specific document, which this hook does not
    attempt (see docs/agdr/AgDR-0104-trust-chain-controls-vs-backstops.md:
    pattern-matching command text cannot be made sound by enumerating ever
    more shapes).

This command is refused rather than published unscanned. Fix: use
--title/--body/--body-file, or -f/-F (and their --raw-field/--field long
forms) instead of --input.

The <!-- private-refs: allow --> skip marker does NOT apply here, for the
same reason it does not apply to an unreadable --body-file: it can only be
honoured for content this hook has actually read.
======================================================================
EOF
  exit 2
fi

# me2resh/apexyard#1070 — a `-F/--field body=@<path>` was named but could not
# be read. Same fail-closed posture as BODY_FILE_UNREADABLE above (#1039):
# checked before the empty-haystack short-circuit, so a missing/unreadable
# file blocks loudly instead of silently scanning nothing (the shape used to
# fall through to the literal-body branch, which cannot match `body=@path`
# either, leaving API_BODY empty and the write open at that short-circuit).
if [ "$API_BODY_UNREADABLE" -eq 1 ]; then
  cat >&2 <<EOF
======================================================================
[apexyard] BLOCKED: gh api body=@file named but not readable
======================================================================

  body=@ path: ${API_BODY_PATH}

This command targets a PUBLIC framework repo (${TARGET_REPO}), but the
referenced body file could not be read, so its contents were never scanned
for private project references. Allowing the write would mean asserting the
body is clean without having looked at it.

Fix the path and retry — that is the only way past this block.

The <!-- private-refs: allow --> skip marker does NOT apply here, for the
same reason it does not apply to an unreadable --body-file (#1039): it can
only be honoured for content this hook has actually read.
======================================================================
EOF
  exit 2
fi

# Short-circuit on truly empty input (no title + no body + no files). This is
# deliberate: `gh issue comment <n>` with no -b / -F triggers gh's editor and
# the hook has nothing to scan.
if [ -z "$(echo "$HAYSTACK" | tr -d '[:space:]')" ]; then
  exit 0
fi

# ---------------------------------------------------------------------------
# 6. Skip marker — lets a deliberate reference through (rare).
# ---------------------------------------------------------------------------

SKIP_MARKER=$(config_get_or '.leak_protection.skip_marker' '<!-- private-refs: allow -->' 2>/dev/null)
# Fallback if the config lib didn't source successfully (e.g. on a bare
# checkout predating apexyard#109).
SKIP_MARKER="${SKIP_MARKER:-<!-- private-refs: allow -->}"
# Grep the CONSERVATIVE haystack, not the greedy one. A marker found only in
# over-captured content (e.g. a subsequent `--label "<marker>"`) must not
# bypass the gate — the operator has to put it in the title or body they are
# actually publishing. Body-file and gh-api content are read from a file /
# discrete field, so they carry no over-capture risk and are included as-is.
MARKER_HAYSTACK=$(printf '%s\n%s\n%s\n%s\n' "$TITLE_STRICT" "$BODY_STRICT" "$BODY_FILE_CONTENT" "$API_BODY")
if echo "$MARKER_HAYSTACK" | grep -qF -- "$SKIP_MARKER"; then
  echo "WARN: private-refs: allow marker present — leak-protection hook bypassed for this ${TARGET_REPO} call. See .claude/rules/leak-protection.md." >&2
  exit 0
fi

# ---------------------------------------------------------------------------
# 7. Extract the scrub list from apexyard.projects.yaml — per-project
#    `name`, `repo`/`repos`, and `workspace`. awk fallback mirrors the one
#    used by /start-ticket (see .claude/skills/start-ticket/SKILL.md) — we
#    do not depend on yq because many forks won't have it installed.
#
#    me2resh/apexyard#1123 — a project may declare a PLURAL `repos:` list
#    (a product split across several repos, governed as one thing) instead
#    of the singular `repo:`. Before this fix, only `repo:` was read, so a
#    multi-repo project's non-primary repos were silently absent from the
#    scrub list — exactly the disclosure gap #1123 exists to close. Every
#    repo in a project's `repos:` list is now scrubbed, on the same footing
#    as `repo:`. `primary:` is irrelevant here on purpose: leak protection
#    must not privilege one repo over the others — ALL of them are private
#    identifiers that must not leak onto a public tracker.
#
#    The awk state machine below distinguishes a `repos:` block list from
#    OTHER block lists in the same entry (`tags:`, `roles:`) via a
#    `current_list` tracker: a `repos:` header (with no inline value) arms
#    it, any OTHER `key:` line (scalar or another list header) disarms it.
#    Without this, `tags:\n  - customer-facing` would be misread as a repo.
#    Both YAML shapes are supported: a block list (repos:\n  - a\n  - b)
#    and a flow list (repos: [a, b]), the latter for parity with the
#    existing hostnames:/topics: flow-list convention in
#    _lib-multi-repo-trace.sh.
# ---------------------------------------------------------------------------

NAMES=""
REPOS=""
WORKSPACES=""

# awk parser: walk each `- name:` block and pull out `name`, every `repo`/
# `repos[]` entry, and `workspace`. Strips surrounding quotes. Assumes
# `- name:` is the first key in each project entry (same assumption as
# /start-ticket).
PARSED=$(awk '
  function unquote(s) { gsub(/^["\x27]|["\x27]$/, "", s); return s }
  /^[[:space:]]*- name:/ {
    print "NAME=" unquote($3)
    current_list = ""
    next
  }
  /^[[:space:]]*repo:/ {
    print "REPO=" unquote($2)
    current_list = ""
    next
  }
  /^[[:space:]]*workspace:/ {
    print "WORKSPACE=" unquote($2)
    current_list = ""
    next
  }
  /^[[:space:]]*repos:[[:space:]]*\[/ {
    line = $0
    sub(/^[^\[]*\[/, "", line); sub(/\].*$/, "", line)
    n = split(line, parts, ",")
    for (i = 1; i <= n; i++) {
      item = parts[i]
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", item)
      if (item != "") print "REPO=" unquote(item)
    }
    current_list = ""
    next
  }
  /^[[:space:]]*repos:[[:space:]]*(#.*)?$/ {
    current_list = "repos"
    next
  }
  /^[[:space:]]*[a-zA-Z_][a-zA-Z0-9_-]*:/ {
    current_list = ""
    next
  }
  /^[[:space:]]*-[[:space:]]+/ {
    if (current_list == "repos") {
      item = $0
      sub(/^[[:space:]]*-[[:space:]]+/, "", item)
      gsub(/[[:space:]]+$/, "", item)
      print "REPO=" unquote(item)
    }
    next
  }
' "$REGISTRY")

while IFS= read -r line; do
  case "$line" in
    NAME=*)
      v=${line#NAME=}
      [ -n "$v" ] && NAMES="$NAMES $v"
      ;;
    REPO=*)
      v=${line#REPO=}
      [ -n "$v" ] && REPOS="$REPOS $v"
      ;;
    WORKSPACE=*)
      v=${line#WORKSPACE=}
      [ -n "$v" ] && WORKSPACES="$WORKSPACES $v"
      ;;
  esac
done <<EOF
$PARSED
EOF

# ---------------------------------------------------------------------------
# 8. Build the match list.
#
#   - `name` → whole-word match (grep -wE). Skip the target's own name, and
#     skip names that collide with the target repo's own name, so mentioning
#     "apexyard" in an apexyard upstream ticket is fine. Also skip the name
#     whose `repo:` matches $TARGET_REPO (belt-and-braces).
#   - `repo` slug → exact match, with optional `#<N>` suffix.
#   - `workspace` path → whole-word match.
# ---------------------------------------------------------------------------

# Derive the target's bare repo name for exemption (e.g. "apexyard" from
# "me2resh/apexyard").
TARGET_NAME=$(echo "$TARGET_REPO" | awk -F/ '{print $NF}')

LEAKS=""

# Reusable matcher: given a pattern regex, if it fires against HAYSTACK,
# append the token to LEAKS with a labelled prefix.
record_if_match() {
  local label="$1"
  local token="$2"
  local regex="$3"
  if echo "$HAYSTACK" | grep -qE "$regex"; then
    LEAKS="$LEAKS
  - ${label}: ${token}"
  fi
}

for n in $NAMES; do
  # Exempt the target repo's own name.
  if [ "$n" = "$TARGET_NAME" ]; then continue; fi
  # Whole-word, case-insensitive. Escape regex-special chars in $n.
  esc=$(printf '%s' "$n" | sed -E 's/[][\\/.^$*+?(){}|]/\\&/g')
  if echo "$HAYSTACK" | grep -qiwE "$esc"; then
    LEAKS="$LEAKS
  - project name: $n"
  fi
done

for rp in $REPOS; do
  if [ "$rp" = "$TARGET_REPO" ]; then continue; fi
  esc=$(printf '%s' "$rp" | sed -E 's/[][\\/.^$*+?(){}|]/\\&/g')
  # Either bare slug (with word-ish boundary) or slug#<N>.
  if echo "$HAYSTACK" | grep -qiE "(^|[^A-Za-z0-9_/-])${esc}(#[0-9]+)?([^A-Za-z0-9_/-]|$)"; then
    LEAKS="$LEAKS
  - project repo: $rp"
  fi
done

for ws in $WORKSPACES; do
  esc=$(printf '%s' "$ws" | sed -E 's/[][\\/.^$*+?(){}|]/\\&/g')
  # Workspace-path boundaries: path-chars `/` and `-` ARE allowed *after* the
  # match (e.g. `workspace/ws-marlow/app.ts` is a real reference — the
  # trailing `/` marks a sub-path, not a suffix extension of the token). The
  # leading boundary rejects alphanumeric/underscore/- to avoid matching
  # inside another token like `myworkspace/ws-marlow`.
  if echo "$HAYSTACK" | grep -qE "(^|[^A-Za-z0-9_-])${esc}([^A-Za-z0-9_-]|$)"; then
    LEAKS="$LEAKS
  - workspace path: $ws"
  fi
done

if [ -z "$LEAKS" ]; then
  exit 0
fi

# ---------------------------------------------------------------------------
# 9. Block with a message that names each leaked token and suggests abstract
#    replacement phrasing.
# ---------------------------------------------------------------------------

cat >&2 <<MSG
BLOCKED: private project reference detected in ${TARGET_REPO} (public framework repo).

Leaked tokens (from your fork's apexyard.projects.yaml):${LEAKS}

Why this is blocked:
  Public-framework issues are indexed and searchable forever. Referencing
  a registered private project by name, repo slug, or workspace path
  publishes that project's existence on a public tracker — usually not
  what you want.

Rewrite with abstract phrasing. Examples:
  "discovered during <private-project> rebuild"
    → "discovered during a managed-project rebuild"
  "same as <owner/repo>#42"
    → "same as a registered project's migration ticket"
  "in workspace/<private-project>/"
    → "in one of the registered project workspaces"

Escape hatch (rare — only when an upstream ticket legitimately needs to
reference a registered project by name):
  Add this HTML comment anywhere in the body:
    ${SKIP_MARKER}

See .claude/rules/leak-protection.md for the full rationale.
MSG

# Diagnostic for the one confusing case: the marker IS somewhere in the
# command, but not where it counts. Without this the operator reads the
# escape-hatch advice above, adds the marker, is blocked again, and has no
# way to tell why — they go hunting for a typo in a marker that is
# demonstrably present. Both haystacks already exist, so this costs a grep.
#
# It fires when the marker is in the greedy haystack but not the conservative
# one: either it sat past the `first`-mode cut inside the body, or it was in a
# later flag value (`--label`/`-l`) that only over-capture ever surfaced.
if echo "$HAYSTACK" | grep -qF -- "$SKIP_MARKER" 2>/dev/null; then
  cat >&2 <<'DIAG'

NOTE: the skip marker IS present in this command, but not in a position
that counts, so it did not apply.

The reliable placement is --body-file: it is read whole, with none of the
restrictions below. Prefer it.

--title and --body both work, but only BEFORE any embedded quote that is
followed by a flag-shaped token. Past that point the value is cut short
and a marker there is not seen — in the title exactly as in the body.

A marker in a later flag value (--label / -l / --assignee / -a) is
deliberately ignored: it is not part of what gets published, and honouring
it there would let the bypass ride in on a parsing artefact rather than on
something you actually wrote into the ticket.
DIAG
fi

exit 2
