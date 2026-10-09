#!/bin/bash
# shellcheck source=/dev/null
. "${BASH_SOURCE[0]%/*}/_lib-awk-fallback.sh"
# Shared PR and repo extraction for merge-gate hooks. The hooks are:
# block-unreviewed-merge.sh, require-design-review-for-ui.sh,
# require-architecture-review.sh, and block-merge-on-red-ci.sh.
#
# This file is a library, not a hook. The merge gates source it and share the
# same tested parser. Keep parsing here instead of duplicating it in a hook.
# The shared parser prevents API merge forms from bypassing the gates, as the
# original GitHub API incident showed (#47).
#
# The parser covers GitHub and GitLab CLI and API merge forms. Examples:
#   gh pr merge 42 --squash
#   gh api repos/owner/repo/pulls/42/merge -X PUT
#   glab mr merge 42 -R owner/repo
#   glab api projects/owner%2Frepo/merge_requests/42/merge
#
# Usage:
#   . "$(dirname "$0")/_lib-extract-pr.sh"
#   if ! is_merge_command "$COMMAND"; then exit 0; fi
#   PR_NUMBER=$(extract_pr_number "$COMMAND")
#
# GitLab support is additive. Forge selection uses tracker_review_kind. Shape
# detection reads the command text directly. CLI state resolution uses the
# matching forge adapter.
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
#
# JSON-ESCAPED SEPARATORS IN THE RAW-PAYLOAD FALLBACK (#973, a residual
# finding from Hakim's #969 review of the #965 fix)
# ------------------------------------------------------------------------
# #965 (see the four call sites in block-unreviewed-merge.sh,
# block-merge-on-red-ci.sh, require-design-review-for-ui.sh, and
# require-architecture-review.sh) added a jq-free fallback: when jq is
# unavailable, each hook calls `is_merge_command "$INPUT"` directly against
# the RAW, still-JSON-encoded payload text instead of the jq-decoded
# command string. That works because the command's own words (`gh`, `pr`,
# `merge`, digits) survive JSON string-encoding unchanged — EXCEPT for the
# command's *separators*, when those separators are themselves characters
# JSON must escape: a literal tab encodes as the two-character sequence
# `\t`, and some encoders emit `\uXXXX` or `\/` for other bytes. Those
# two-character escape sequences are not whitespace to `grep -E`'s `\s`
# class, so `is_merge_command`'s `\bgh\s+pr\s+merge\b` pattern silently
# fails to match a merge command whose separators are JSON-escaped —
# exactly while jq (the thing that would normally decode them into real
# whitespace) is unavailable. A gate that can't evaluate its own
# precondition must fail closed, not quietly no-op on a payload that IS
# merge-shaped once decoded.
#
# `_normalize_json_escapes` (below) is a small, best-effort decoder for
# the handful of escape shapes that matter here — NOT a full JSON string
# parser, only sufficient for the shapes real callers emit.
# It is called ONLY at the four hooks' raw-payload fallback call sites
# (`is_merge_command_raw "$(_normalize_json_escapes "$INPUT")"`), never from
# inside `is_merge_command` itself and never when jq returns a nonempty
# command: jq has ALREADY correctly decoded these same escapes for that path
# (that's what `jq -r` does), so re-normalizing already-decoded text would
# be redundant at best and, for the rare case of a command that legitimately
# contains a literal backslash-t/backslash-n substring (e.g. inside a sed
# script), actively wrong — it would corrupt real command text that jq had
# already decoded correctly. Keeping the two paths separate is what makes
# this change safe for commands successfully read by jq: they never call
# this function. An empty or failed jq result enters the fallback even when
# jq is installed.
#
# BACKSLASH-NEWLINE CONTINUATIONS ON THE RAW-PAYLOAD PATH (#1564)
# ---------------------------------------------------------------
# After decode, a JSON-escaped shell continuation (`\\` then `\n` in the
# payload → real backslash then newline) is still two lines to the raw
# scanner. `is_merge_command_raw` scans both the original and continuation-
# joined text (outside single quotes), so `<cli> \<newline>pr <verb>` and
# `<cli> pr \<newline><verb>` block like the one-line form. A plain newline
# at the same positions stays two commands and is not treated as a merge.

# Lazily source the tracker lib so `tracker_review_kind` is available for forge
# resolution. Guarded: only source if not already defined and the lib is
# present. tracker_review_kind defaults to "gh" with no config, preserving gh behaviour.
if ! command -v tracker_review_kind >/dev/null 2>&1; then
  # ${BASH_SOURCE[0]} is bash-only and unset under zsh (#1025) — the `:-`
  # default avoids a hard "parameter not set" error, but an empty value
  # still makes `dirname` resolve to ".", i.e. the CALLER's cwd rather than
  # this lib's real directory, which usually (harmlessly) misses the `-f`
  # check below. The git-rev-parse fallback is the actual portability fix.
  _lib_extract_pr_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-}")" 2>/dev/null && pwd 2>/dev/null)"
  # me2resh/apexyard#1062: under a non-bash shell BASH_SOURCE is empty, so the resolution above
  # degrades to the CALLER's cwd (dirname "" -> "."). Discard a cwd-derived path so the anchored
  # git-root check below must validate it; a genuine BASH_SOURCE path is where this file lives and
  # is kept as-is (#1061 only anchored the git-derived fallback, not this cwd-derived branch).
  if [ -z "${BASH_SOURCE[0]:-}" ]; then _lib_extract_pr_dir=""; fi
  if [ -z "$_lib_extract_pr_dir" ] || [ ! -f "$_lib_extract_pr_dir/_lib-tracker.sh" ]; then
    _lib_extract_pr_root="$(git rev-parse --show-toplevel 2>/dev/null)"
    # me2resh/apexyard#1033: only accept a git-derived root that is actually
    # an apexyard fork. Without this the fallback sources a trust-chain
    # library out of ANY repo the cwd happens to be inside -- a
    # workspace/<project> clone, or an unrelated checkout.
    #
    # This narrows an ACCIDENT surface. It is NOT an access-control boundary:
    # the anchors are unauthenticated presence-only files, and -f follows
    # symlinks, so anyone able to write to the candidate root can satisfy it.
    # What it prevents is a cwd-driven misresolution, not a hostile library.
    # Anchor pair per AgDR-0021 §A/§E -- the same test
    # resolve_ops_root_walk applies, evaluated against one candidate rather
    # than a walk. (resolve_ops_root itself is unusable here: three of these
    # sites are locating _lib-ops-root.sh, and its pin is session-scoped.)
    if [ -n "$_lib_extract_pr_root" ] && { [ -f "$_lib_extract_pr_root/.apexyard-fork" ] || { [ -f "$_lib_extract_pr_root/onboarding.yaml" ] && [ -f "$_lib_extract_pr_root/apexyard.projects.yaml" ]; }; } && [ -f "$_lib_extract_pr_root/.claude/hooks/_lib-tracker.sh" ]; then
      _lib_extract_pr_dir="$_lib_extract_pr_root/.claude/hooks"
    fi
    unset _lib_extract_pr_root
  fi
  if [ -n "$_lib_extract_pr_dir" ] && [ -f "$_lib_extract_pr_dir/_lib-tracker.sh" ]; then
    # shellcheck source=/dev/null
    . "$_lib_extract_pr_dir/_lib-tracker.sh"
  fi
fi

# Echoes the forge kind ('gh' | 'glab') for a repo, via tracker_review_kind.
# Any non-glab kind (gh / none / jira / linear / unknown / unresolved) → 'gh', so
# the GitHub CLI path stays the default. Used by the CLI-calling resolvers
# (resolve_pr_head, resolve_pr_head_branch) which only have the repo, not the
# command text.
_forge_kind_for() {
  local repo="${1:-}" kind="gh"
  if command -v tracker_review_kind >/dev/null 2>&1; then
    kind=$(tracker_review_kind "$repo" 2>/dev/null || echo gh)
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

# Best-effort decode of the JSON string escapes that could hide a merge
# command's SEPARATORS from the raw-payload fallback scan (#973). Echoes
# the normalized text.
#
# Handles six literal JSON escape sequences, decoded to the real character
# they represent: backslash-t and backslash-u0009 both decode to a tab;
# backslash-n and backslash-u000A (either case) decode to a newline;
# backslash-u0020 decodes to a plain space; backslash-slash decodes to a
# plain slash.
# The original substitution order is u0020, u0009, u000A, u000a, slash,
# short t, short n, then JSON `\\` (escaped backslash). Specific two-char
# escapes are matched before `\\` so `\n` / `\t` / `\/` stay correct.
# Decoding `\\` to one backslash makes payload `\\\n` (JSON backslash then
# newline) a real shell continuation for the join in `is_merge_command_raw`
# (#1564). A single awk pass avoids bash 3.2's superlinear global
# substitutions. It does not eval or run the input text.
#
# Callers: ONLY the four merge-gate hooks' raw-payload fallback branches
# (`is_merge_command_raw "$(_normalize_json_escapes "$INPUT")"`), never
# `is_merge_command` itself and never the normal jq-present path — see the
# file header (#973) for why mixing this into the jq-present path would be
# unsafe.
_normalize_json_escapes() {
  LC_ALL=C _run_awk_or_fallback "$1" _normalize_json_escapes_legacy '
    function decode(s,    i, n, six, two) {
      n = length(s)
      for (i = 1; i <= n;) {
        six = substr(s, i, 6)
        two = substr(s, i, 2)
        if (six == "\\u0020") { printf " "; i += 6 }
        else if (six == "\\u0009") { printf "\t"; i += 6 }
        else if (six == "\\u000A" || six == "\\u000a") { printf "\n"; i += 6 }
        else if (two == "\\/") { printf "/"; i += 2 }
        else if (two == "\\t") { printf "\t"; i += 2 }
        else if (two == "\\n") { printf "\n"; i += 2 }
        else if (two == "\\\\") { printf "\\"; i += 2 }
        else { printf "%s", substr(s, i, 1); i++ }
      }
    }
    NR > 1 { decode(previous); printf "\n" }
    { previous = $0 }
    END { if (NR) decode(substr(previous, 1, length(previous) - 1)) }
  '
}

# Pre-#1550 decoder with #1564 `\\` handling, retained for awk failure.
# Bash 3.2 global substitutions are slow on huge input, so the normal path
# uses awk above.
#
# The piece decoder below uses the byte 0x1E as a backslash sentinel. A raw
# 0x1E in the input would also become a backslash, so split the input on
# raw 0x1E bytes and decode each piece alone. No escape contains 0x1E, so
# the output is the same as the awk path, and a raw 0x1E passes through
# unchanged. Print each piece directly: command substitution would strip
# a trailing newline from a piece.
_normalize_json_escapes_legacy() {
  local text="$1"
  local rs=$'\036'
  while :; do
    case "$text" in
      *"$rs"*)
        _normalize_json_escapes_legacy_piece "${text%%"$rs"*}"
        printf '%s' "$rs"
        text="${text#*"$rs"}"
        ;;
      *)
        _normalize_json_escapes_legacy_piece "$text"
        return 0
        ;;
    esac
  done
}

# Decode one piece that contains no raw 0x1E byte.
_normalize_json_escapes_legacy_piece() {
  local text="$1"
  local tab=$'\t'
  local nl=$'\n'
  # Two literal backslash characters. Used as the escape-matching prefix
  # below rather than a single backslash: bash's `${var//pattern/repl}`
  # treats a SINGLE backslash inside an expanded pattern as a glob escape
  # character (it would consume/escape the following char instead of
  # matching a literal backslash), so building the pattern from a
  # single-backslash variable silently fails to consume the backslash
  # itself — the doubled form is what makes the pattern match one literal
  # backslash followed by the literal marker character.
  local bs2='\\'
  # Four backslash characters: matches two literal backslashes (JSON `\\`).
  local esc_bs="${bs2}${bs2}"
  # Protect escaped backslashes before `\n`/`\t` so payload `\\\n` becomes
  # a real backslash-newline (#1564), not two backslashes then a newline.
  local bs_sentinel=$'\036'
  local bs1=$'\\'

  local esc_u0020="${bs2}u0020"
  local esc_u0009="${bs2}u0009"
  local esc_u000A="${bs2}u000A"
  local esc_u000a="${bs2}u000a"
  local esc_slash="${bs2}/"
  local esc_t="${bs2}t"
  local esc_n="${bs2}n"

  text="${text//$esc_bs/$bs_sentinel}"
  text="${text//$esc_u0020/ }"
  text="${text//$esc_u0009/$tab}"
  text="${text//$esc_u000A/$nl}"
  text="${text//$esc_u000a/$nl}"
  text="${text//$esc_slash//}"
  text="${text//$esc_t/$tab}"
  text="${text//$esc_n/$nl}"
  text="${text//$bs_sentinel/$bs1}"

  printf '%s' "$text"
}

# Join shell line continuations: a backslash immediately before a newline
# (#1564). Bash removes that pair before tokenising, so
# `<cli> \<newline>pr <verb>` is one merge command. The raw merge scan is
# line-oriented and would otherwise miss it after JSON-escape decode on the
# jq-failure path (decode turns payload `\\\n` into a real backslash-newline
# without joining).
#
# Outside single quotes only. A `#` comment (unquoted, at a word boundary)
# eats the rest of the line: a trailing backslash there is NOT a continuation
# (#1568 security: joining across `# … \` rewrote `--repo` onto a later merge).
# Inside double quotes, `#` is literal and `\`+newline still joins (bash).
# Linear awk over stdin — no ENVIRON/-v (Linux 128 KB cap), no
# bash `${var//…}` on large input. On awk failure, crush backslashes and
# newlines to spaces. This fallback only broadens detection because the
# original text is also scanned.
_join_shell_continuations() {
  join_shell_continuations "$1"
}

# Merge-only scrub decision (AgDR-0196, AgDR-0204). The general command
# scrubber permits programs such as git, gh, rg and sort that can execute
# arguments or files. Do not use that allowlist here: a later program could
# execute earlier data. Accept only literal command words from the narrow
# list, in EVERY segment. Unknown syntax, substitutions, incomplete heredocs,
# zsh `~[`, startup/hook redirects, grep execution options, or parser
# failures keep the entire raw command. This function never executes the
# command text.
_scrub_merge_command() {
  local cmd="$1" result
  if [ "${#cmd}" -gt 120000 ] || ! command -v awk >/dev/null 2>&1; then
    printf '%s' "$cmd"
    return 0
  fi
  result=$(MERGE_SCRUB_INPUT="$cmd" awk '
    function blank(text) { gsub(/[^\n]/, " ", text); return text }
    # printf is NOT on this list: `printf -v "a[$(cmd)]"` makes the shell
    # evaluate the array subscript, which runs the substitution (#1489 review).
    function allowed(word) {
      return word == "grep" || word == "egrep" || word == "fgrep" || \
             word == "cat" || word == "echo" || \
             word == "head" || word == "tail" || word == "wc"
    }
    function is_grep_family(word) {
      return word == "grep" || word == "egrep" || word == "fgrep"
    }
    # Strip quotes only. Do not evaluate paths or expand tildes.
    function flat_word(w,    t) {
      t = w
      gsub(/["\047]/, "", t)
      return t
    }
    function dangerous_grep_opt(w,    t, eq) {
      t = flat_word(w)
      eq = index(t, "=")
      if (eq > 1) t = substr(t, 1, eq - 1)
      return t == "--filter" || t == "--pager" || t == "--view" || \
             t == "--format-open"
    }
    # Check a grep option that starts at position p. Read a fixed window,
    # drop quote characters (the shell removes them, so --"filter"= and
    # ""--filter= reach grep as --filter=), and test the option name. The
    # window keeps the cost fixed per word start.
    function grep_opt_at(p,    w) {
      w = flat_word(substr(s, p, 48))
      if (match(w, /^-[-A-Za-z]*/)) return dangerous_grep_opt(substr(w, 1, RLENGTH))
      return 0
    }
    function startup_base(b) {
      return b == ".zshenv" || b == "zshenv" || \
             b == ".zshrc" || b == "zshrc" || \
             b == ".zprofile" || b == "zprofile" || \
             b == ".zlogin" || b == "zlogin" || \
             b == ".zlogout" || b == "zlogout" || \
             b == ".bashrc" || b == "bashrc" || \
             b == ".bash_profile" || b == "bash_profile" || \
             b == ".bash_login" || b == "bash_login" || \
             b == ".profile" || b == "profile" || \
             b == "bash.bashrc" || b == "config.fish"
    }
    function is_startup_or_hook(w,    t, n, base) {
      t = flat_word(w)
      if (t == "") return 0
      if (index(t, ".git/hooks/") > 0) return 1
      n = split(t, parts, "/")
      base = parts[n]
      if (startup_base(base)) return 1
      # Catch ~/name and bare name forms the split may leave as one field.
      if (startup_base(t)) return 1
      if (substr(t, 1, 2) == "~/" && startup_base(substr(t, 3))) return 1
      return 0
    }
    # Read one shell word with concatenated quoted spans. Leaves pos after
    # the word. Sets WORD. Returns 0 on incomplete quotes or empty input.
    function read_merge_word(    c, q, out) {
      WORD = ""
      while (pos <= n && substr(s, pos, 1) ~ /[ \t]/) pos++
      if (pos > n) return 0
      c = substr(s, pos, 1)
      if (c ~ /[\n;|&<>(){}]/ || c == "#") return 0
      out = ""
      while (pos <= n) {
        c = substr(s, pos, 1)
        if (c == sq || c == dq) {
          q = c; out = out c; pos++
          while (pos <= n && substr(s, pos, 1) != q) {
            c = substr(s, pos, 1)
            if (q == dq && (c == "$" || c == "`" || c == bs)) return 0
            out = out c; pos++
          }
          if (pos > n) return 0
          out = out q; pos++
          continue
        }
        if (c ~ /[ \t\n;|&<>(){}]/ || c == "#") break
        if (c == bs || c == "$" || c == "`") return 0
        out = out c; pos++
      }
      WORD = out
      return (WORD != "")
    }
    BEGIN {
      s = ENVIRON["MERGE_SCRUB_INPUT"]
      n = length(s); pos = 1; first = 1; out = ""; bad = 0; newbad = 0; pending = 0
      cmdword = ""
      sq = sprintf("%c", 39); dq = sprintf("%c", 34); bs = sprintf("%c", 92)
      while (pos <= n && !bad) {
        c = substr(s, pos, 1); nx = substr(s, pos + 1, 1)
        if (c == " " || c == "\t") { out = out c; pos++; continue }
        if (c == "\n") {
          out = out c; pos++; first = 1; cmdword = ""
          # Bodies start after the opener line, in delimiter order. Inspect
          # every command on the opener line before discarding any body.
          for (h = 1; h <= pending && !bad; h++) {
            found = 0
            while (pos <= n) {
              start = pos
              while (pos <= n && substr(s, pos, 1) != "\n") pos++
              line = substr(s, start, pos - start); check = line
              if (tabs[h]) sub(/^\t+/, "", check)
              if (!quoted[h] && (index(line, "$") || index(line, "`") || index(line, bs))) {
                bad = 1; break
              }
              out = out blank(line)
              if (pos <= n) { out = out "\n"; pos++ }
              if (check == delim[h]) { found = 1; break }
            }
            if (!found) bad = 1
          }
          pending = 0
          continue
        }
        if (c ~ /[;|&]/) { out = out c; pos++; first = 1; cmdword = ""; continue }
        # No normalization of command words: quoted, escaped, assigned,
        # expanded, reserved and path-qualified words all retain raw text.
        if (first) {
          start = pos
          while (pos <= n && substr(s, pos, 1) ~ /[A-Za-z]/) pos++
          word = substr(s, start, pos - start)
          after = substr(s, pos, 1)
          if (!allowed(word) || (after != "" && after !~ /[ \t\n;|&<>]/)) {
            bad = 1; break
          }
          out = out word; first = 0; cmdword = word; continue
        }
        # Unquoted zsh dynamic named directory (~[...]) can run code.
        # newbad keeps the dev scrub and adds the raw text (see the end).
        if (c == "~" && nx == "[") newbad = 1
        if (c == sq || c == dq) {
          q = c; start = pos++
          while (pos <= n && substr(s, pos, 1) != q) {
            c = substr(s, pos, 1)
            if (q == dq && (c == "$" || c == "`" || c == bs)) { bad = 1; break }
            pos++
          }
          if (bad || pos > n) { bad = 1; break }
          pos++
          word = substr(s, start, pos - start)
          # Quoted grep option names still select an execution feature. A
          # quoted span that starts a word can also begin an option name.
          if (is_grep_family(cmdword) && (dangerous_grep_opt(word) || \
              ((start == 1 || substr(s, start - 1, 1) ~ /[ \t\n;|&<>(]/) && grep_opt_at(start)))) newbad = 1
          out = out blank(word); continue
        }
        # Reject shell execution/expansion syntax and comments conservatively.
        if (c == bs || c == "$" || c == "`" || c == "#" || c ~ /[(){}]/) {
          bad = 1; break
        }
        if (c == "<" && nx == "<") {
          start = pos; pos += 2; strip = 0; q = ""
          if (substr(s, pos, 1) == "-") { strip = 1; pos++ }
          while (pos <= n && substr(s, pos, 1) ~ /[ \t]/) pos++
          c = substr(s, pos, 1)
          if (c == sq || c == dq) { q = c; pos++ }
          ds = pos
          while (pos <= n && substr(s, pos, 1) ~ /[A-Za-z0-9_]/) pos++
          d = substr(s, ds, pos - ds)
          if (d == "" || (q != "" && substr(s, pos, 1) != q)) { bad = 1; break }
          if (q != "") pos++
          after = substr(s, pos, 1)
          if (after != "" && after !~ /[ \t\n;|&<>]/) { bad = 1; break }
          pending++; delim[pending] = d; quoted[pending] = (q != ""); tabs[pending] = strip
          out = out substr(s, start, pos - start); continue
        }
        # Do not mistake the ampersand in a descriptor redirect for a new
        # command. Process substitutions hit the raw fallback above.
        if ((c == ">" || c == "<") && nx == "&") {
          out = out c nx; pos += 2; continue
        }
        # Output redirects to shell startup files or .git/hooks add the raw
        # text. Look ahead only: pos returns to the operator, so the scrub
        # below stays the same as on dev.
        if (c == ">") {
          start = pos
          pos++
          if (substr(s, pos, 1) == ">" || substr(s, pos, 1) == "|") pos++
          if (read_merge_word() && is_startup_or_hook(WORD)) newbad = 1
          pos = start
        }
        # Grep-family options that can run a program on some hosts add the
        # raw text. A word that starts with a quote is handled in the quote branch.
        # Check only a dash that starts a word, and read a fixed window with
        # grep_opt_at: reading each dash to the end of a long word made the
        # scan super-linear, and a timed-out gate does not block (Hakim,
        # review of PR #1517).
        if (is_grep_family(cmdword) && c == "-" && \
            (pos == 1 || substr(s, pos - 1, 1) ~ /[ \t\n;|&<>(]/)) {
          if (grep_opt_at(pos)) newbad = 1
        }
        out = out c; pos++
      }
      if (pending) bad = 1
      # A newbad shape can execute the data, so the gates must see the raw
      # text. They must also still see the dev scrubbed text, where a merge
      # phrase split by quotes reads as separate words (review of PR #1517).
      # Print both, on separate lines.
      if (bad) printf "%s", s
      else if (newbad) printf "%s\n%s", s, out
      else printf "%s", out
    }
  ' 2>/dev/null) || result="$cmd"
  printf '%s' "${result:-$cmd}"
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
  # Gates require this function. Standalone consumers still retain the raw
  # detector if a damaged library omits it or the scrub operation fails.
  if declare -F _scrub_merge_command >/dev/null 2>&1; then
    cmd=$(_scrub_merge_command "$cmd") || cmd="$1"
  fi
  is_merge_command_raw "$cmd"
}

# Interpreter calls can pass gh/pr/merge as quoted argv elements without a
# contiguous CLI phrase. Flatten newlines so one scan also sees multi-line
# lists. The optional `[` after gh covers spawn('gh', ['pr', 'merge', ...]).
# #1552 also covers padded/full-path binaries, global flags between elements,
# glab argv, API elements with internal commas, split-tail strings, JS
# backticks, and short list-join / star-unpack gaps. See AgDR-0214.
_has_argv_merge() {
  # Use tr, not ${1//$'\n'/ }: under macOS /bin/bash 3.2 that substitution
  # slows sharply with input size (about 2,000 lines took over a minute), and
  # a gate that times out does not block. tr is linear.
  local flat
  flat=$(printf '%s' "$1" | tr '\n' ' ')
  # Match each quote style separately so one kind cannot close another.
  # A backtick inside '…' or "…" (e.g. commit_message with inline code) must
  # stay inside that element. Optional JSON-style backslash before each
  # opener and closer (covers \"gh\" as well as "gh").
  local elem='([\\]?"[^"]*[\\]?"|[\\]?'\''[^'\'']*[\\]?'\''|[\\]?`[^`]*[\\]?`)'
  local comma='[[:space:]]*,[[:space:]]*'
  local argv_start='\[?[[:space:]]*'
  # Quoted flag/option elements between major tokens (e.g. '-R', 'o/r').
  local argv_flags="(${elem}${comma})*"
  # ≤20 chars of list-join / star-unpack glue, and at least one of ] [ + * ,
  # (#1552 shape 7). Space-only gaps between quoted tokens stay non-matches
  # so prose like '`gh` `pr` `merge`' does not look like an argv list.
  local glue='([][:space:]"`'"'"']){0,10}[][+*,]([][+*,[:space:]"`'"'"']){0,9}'
  # Binary element: optional path prefix and/or leading pad inside the quotes.
  local gh_elem='([\]?["'"'"'`]([^/"'"'"'`[:space:]]*/)*[[:space:]]*gh[\]?["'"'"'`])'
  local glab_elem='([\]?["'"'"'`]([^/"'"'"'`[:space:]]*/)*[[:space:]]*glab[\]?["'"'"'`])'
  local pr_elem='([\]?["'"'"'`]pr[\]?["'"'"'`])'
  local mr_elem='([\]?["'"'"'`]mr[\]?["'"'"'`])'
  local merge_elem='([\]?["'"'"'`]merge[\]?["'"'"'`])'
  local api_tok='([\]?["'"'"'`]api[\]?["'"'"'`])'
  local open_q='([\\]?"|[\\]?'\''|[\\]?`)'

  # Classic comma-separated argv, with optional global flags between tokens.
  if printf '%s\n' "$flat" | grep -qE "${gh_elem}${comma}${argv_start}${argv_flags}${pr_elem}${comma}${merge_elem}"; then
    return 0
  fi
  # Joined lists / star-unpacking with a bounded glue gap (#1552 shape 7).
  if printf '%s\n' "$flat" | grep -qE "${gh_elem}${glue}${pr_elem}${glue}${merge_elem}"; then
    return 0
  fi
  # One element holds the remainder: 'gh' then a quoted "pr merge …" (#1552 shape 5).
  if printf '%s\n' "$flat" | grep -qE "${gh_elem}${glue}${open_q}pr[[:space:]]+merge\b"; then
    return 0
  fi
  # glab mr merge argv (with optional flags or glue).
  if printf '%s\n' "$flat" | grep -qE "${glab_elem}${comma}${argv_start}${argv_flags}${mr_elem}${comma}${merge_elem}"; then
    return 0
  fi
  if printf '%s\n' "$flat" | grep -qE "${glab_elem}${glue}${mr_elem}${glue}${merge_elem}"; then
    return 0
  fi

  # The same argv shape can call the GitHub API merge endpoint directly.
  # Intermediate quoted args may contain commas (e.g. '-f', 'm=a,b') and
  # backticks (e.g. commit_message with inline code).
  local api_elem='([\\]?"[^"[:space:],]*/pulls/[0-9]+/merge([?][^"[:space:],]*)?[\\]?"|[\\]?'\''[^'\''[:space:],]*/pulls/[0-9]+/merge([?][^'\''[:space:],]*)?[\\]?'\''|[\\]?`[^`[:space:],]*/pulls/[0-9]+/merge([?][^`[:space:],]*)?[\\]?`)'
  local argv_any="(${elem}${comma})*"
  printf '%s\n' "$flat" | grep -qE "${gh_elem}${comma}${argv_start}${api_tok}${comma}${argv_any}${api_elem}"
}

# Merges nested in shell -c argv lists, xargs pipelines, or Perl qw() are
# detected as merges by the contiguous phrase matcher, but their PR/repo
# cannot be trusted (or is absent). Treat them as opaque targets so the
# gates never fall back to the current branch's PR (#1552 shapes 10–12).
# Wrapper and merge text must share one statement: split on ; && || and
# newlines ONLY outside single/double quotes (backslash escapes outside
# single quotes). Skip shell comments and fail closed on an unclosed quote.
# Split into characters once: macOS awk makes repeated one-character substr
# calls quadratic on a long statement (#1552 round 3).
# Same statement + xargs = opaque (no character window). The argv -c form
# still requires the merge within 200 characters after '-c'. On awk failure,
# fail closed because the whole-input classifier is unavailable.
_has_opaque_merge_wrapper() {
  _has_opaque_merge_wrapper_fallback() {
    # Without the whole-input parser, split-line phrases and malformed
    # quotes cannot be ruled out. Raw 0x1c must also remain opaque.
    printf opaque
  }
  local result
  result=$(_run_awk_or_fallback "$1" _has_opaque_merge_wrapper_fallback '
    function wb_before(t, p) {
      return p <= 1 || substr(t, p - 1, 1) !~ /[A-Za-z0-9_]/
    }
    function wb_after(t, p, len) {
      return p + len > length(t) || substr(t, p + len, 1) !~ /[A-Za-z0-9_]/
    }
    function has_merge(t,    p) {
      p = match(t, /gh[[:space:]]+pr[[:space:]]+merge/)
      if (p && wb_before(t, p) && wb_after(t, p, RLENGTH)) return 1
      p = match(t, /glab[[:space:]]+mr[[:space:]]+merge/)
      if (p && wb_before(t, p) && wb_after(t, p, RLENGTH)) return 1
      return 0
    }
    function has_xargs(t,    p) {
      p = match(t, /xargs/)
      return p && wb_before(t, p) && wb_after(t, p, 5)
    }
    function has_sh_c_near_merge(t,    flat, q, re) {
      # Flatten newlines so .{0,200} spans a quoted multi-line -c script.
      flat = t
      gsub(/\n/, " ", flat)
      q = "[\\\\]?[\"'"'"'`]"
      re = q "(sh|bash|zsh)" q "[[:space:]]*,[[:space:]]*" q "-c" q ".{0,200}"
      if (match(flat, re "(gh[[:space:]]+pr[[:space:]]+merge)")) return 1
      if (match(flat, re "(glab[[:space:]]+mr[[:space:]]+merge)")) return 1
      return 0
    }
    function has_qw(t,    flat) {
      flat = t
      gsub(/\n/, " ", flat)
      if (match(flat, /qw[[:space:]]*[(][^)]*gh[[:space:]]+pr[[:space:]]+merge/)) return 1
      if (match(flat, /qw[[:space:]]*[(][^)]*glab[[:space:]]+mr[[:space:]]+merge/)) return 1
      if (match(flat, /qw[[:space:]]*\/[^\/]*gh[[:space:]]+pr[[:space:]]+merge/)) return 1
      if (match(flat, /qw[[:space:]]*\/[^\/]*glab[[:space:]]+mr[[:space:]]+merge/)) return 1
      return 0
    }
    function stmt_opaque(t) {
      if (!has_merge(t)) return 0
      if (has_xargs(t)) return 1
      if (has_sh_c_near_merge(t)) return 1
      if (has_qw(t)) return 1
      return 0
    }
    # A separator in caller text creates another record and fails closed.
    BEGIN { RS = sprintf("%c", 28) }
    { if (NR == 1) s = $0; else multiple = 1 }
    END {
      opaque = multiple
      n = length(s)
      sq = sprintf("%c", 39); dq = sprintf("%c", 34); bs = sprintf("%c", 92)
      in_sq = 0; in_dq = 0; st = 1; escaped_prev = 0
      n = split(s, ch, "")
      for (i = 1; i <= n && !opaque; i++) {
        c = ch[i]
        nx = (i < n) ? ch[i + 1] : ""
        was_escaped = escaped_prev; escaped_prev = 0
        if (!in_sq && c == bs && i < n) { i++; escaped_prev = 1; continue }
        if (!in_dq && c == sq) { in_sq = !in_sq; continue }
        if (!in_sq && c == dq) { in_dq = !in_dq; continue }
        if (!in_sq && !in_dq) {
          if (c == "#" && !was_escaped && (i == 1 || ch[i - 1] ~ /[ \t\n;&|(]/)) {
            while (i < n && ch[i + 1] != "\n") i++
            continue
          }
          if (c == "\n" || c == ";") {
            if (stmt_opaque(substr(s, st, i - st))) { opaque = 1; break }
            st = i + 1; continue
          }
          if ((c == "&" && nx == "&") || (c == "|" && nx == "|")) {
            if (stmt_opaque(substr(s, st, i - st))) { opaque = 1; break }
            i++; st = i + 1; continue
          }
        }
      }
      if (!opaque && stmt_opaque(substr(s, st))) opaque = 1
      if (!opaque && (in_sq || in_dq) && has_merge(s)) opaque = 1
      if (opaque) print "opaque"
      else print "clear"
    }
  ')
  case "$result" in
    opaque) return 0 ;;
    clear) return 1 ;;
  esac
  # Missing classifier output remains fail closed.
  [ "$(_has_opaque_merge_wrapper_fallback "$1")" = opaque ]
}

# Raw scan for the unparseable JSON fallback. Do not scrub the encoded payload:
# JSON quotes are transport syntax, not shell argument boundaries.
# Scan both the original text and backslash-newline-joined text (#1564).
# A backslash at the end of a comment line does not continue that comment,
# so the original scan must remain available for every detector.
is_merge_command_raw() {
  local cmd joined
  joined=$(_join_shell_continuations "$1")
  for cmd in "$1" "$joined"; do
    if echo "$cmd" | grep -qE '\bgh\s+pr\s+merge\b'; then
      return 0
    fi
    if _has_argv_merge "$cmd"; then
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
  done
  return 1
}

# The argv detector can identify a merge without identifying its target.
# Treat ANY argv merge as opaque, even beside a parseable CLI form: in a mixed
# command the extractors would read the CLI form's PR (for example one only
# echoed as text) while the argv list merges a different PR. Nested shell -c /
# xargs / Perl qw wrappers are opaque for the same reason (#1552).
_is_argv_only_merge_command() {
  if _has_argv_merge "$1"; then
    return 0
  fi
  # Continuations can split an argv list across lines (#1568). Detectors in
  # is_merge_command_raw already scan the joined text; opacity must too, or
  # the extractors fall through to the current branch's PR.
  if _has_argv_merge "$(_join_shell_continuations "$1")"; then
    return 0
  fi
  _has_opaque_merge_wrapper "$1"
}

# Echoes the PR number extracted from the command, or empty if none found.
# Tries (in order):
#   1. `gh api .../pulls/<N>/merge` URL path
#   2. `gh pr merge <N>` first numeric arg (strict: must be a bare integer token
#      immediately following `merge`; NOT a digit scraped from a redirection such
#      as `2>&1`, and NOT an unexpanded shell variable such as `$pr` or `$PR`).
#      When the token is a shell variable the function returns empty so the
#      caller's step-3 fallback can invoke `gh pr view`.
#   3. falls back to `gh pr view --json number` (current branch's PR), except
#      for argv-only merges, whose target must stay unresolved
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
  local cmd
  # Join before parsing so a backslash-newline split `gh pr merge N` still
  # yields N (#1568). Detectors already join; extractors must match.
  cmd=$(_join_shell_continuations "$1")
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
    if _is_argv_only_merge_command "$cmd"; then
      echo ""
      return 0
    fi
    if [ "$(_forge_from_command "$cmd")" = glab ]; then
      pr=$(glab mr view --output json 2>/dev/null | jq -r '.iid // empty' 2>/dev/null)
    else
      pr=$(gh pr view --json number --jq '.number' 2>/dev/null)
    fi
  fi

  echo "$pr"
}

# Returns 0 if the merge target is opaque: an unexpanded PR/repo variable
# ($VAR / ${VAR}), or an argv-only merge whose target cannot be parsed. (#643)
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
# Plain CLI forms with literal targets do not match. Quoted argv-only forms
# remain opaque even with a literal element because this parser cannot read
# their target. `$(...)` is not a PR/repo variable token.
merge_command_uses_variable() {
  local cmd joined
  # Join first so continued CLI merges and argv lists keep a readable target
  # for the opacity / variable checks (#1568).
  joined=$(_join_shell_continuations "$1")
  # Use the same bounded data view as is_merge_command. Uncertain or
  # executable commands keep the raw text, so variable targets still block.
  cmd=$(_scrub_merge_command "$joined") || cmd="$joined"

  # All four hooks call this check before PR extraction. Three intentionally
  # skip when extraction returns empty, leaving the approval hook to report
  # that error. An argv-only merge must block in every hook because its
  # target may differ from the branch PR, so use this early unresolved-target
  # guard as well as suppressing the extractors' ambient fallbacks.
  if _is_argv_only_merge_command "$cmd"; then
    return 0
  fi

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

# Echoes repo flag values in command order, limited to CLI merge spans.
# One match preserves command order across separated and attached spellings.
# Keep separators first so -R=VALUE strips the equals sign.
_merge_repo_flag_values() {
  local cmd
  cmd=$(_join_shell_continuations "$1")
  echo "$cmd" | grep -oE '\b(gh\s+pr|glab\s+mr)\s+merge\b[^|;&]*' \
    | grep -oE '[[:space:]]((--repo|-R)(=|[[:space:]]+)[^[:space:]]+|-R[^=[:space:]][^[:space:]]*)' \
    | sed -E 's/^[[:space:]]+((--repo|-R)(=|[[:space:]]+)|-R)//'
}

# Conflicting repo declarations are never a legitimate merge target.
has_conflicting_repo_flags() {
  local cmd spans span values first value
  cmd=$(_join_shell_continuations "$1")
  spans=$(echo "$cmd" | grep -oE '\b(gh\s+pr|glab\s+mr)\s+merge\b[^|;&]*')
  while IFS= read -r span; do
    values=$(_merge_repo_flag_values "$span")
    first=""
    while IFS= read -r value; do
      [ -n "$value" ] || continue
      if [ -n "$first" ] && [ "$value" != "$first" ]; then
        return 0
      fi
      first="$value"
    done <<EOF
$values
EOF
  done <<EOF
$spans
EOF
  return 1
}

# Echoes an owner/repo EXPLICITLY named in the merge command, or empty when
# the command carries no literal repo. This intentionally excludes ambient
# forge/CWD fallbacks so callers can apply the precedence "explicit command
# target > cd-target heuristic > ambient checkout" without duplicating the
# command parser (me2resh/apexyard#1151).
extract_explicit_repo_from_command() {
  local cmd
  cmd=$(_join_shell_continuations "$1")
  local repo=""

  # 1. --repo/-R on the merge-command span only. A flag is the clearest
  # explicit declaration and therefore outranks any URL text elsewhere.
  local mspan span
  mspan=$(echo "$cmd" | grep -oE '\b(gh\s+pr|glab\s+mr)\s+merge\b[^|;&]*')
  while IFS= read -r span; do
    repo=$(_merge_repo_flag_values "$span" | tail -1)
    [ -n "$repo" ] && break
  done <<EOF
$mspan
EOF

  # 2. gh api path extraction.
  if [ -z "$repo" ]; then
    repo=$(echo "$cmd" | grep -oE 'repos/[^/[:space:]]+/[^/[:space:]]+/pulls/[0-9]+/merge' \
      | sed -nE 's|repos/([^/]+/[^/]+)/pulls/.*|\1|p' | head -1)
  fi

  # 2b. glab api path extraction (#767).
  if [ -z "$repo" ]; then
    repo=$(echo "$cmd" | grep -oE 'projects/[^/[:space:]]+/merge_requests/[0-9]+/merge' \
      | sed -nE 's|projects/([^/]+)/merge_requests/.*|\1|p' | head -1)
    if [ -n "$repo" ]; then
      repo=$(echo "$repo" | sed -e 's/%2[Ff]/\//g')
    fi
  fi

  # 3. tracker_pr_merge positional repo argument (#759).
  if [ -z "$repo" ]; then
    local wspan wargs
    wspan=$(echo "$cmd" | grep -oE '\btracker_pr_merge\b[^|;&)]*')
    if [ -n "$wspan" ]; then
      wargs=$(echo "$wspan" | sed -E 's/^tracker_pr_merge[[:space:]]+//')
      repo=$(_extract_wrapper_arg "$wargs" 1)
    fi
  fi

  echo "$repo"
}

# Resolves the merge target with one precedence shared by all four gates:
# explicit command target, then a leading cd target's origin, then ambient
# forge/CWD discovery. pr_cmd_cd_target + git_origin_repo are supplied by
# _lib-pr-repo.sh, which each merge-gate hook sources before calling this.
resolve_merge_repo() {
  local cmd repo="" cd_target=""
  cmd=$(_join_shell_continuations "$1")

  repo=$(extract_explicit_repo_from_command "$cmd")

  # An argv-only merge can target another repo. Never borrow the checkout's
  # repo unless the command has an explicit form the extractor can read.
  if [ -z "$repo" ] && _is_argv_only_merge_command "$cmd"; then
    echo ""
    return 0
  fi
  if [ -z "$repo" ] && command -v pr_cmd_cd_target >/dev/null 2>&1 && command -v git_origin_repo >/dev/null 2>&1; then
    cd_target=$(pr_cmd_cd_target "$cmd")
    if [ -n "$cd_target" ] && git -C "$cd_target" rev-parse --git-dir >/dev/null 2>&1; then
      repo=$(git_origin_repo "$cd_target")
    fi
  fi
  if [ -z "$repo" ]; then
    repo=$(extract_repo_from_command "$cmd")
  fi

  echo "$repo"
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
#   3. Falls back to `gh pr view --json headRepository`, scoped to the
#      checkout's own `origin` remote when resolvable (#887) — current
#      branch's PR
#
# Returns empty if the repo cannot be determined.
extract_repo_from_command() {
  local cmd
  cmd=$(_join_shell_continuations "$1")
  local repo=""

  repo=$(extract_explicit_repo_from_command "$cmd")

  # An argv-only merge may target a different repo from the checkout's.
  if [ -z "$repo" ] && _is_argv_only_merge_command "$cmd"; then
    echo ""
    return 0
  fi

  # 3. Last resort: ask the forge which repo the current branch's PR/MR belongs
  #    to. Forge-aware (#764): a glab command falls back to `glab repo view`.
  #
  #    gh side (#887): an UNSCOPED `gh pr view --json headRepository` trusts
  #    gh's ambient default-repo resolution, which prefers a remote literally
  #    named "upstream" over "origin" when both exist — exactly the fork
  #    layout this framework's own hooks use (origin=fork, upstream=canonical).
  #    On a same-repo fork PR (opened against the fork's own main) that
  #    ambient default silently targets the WRONG (parent) repo instead of
  #    failing, the same class of bug `pr_base_repo` was fixed against in
  #    #765/#898. Resolve the checkout's OWN repo from its `origin` remote
  #    FIRST — deterministic, not a guess — and scope the gh query to it;
  #    only fall through to the unscoped call when origin itself can't be
  #    resolved at all (e.g. no git remote configured), so single-remote
  #    checkouts keep working exactly as before.
  if [ -z "$repo" ]; then
    if [ "$(_forge_from_command "$cmd")" = glab ]; then
      repo=$(glab repo view --output json 2>/dev/null | jq -r '.full_name // empty' 2>/dev/null)
    else
      local origin_repo
      origin_repo=$(git remote get-url origin 2>/dev/null | sed -E 's#\.git$##; s#^(https?://[^/]+/|git@[^:]+:)##')
      if [ -n "$origin_repo" ]; then
        repo=$(gh pr view --repo "$origin_repo" --json headRepository --jq '.headRepository.nameWithOwner' 2>/dev/null)
      fi
      if [ -z "$repo" ]; then
        repo=$(gh pr view --json headRepository --jq '.headRepository.nameWithOwner' 2>/dev/null)
      fi
    fi
  fi

  echo "$repo"
}
