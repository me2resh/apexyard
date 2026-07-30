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
# 2. Resolve the target repo.
#    - From `--repo owner/name` for the subcommand shape.
#    - From the URL path for the api shape: `gh api repos/<owner>/<repo>/...`.
#
#    Anchored on the matched WRITE invocation (me2resh/apexyard#1068).
#
#    The previous implementation was a single greedy sed match:
#        sed -nE 's/.*--repo[[:space:]]+.../\1/p'
#    The leading `.*` is greedy, and POSIX substitution finds the leftmost
#    STARTING position where the whole pattern can match (position 0) then
#    extends `.*` as far right as it can while still allowing `--repo` to
#    match somewhere after it. With more than one `--repo` token on the
#    line, that binds the LAST one, not the one belonging to the write —
#    so a chained second `gh` call, or even a bare trailing shell comment
#    mentioning `--repo`, silently resolved to the wrong target and the
#    hook exited 0 at step 3 before extracting anything. `| head -1`
#    de-dupes matched LINES, not matches within a line, so it did not help.
#
#    The fix: find the leftmost occurrence of one of the five recognised
#    write shapes (`gh issue create`, `gh pr create`, `gh issue comment`,
#    `gh pr comment`, `gh api`), then take the FIRST `--repo` value (or,
#    for the api shape, the first `repos/<owner>/<repo>` path) found AFTER
#    that anchor — not the last one anywhere on the line. This is
#    structural (anchored on the matched invocation) rather than a tighter
#    pattern, which is the direction #1040 tried and measurably regressed
#    (see extract_flag_value's history below).
#
#    Deliberately NOT done: truncating the search region at the next shell
#    operator (&&, ||, ;, |, #). A value like `--body "a | b"` legitimately
#    contains those characters inside quotes, and a naive cut there would
#    silently stop the scan before reaching a --repo that legitimately
#    appears later in the same, single, unchained command — trading one
#    silent-leak shape for another. Taking the first match after the
#    anchor, with no upper bound, avoids that trade entirely.
#
#    Residual (documented, not solved here — command-text matching cannot
#    be made fully sound per AgDR-0104):
#      - Two REAL writes chained to DIFFERENT repos in one Bash call
#        resolve only the FIRST — a pre-existing limitation TITLE/BODY
#        extraction below already has (it has always read the first
#        occurrence across the whole command, never per-invocation).
#      - A `--repo` token embedded inside an EARLIER flag's quoted value
#        (e.g. inside `--title`) that textually precedes the real `--repo`
#        flag can still be picked up first. This requires deliberately
#        crafting the command against its own safety hook, is narrower and
#        more contrived than the reported bypass (which needed no quoting
#        trickery at all), and is a pre-existing weakness of the previous
#        implementation too — not something this fix introduces.
# ---------------------------------------------------------------------------

find_target_repo() {
  local cmd="$1"
  printf '%s' "$cmd" | awk -v SQ="'" '
    function extract_repo_after(rest,    re, chunk) {
      # Double-quoted value.
      re = "--repo[[:space:]]+\"([^\"]*)\""
      if (match(rest, re)) {
        chunk = substr(rest, RSTART, RLENGTH)
        sub(/^--repo[[:space:]]+"/, "", chunk)
        sub(/"$/, "", chunk)
        return chunk
      }
      # Single-quoted value.
      re = "--repo[[:space:]]+" SQ "([^" SQ "]*)" SQ
      if (match(rest, re)) {
        chunk = substr(rest, RSTART, RLENGTH)
        sub("^--repo[[:space:]]+" SQ, "", chunk)
        sub(SQ "$", "", chunk)
        return chunk
      }
      # Unquoted value: single whitespace-delimited token.
      re = "--repo[[:space:]]+[^[:space:]]+"
      if (match(rest, re)) {
        chunk = substr(rest, RSTART, RLENGTH)
        sub(/^--repo[[:space:]]+/, "", chunk)
        return chunk
      }
      return ""
    }
    { buf = (NR == 1 ? $0 : buf "\n" $0) }
    END {
      s = buf
      # Leftmost occurrence of a recognised write shape. `(^|[[:space:]])`
      # before "gh" and a trailing boundary after the keyword keep this
      # from matching "gh" as a bare substring of an unrelated word (e.g.
      # "high api" contains the literal text "gh api" but is not a gh
      # invocation) — mirroring the `\b` word-boundary the step-1
      # classification regex already relies on (GNU grep -E extension; not
      # available inside awk EREs, so reproduced explicitly here).
      anchor_re = "(^|[[:space:]])gh[[:space:]]+(issue[[:space:]]+(create|comment)([[:space:]]|$)|pr[[:space:]]+(create|comment)([[:space:]]|$)|api([[:space:]]|$))"
      if (!match(s, anchor_re)) { exit }
      rest = substr(s, RSTART)
      r = extract_repo_after(rest)
      if (r != "") { print r; exit }
      # gh api shape: first `repos/<owner>/<repo>` path AFTER the anchor.
      # Accepts both `repos/owner/repo/...` and `/repos/owner/repo/...`.
      path_re = "/?repos/[^/[:space:]\"" SQ "]+/[^/[:space:]\"" SQ "]+"
      if (match(rest, path_re)) {
        chunk = substr(rest, RSTART, RLENGTH)
        sub(/^\/?repos\//, "", chunk)
        print chunk
        exit
      }
    }
  '
}

TARGET_REPO=$(find_target_repo "$COMMAND")

if [ -z "$TARGET_REPO" ]; then
  # No target repo resolvable — the hook has nothing to evaluate. Default
  # gh behaviour (current-dir repo) is safe to ignore here: the hook is a
  # backstop against cross-repo leaks, not a universal scrubber.
  exit 0
fi

# ---------------------------------------------------------------------------
# 3. Determine whether the target is public / framework-class.
#    Sources (in order):
#      1. `.claude/project-config.*.json` → `leak_protection.public_framework_repos[]`
#         (read via the shared config lib landed in apexyard#109)
#      2. Shipped default: `me2resh/apexyard`
#      3. Auto-detected: whatever the fork's `upstream` remote resolves to
#         (unless `leak_protection.auto_detect_upstream` is set to `false`).
# ---------------------------------------------------------------------------

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

IS_PUBLIC_TARGET=0
for r in $PUBLIC_REPOS; do
  if [ "$TARGET_REPO" = "$r" ]; then
    IS_PUBLIC_TARGET=1
    break
  fi
done

if [ "$IS_PUBLIC_TARGET" -eq 0 ]; then
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
API_BODY=""
if [ "$IS_GH_API" -eq 1 ]; then
  # Handle -F body=@<path> (file ref) and -f/-F body=<literal>.
  API_BODY_PATH=$(echo "$COMMAND" | sed -nE "s/.*-F[[:space:]]+body=@([^[:space:]\"']+).*/\1/p" | head -1)
  if [ -n "$API_BODY_PATH" ] && [ -f "$API_BODY_PATH" ]; then
    API_BODY=$(cat "$API_BODY_PATH" 2>/dev/null)
  else
    # Literal body=... — may be quoted. Strip surrounding quotes.
    API_BODY=$(echo "$COMMAND" | sed -nE "s/.*-[fF][[:space:]]+body=\"([^\"]*)\".*/\1/p" | head -1)
    if [ -z "$API_BODY" ]; then
      API_BODY=$(echo "$COMMAND" | sed -nE "s/.*-[fF][[:space:]]+body='([^']*)'.*/\1/p" | head -1)
    fi
    if [ -z "$API_BODY" ]; then
      API_BODY=$(echo "$COMMAND" | sed -nE "s/.*-[fF][[:space:]]+body=([^[:space:]]+).*/\1/p" | head -1)
    fi
  fi

  # Also pick up a `title` field on api-shape issue creation.
  if [ -z "$TITLE" ]; then
    API_TITLE=$(echo "$COMMAND" | sed -nE "s/.*-[fF][[:space:]]+title=\"([^\"]*)\".*/\1/p" | head -1)
    if [ -z "$API_TITLE" ]; then
      API_TITLE=$(echo "$COMMAND" | sed -nE "s/.*-[fF][[:space:]]+title='([^']*)'.*/\1/p" | head -1)
    fi
    if [ -z "$API_TITLE" ]; then
      API_TITLE=$(echo "$COMMAND" | sed -nE "s/.*-[fF][[:space:]]+title=([^[:space:]]+).*/\1/p" | head -1)
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
#    `name`, `repo`, and `workspace`. awk fallback mirrors the one used
#    by /start-ticket (see .claude/skills/start-ticket/SKILL.md) — we do
#    not depend on yq because many forks won't have it installed.
# ---------------------------------------------------------------------------

NAMES=""
REPOS=""
WORKSPACES=""

# awk parser: walk each `- name:` block and pull out `name`, `repo`,
# `workspace`. Strips surrounding quotes. Assumes `- name:` is the first
# key in each project entry (same assumption as /start-ticket).
PARSED=$(awk '
  function unquote(s) { gsub(/^["\x27]|["\x27]$/, "", s); return s }
  /^[[:space:]]*- name:/       { print "NAME=" unquote($3) }
  /^[[:space:]]*repo:/         { print "REPO=" unquote($2) }
  /^[[:space:]]*workspace:/    { print "WORKSPACE=" unquote($2) }
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
