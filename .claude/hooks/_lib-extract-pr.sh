#!/bin/bash
# shellcheck source=/dev/null
. "${BASH_SOURCE[0]%/*}/_lib-awk-fallback.sh"
# Per-call forge time limit for resolve_* helpers (#1796).
if [ -z "${APEXYARD_GH_TIMEOUT_LOADED:-}" ] && [ -r "${BASH_SOURCE[0]%/*}/_lib-gh-timeout.sh" ]; then
  # shellcheck source=/dev/null
  . "${BASH_SOURCE[0]%/*}/_lib-gh-timeout.sh"
  APEXYARD_GH_TIMEOUT_LOADED=1
fi
if ! command -v apexyard_gh >/dev/null 2>&1; then
  apexyard_gh() { gh "$@"; }
fi
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
  case "${1:-}" in *glab*) ;; *) echo gh; return 0 ;; esac
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
  case "$1" in
    *\\*) ;;
    *)
      if command -v awk >/dev/null 2>&1; then
        printf '%s' "$1"
        return 0
      fi
      ;;
  esac
  join_shell_continuations "$1"
}

# Merge-only scrub decision (AgDR-0196, AgDR-0204, AgDR-0247). The general
# command scrubber permits programs such as git, gh, rg and sort that can
# execute arguments or files. Do not use that allowlist here: a later program
# could execute earlier data. Accept only literal command words from the
# narrow list, in EVERY segment. Unknown syntax, substitutions, incomplete
# heredocs, zsh `~[`, startup/hook redirects, grep execution options, or
# parser failures keep the entire raw command. This function never executes
# the command text.
#
# Returns 0 when the scrub is clean, 3 when a shape can execute the data,
# and 2 when the raw command must stay. Callers that decide a gate use
# _scrub_merge_command, which always returns 0.
_merge_scrub_once() {
  local cmd="$1" result
  if [ "${#cmd}" -gt 120000 ] || ! command -v awk >/dev/null 2>&1; then
    printf '%s' "$cmd"
    return 2
  fi
  local rc=0
  result=$(MERGE_SCRUB_INPUT="$cmd" awk '
    function blank(text) { gsub(/[^\n]/, " ", text); return text }
    # Record a grep pattern. Blank it at the end only when nothing in the
    # command can execute that pattern (#1760).
    function remember_pattern(text) {
      np++
      ps[np] = length(out) + 1
      pl[np] = length(text)
    }
    # printf is NOT on this list: `printf -v "a[$(cmd)]"` makes the shell
    # evaluate the array subscript, which runs the substitution (#1489 review).
    # true and false do not run their arguments. A later word off this list
    # still keeps the raw command.
    function allowed(word) {
      return word == "grep" || word == "egrep" || word == "fgrep" || \
             word == "cat" || word == "echo" || word == "jq" || \
             word == "head" || word == "tail" || word == "wc" || \
             word == "true" || word == "false"
    }
    # Echo arguments are data only after every segment passes the scrub.
    function remember_echo() {
      if (echo_start) {
        np++; ps[np] = echo_start; pl[np] = length(out) - echo_start + 1
        echo_start = 0
      }
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
      cmdword = ""; seen_pat = 0; take_next = 0; np = 0
      sq = sprintf("%c", 39); dq = sprintf("%c", 34); bs = sprintf("%c", 92)
      while (pos <= n && !bad) {
        c = substr(s, pos, 1); nx = substr(s, pos + 1, 1)
        if (c == " " || c == "\t") { out = out c; pos++; continue }
        if (c == "\n") {
          remember_echo()
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
        # Combined-output operators do not start a new command.
        if (c == "&" && nx == ">") { out = out c; pos++; c = ">"; nx = substr(s, pos + 1, 1) }
        if (c ~ /[;|&]/) { remember_echo(); out = out c; pos++; first = 1; cmdword = ""; continue }
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
          out = out word; first = 0; cmdword = word; seen_pat = 0; take_next = 0
          if (word == "echo") echo_start = length(out) + 1
          continue
        }
        # Unquoted zsh dynamic named directory (~[...]) can run code.
        # newbad keeps the dev scrub and adds the raw text (see the end).
        if (c == "~" && nx == "[") newbad = 1
        if (c == sq || c == dq) {
          q = c; start = pos++
          while (pos <= n && substr(s, pos, 1) != q) {
            c = substr(s, pos, 1)
            # A plain $name or ${name} inside double quotes is data. $(,
            # backticks, and ${ with an operator can run, so they keep the
            # raw command (#1760). An escaped character is also data.
            if (q == dq && c == "`") { bad = 1; break }
            if (q == dq && c == bs) {
              pos++
              if (pos <= n) pos++
              continue
            }
            if (q == dq && c == "$") {
              nx2 = substr(s, pos + 1, 1)
              if (nx2 == "(" || nx2 == "[" || nx2 == "`") { bad = 1; break }
              if (nx2 == "{") {
                if (match(substr(s, pos + 2), /^[A-Za-z_][A-Za-z0-9_]*}/)) {
                  pos += 2 + RLENGTH
                  continue
                }
                bad = 1; break
              }
              if (nx2 ~ /[A-Za-z_]/) {
                pos++
                while (pos <= n && substr(s, pos, 1) ~ /[A-Za-z0-9_]/) pos++
                continue
              }
              pos++
              if (nx2 ~ /[0-9@*#?!-]/) pos++
              continue
            }
            pos++
          }
          if (bad || pos > n) { bad = 1; break }
          pos++
          word = substr(s, start, pos - start)
          # Quoted grep option names still select an execution feature. A
          # quoted span that starts a word can also begin an option name.
          if (is_grep_family(cmdword) && (dangerous_grep_opt(word) || \
              ((start == 1 || substr(s, start - 1, 1) ~ /[ \t\n;|&<>(]/) && grep_opt_at(start)))) newbad = 1
          if (is_grep_family(cmdword) && (take_next || !seen_pat)) {
            seen_pat = 1
            take_next = 0
          }
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
        if ((c == "<" && nx == "&") || \
            (c == ">" && nx == "&" && substr(s, pos + 2, 1) ~ /[0-9-]/)) {
          out = out c nx; pos += 2; continue
        }
        # Output redirects to shell startup files or .git/hooks add the raw
        # text. A target the word reader cannot read also adds the raw text
        # for any word lead. A word lead is a first character that is not a
        # separator. A later "$NAME" span is in that class. Look ahead only.
        # pos returns to the operator, so the scrub below stays the same as
        # on dev.
        if (c == ">") {
          start = pos
          pos++
          while (pos <= n && substr(s, pos, 1) ~ /[>|!&]/) pos++
          while (pos <= n && substr(s, pos, 1) ~ /[ \t]/) pos++
          lead = (pos <= n) ? substr(s, pos, 1) : ""
          if (read_merge_word()) {
            if (is_startup_or_hook(WORD)) newbad = 1
          } else if (lead != "" && lead !~ /[&;|<>()\n]/) {
            newbad = 1
          }
          pos = start
          if (nx == "&") {
            pos++
            while (pos <= n && substr(s, pos, 1) ~ /[>|!&]/) pos++
            out = out substr(s, start, pos - start)
            continue
          }
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
          wstart = pos
          while (pos <= n) {
            c = substr(s, pos, 1)
            # zsh ~[ runs code. The word loop must not skip that check.
            if (c == "~" && substr(s, pos + 1, 1) == "[") newbad = 1
            if (c ~ /[ \t\n;|&<>(){}#]/ || c == sq || c == dq || c == bs || c == "$" || c == "`") break
            pos++
          }
          word = substr(s, wstart, pos - wstart)
          opt = word
          sub(/=.*/, "", opt)
          # --regexp=PAT and -e=PAT carry the pattern in this word.
          # Test that form first. After "=" is removed, the name test
          # also matches those words and would blank the next word.
          if (word != opt && (opt == "--regexp" || opt == "-e")) {
            remember_pattern(word)
            seen_pat = 1
            take_next = 0
          } else if (opt == "-e" || opt == "--regexp") take_next = 1
          out = out word
          continue
        }
        # An unquoted grep pattern is data. Blank it only when the command
        # cannot execute the pattern (#1760).
        if (is_grep_family(cmdword) && \
            (pos == 1 || substr(s, pos - 1, 1) ~ /[ \t\n;|&<>]/)) {
          wstart = pos
          while (pos <= n) {
            c = substr(s, pos, 1)
            # zsh ~[ runs code. The word loop must not skip that check.
            if (c == "~" && substr(s, pos + 1, 1) == "[") newbad = 1
            if (c ~ /[ \t\n;|&<>(){}#]/ || c == sq || c == dq || c == bs || c == "$" || c == "`") break
            pos++
          }
          word = substr(s, wstart, pos - wstart)
          if (word != "") {
            if (take_next || !seen_pat) {
              remember_pattern(word)
              seen_pat = 1
              take_next = 0
            }
            out = out word
            continue
          }
        }
        out = out c; pos++
      }
      remember_echo()
      if (pending) bad = 1
      # A newbad shape can execute the data, so the gates must see the raw
      # text. They must also still see the dev scrubbed text, where a merge
      # phrase split by quotes reads as separate words (review of PR #1517).
      # Print both, on separate lines. Do not blank a pattern in that copy.
      if (!bad && !newbad) {
        for (i = 1; i <= np; i++)
          out = substr(out, 1, ps[i] - 1) blank(substr(out, ps[i], pl[i])) substr(out, ps[i] + pl[i])
      }
      if (bad) { printf "%s", s; exit 2 }
      if (newbad) { printf "%s\n%s", s, out; exit 3 }
      printf "%s", out
      exit 0
    }
  ' 2>/dev/null) || rc=$?
  if [ "$rc" -ne 0 ] && [ "$rc" -ne 2 ] && [ "$rc" -ne 3 ]; then
    printf '%s' "$cmd"
    return 2
  fi
  printf '%s' "${result:-$cmd}"
  return "$rc"
}

# Public scrub. Always returns 0.
#
# _merge_scrub_once blanks an inert heredoc body. Do not call
# strip_heredoc_bodies here. That helper must not decide whether a merge
# gate fires. See _lib-strip-heredoc.sh.
_scrub_merge_command() {
  local cmd="$1" result
  result=$(_merge_scrub_once "$cmd") || true
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
  # Every pattern needs a quoted binary element, so no quotes means no match.
  case "$1" in *\'*|*\"*|*\`*) ;; *) return 1 ;; esac
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
# still requires the merge within 200 characters after the -c quote. Mark
# phrase starts and -c matches in one pass, then test that fixed window.
# Do not copy the unread tail. macOS awk makes that copy quadratic, and a
# slow gate does not block (AgDR-0204). An ERE interval is not portable:
# Debian mawk 1.3.4 20200120 aborts on it and the fallback then blocks
# every direct merge (#1757). Homebrew mawk 1.3.4-20260302 accepts the
# interval, so that build is not evidence. On awk failure, fail closed
# because the whole-input classifier is unavailable.
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
    # Character classes for the argv -c pattern. Use the split array below.
    # Repeated substr on the tail is quadratic on macOS awk.
    function hm_is_quote(c) {
      return c == sq || c == dq || c == hm_bt
    }
    function hm_is_space(c) {
      return c == " " || c == "\t" || c == "\n" || c == "\r" || c == "\f" || c == hm_vt
    }
    function hm_quote_len(i,    c) {
      if (i > hm_n) return 0
      c = hm_fc[i]
      if (c == bs && i < hm_n && hm_is_quote(hm_fc[i + 1])) return 2
      if (hm_is_quote(c)) return 1
      return 0
    }
    function hm_shell_len(i) {
      if (i + 3 <= hm_n && hm_fc[i] == "b" && hm_fc[i + 1] == "a" && hm_fc[i + 2] == "s" && hm_fc[i + 3] == "h") return 4
      if (i + 2 <= hm_n && hm_fc[i] == "z" && hm_fc[i + 1] == "s" && hm_fc[i + 2] == "h") return 3
      if (i + 1 <= hm_n && hm_fc[i] == "s" && hm_fc[i + 1] == "h") return 2
      return 0
    }
    # Length of quote + shell + quote + comma + quote + -c + quote at i.
    # Whitespace around the comma may be any length. 0 means no match.
    function hm_c_len(i,    k, j, sl) {
      k = hm_quote_len(i)
      if (!k) return 0
      j = i + k
      sl = hm_shell_len(j)
      if (!sl) return 0
      j += sl
      k = hm_quote_len(j)
      if (!k) return 0
      j += k
      while (j <= hm_n && hm_is_space(hm_fc[j])) j++
      if (j > hm_n || hm_fc[j] != ",") return 0
      j++
      while (j <= hm_n && hm_is_space(hm_fc[j])) j++
      k = hm_quote_len(j)
      if (!k) return 0
      j += k
      if (j + 1 > hm_n || hm_fc[j] != "-" || hm_fc[j + 1] != "c") return 0
      j += 2
      k = hm_quote_len(j)
      if (!k) return 0
      return j + k - i
    }
    function hm_phrase_gh(i,    j) {
      if (i + 1 > hm_n || hm_fc[i] != "g" || hm_fc[i + 1] != "h") return 0
      j = i + 2
      if (j > hm_n || !hm_is_space(hm_fc[j])) return 0
      while (j <= hm_n && hm_is_space(hm_fc[j])) j++
      if (j + 1 > hm_n || hm_fc[j] != "p" || hm_fc[j + 1] != "r") return 0
      j += 2
      if (j > hm_n || !hm_is_space(hm_fc[j])) return 0
      while (j <= hm_n && hm_is_space(hm_fc[j])) j++
      if (j + 4 > hm_n || hm_fc[j] != "m" || hm_fc[j + 1] != "e" || hm_fc[j + 2] != "r" || hm_fc[j + 3] != "g" || hm_fc[j + 4] != "e") return 0
      return 1
    }
    function hm_phrase_glab(i,    j) {
      if (i + 3 > hm_n || hm_fc[i] != "g" || hm_fc[i + 1] != "l" || hm_fc[i + 2] != "a" || hm_fc[i + 3] != "b") return 0
      j = i + 4
      if (j > hm_n || !hm_is_space(hm_fc[j])) return 0
      while (j <= hm_n && hm_is_space(hm_fc[j])) j++
      if (j + 1 > hm_n || hm_fc[j] != "m" || hm_fc[j + 1] != "r") return 0
      j += 2
      if (j > hm_n || !hm_is_space(hm_fc[j])) return 0
      while (j <= hm_n && hm_is_space(hm_fc[j])) j++
      if (j + 4 > hm_n || hm_fc[j] != "m" || hm_fc[j + 1] != "e" || hm_fc[j + 2] != "r" || hm_fc[j + 3] != "g" || hm_fc[j + 4] != "e") return 0
      return 1
    }
    function hm_mark_phrases(    i) {
      hm_nm = 0
      i = 1
      while (i <= hm_n) {
        if (hm_fc[i] == "g" && (hm_phrase_gh(i) || hm_phrase_glab(i))) {
          hm_nm++
          hm_ms[hm_nm] = i
        }
        i++
      }
    }
    # Gap 0 is a phrase at e. Gap 200 is a phrase at e+200.
    function hm_phrase_in_window(e,    lo, hi, mid, hit) {
      lo = 1
      hi = hm_nm
      while (lo <= hi) {
        mid = int((lo + hi) / 2)
        hit = hm_ms[mid]
        if (hit < e) lo = mid + 1
        else if (hit > e + 200) hi = mid - 1
        else return 1
      }
      return 0
    }
    function has_sh_c_near_merge(t,    flat, i, len, c) {
      # Flatten newlines so the 200-character bound spans a multi-line -c script.
      # Own array: the statement splitter also uses ch[].
      hm_bt = sprintf("%c", 96)
      hm_vt = sprintf("%c", 11)
      flat = t
      gsub(/\n/, " ", flat)
      hm_n = split(flat, hm_fc, "")
      if (hm_n < 1) return 0
      hm_mark_phrases()
      if (hm_nm < 1) return 0
      i = 1
      while (i <= hm_n) {
        c = hm_fc[i]
        if (c != sq && c != dq && c != hm_bt && c != bs) {
          i++
          continue
        }
        len = hm_c_len(i)
        if (len > 0 && hm_phrase_in_window(i + len)) return 1
        i++
      }
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
# Scan the bounded data view without evaluating shell input. A changed
# phrase is opaque: its target must never borrow another call or checkout.
# Return 0 for a split, 1 for clear text, and 2 for scan failure.
_has_split_merge_phrase() {
  local result
  if [ "${#1}" -gt 120000 ]; then return 2; fi
  result=$(MERGE_SPLIT_INPUT="$1" awk '
    function reset() { stage = 0; active = 1; redirected = 0; option_value = 0; api = 0; wrapper = wrapper_value = gap = skip_target = 0; phrase_lit = cmd_lit = prefixed = 0 }
    # Start a phrase window at a host word. Return 1 when the word can be a host.
    function open_window(value,    host) {
      host = value; sub(/^.*\//, "", host)
      # Unquoted expansion can word-split into the host. Keep it opaque.
      # A quoted expansion before a literal last segment keeps that segment.
      if (opaque_unquoted) host = ".*"
      if ("gh" ~ ("^" host "$") || "glab" ~ ("^" host "$")) {
        stage = 1; cli = host; altered = changed || host != value
        if (!opaque_word) phrase_lit = cmd_lit = 1
        return 1
      }
      return 0
    }
    # A broken phrase: the current word starts a new window behind a prefix.
    function restart_window(value) {
      stage = 0; phrase_lit = cmd_lit = 0; altered = 0; option_value = 0; prefixed = 1
      open_window(value)
    }
    function clear_word() { w = raw = ""; changed = opaque_word = opaque_unquoted = 0 }
    # A body from a here-document is data. Its descendants are data too.
    # A here-document body keeps the current layer, as the scan before
    # #1824 read it in place. A tail body runs to the end of its text.
    # The scan reads each queued body once. The total length of all queued
    # bodies has a limit of three times the command length, so the total
    # work stays linear. Above that limit the scan fails closed.
    function queue_body(body, data, tail) {
      # A blank body holds no command, for example a blanked inert body.
      if (body !~ /[^ \t\n]/) return
      qlen += length(body)
      if (depth >= 3 || (!data && nq >= 100) || qlen > budget) scan_error = 1
      else {
        pending[++np] = body; levels[np] = depth + (data ? 0 : 1)
        datas[np] = in_data || data; tails[np] = tail
        if (!data) nq++
      }
    }
    # Index the lines of the current text once, so that each delimiter
    # search costs a lookup and not a walk to the end of the text.
    function index_lines(    k,m,p,key,L) {
      split("", lpos); split("", lcnt); split("", dpos); split("", dcnt); split("", llen)
      m = split(s, L, "\n"); p = 1
      for (k = 1; k <= m; k++) {
        key = L[k]; llen[p] = length(key)
        lpos[++lcnt[key], key] = p
        sub(/^\t+/, "", key)
        dpos[++dcnt[key], key] = p
        p += llen[p] + 1
      }
      lines_ready = 1
    }
    # Read the here-document delimiter after "<<" or "<<-". Quotes and
    # escapes are removed from the word, as the shell removes them.
    # Set hd_dash_last for "<<-" and return the word.
    function heredoc_word(    t,d,wq) {
      i++; hd_dash_last = 0; d = wq = ""
      if (substr(s, i + 1, 1) == "-") { i++; hd_dash_last = 1 }
      while (i < n && substr(s, i + 1, 1) ~ /[ \t]/) i++
      while (i < n) {
        t = substr(s, i + 1, 1)
        if (wq == "" && t ~ /[ \t\n;|&()<>]/) break
        i++
        if (wq != "" && t == wq) { wq = ""; continue }
        if (wq == "" && (t == sq || t == dq)) { wq = t; continue }
        if (t == bs && wq != sq && i < n) { d = d substr(s, ++i, 1); continue }
        d = d t
      }
      return d
    }
    # Move i from a newline to the newline after the delimiter line of one
    # here-document. Set hd_line to the start of that line. Return 0 when
    # the delimiter line is missing.
    function heredoc_end(word, dash,    cnt,lo,hi,mid,p) {
      if (!lines_ready) index_lines()
      cnt = dash ? dcnt[word] + 0 : lcnt[word] + 0
      # Find the first delimiter line that starts after position i.
      lo = 1; hi = cnt
      while (lo <= hi) {
        mid = int((lo + hi) / 2)
        p = dash ? dpos[mid, word] : lpos[mid, word]
        if (p > i) hi = mid - 1
        else lo = mid + 1
      }
      if (lo > cnt) { i = n; return 0 }
      p = dash ? dpos[lo, word] : lpos[lo, word]
      hd_line = p; i = p + llen[p]
      if (i > n) i = n
      return 1
    }
    # The substitution walk skips each pending here-document body. The body
    # is data for the walk. Return 0 when a delimiter line is missing.
    function skip_heredocs(    k) {
      for (k = 1; k <= nh; k++) if (!heredoc_end(hd_word[k], hd_dash[k])) { nh = 0; return 0 }
      nh = 0
      return 1
    }
    # The command scan queues each pending here-document body as its own
    # nested body, then continues after the delimiter line. A shell can read
    # the body as commands, and the body quotes must not change the scan of
    # the next command. Without a delimiter line, the shell reads the body
    # to the end of the input, so the scan does the same. The scan queues
    # that tail body once. A tail body reads its own tail in place, as a
    # fresh nested body would read it. Thus no text is queued again.
    function take_heredocs(    k,start) {
      for (k = 1; k <= snh; k++) {
        start = i + 1
        if (!heredoc_end(sc_word[k], sc_dash[k])) {
          if (in_tail) { i = start - 1; walk_failed = 0 }
          else { queue_body(substr(s, start), 1, 1); i = n }
          break
        }
        queue_body(substr(s, start, hd_line - start), 1, 0)
      }
      snh = 0
    }
    # Find the end of a substitution body. A backtick body ends at the next
    # unescaped backtick, as in the shell. A "$(" body walk tracks quotes,
    # comments, ANSI-C quotes, case words, and here-document bodies. In
    # command text, a body that does not close fails closed. In a
    # here-document body, which is data, this scan uses the plain
    # parenthesis count for that body and all later bodies. That count is
    # the boundary from before #1824. When the command also has a shell,
    # eval, or source word, a shell can read the body, so the walk fails
    # closed there too.
    function consume_group(endchar,    level,t,start,cq,word,cases,commandpos,comment) {
      start = i + 1
      if (endchar == "`") {
        level = 1
        while (i < n) {
          t = substr(s, ++i, 1)
          if (t == bs) { i++; continue }
          if (t == "`") { level = 0; break }
        }
        if (level && (!in_data || nested)) { scan_error = 1; i = n; return "" }
        return substr(s, start, i - start)
      }
      level = 1; nh = 0
      if (!walk_failed) {
        cq = word = ""; cases = comment = 0; commandpos = 1
        while (i < n && level) {
          t = substr(s, ++i, 1)
          if (comment) {
            if (t != "\n") continue
            comment = 0
          }
          if (t == bs && cq != sq) { word = word "!"; i++; continue }
          # An ANSI-C quote ends at the next single quote without a
          # backslash before it.
          if (cq == "" && t == "$" && substr(s, i + 1, 1) == sq) { word = word "!"; i++; cq = "$"; continue }
          if (cq == "$") { if (t == sq) cq = ""; continue }
          if (t == sq || t == dq) {
            word = word "!"
            if (cq == t) cq = ""
            else if (cq == "") cq = t
            continue
          }
          if (cq != "") continue
          if (t == "#" && (i == start || substr(s, i - 1, 1) ~ /[ \t\n;|&()]/)) {
            comment = 1; continue
          }
          if (t !~ /[ \t\n;|&()<>]/) { word = word t; continue }
          if (word != "") {
            if (word == "case" && commandpos) cases++
            else if (word == "esac" && commandpos && cases) cases--
            commandpos = 0
          }
          word = ""
          if (t == "<" && substr(s, i + 1, 1) == "<") {
            if (substr(s, i + 2, 1) == "<") i += 2
            else {
              t = heredoc_word()
              if (t != "") { hd_word[++nh] = t; hd_dash[nh] = hd_dash_last }
            }
            continue
          }
          if (t == "\n" && nh && !skip_heredocs()) break
          if (t ~ /[;|&\n()]/) commandpos = 1
          if (t == "(") level++
          if (t == ")" && !(cases && level == 1)) level--
        }
        if (!level) return substr(s, start, i - start)
        if (!in_data || nested) { scan_error = 1; i = n; return "" }
        walk_failed = 1; i = start - 1; level = 1
      }
      while (i < n && level) {
        t = substr(s, ++i, 1)
        if (t == "(") level++
        if (t == ")") level--
      }
      return substr(s, start, i - start)
    }
    function finish(    value) {
      if (w == "") {
        if (changed && stage > 0) altered = 1
        if (changed && skip_target) skip_target = 0
        clear_word(); return
      }
      # Shell arguments can contain another command. Never evaluate them.
      if (nested && raw ~ /[ \t]/) queue_body(raw, 0, 0)
      if (skip_target) { skip_target = 0; clear_word(); return }
      value = w
      if (api && value ~ /(pulls|merge_requests)\/[0-9]+\/merge/ && changed) hit = 1
      if (active && stage == 0) {
        # Wrapper options belong to the launcher, not the command window.
        if (wrapper_value) { wrapper_value = 0; clear_word(); return }
        if (wrapper && value ~ /^-/) {
          if ((wrapper == "exec" && value == "-a") ||
              (wrapper == "env" && value ~ /^(-u|-C|-S|--unset|--chdir|--split-string)$/) ||
              (wrapper == "sudo" && value ~ /^(-u|-g|-C|-p|-h|-r|-t|-T|-D|-R|-U|--user|--group|--prompt|--host|--role|--type|--command-timeout|--chdir|--chroot|--other-user|--close-from)$/) ||
              (wrapper == "time" && value ~ /^(-o|-f|--output|--format)$/) ||
              (wrapper == "nice" && value ~ /^(-n|--adjustment)$/)) wrapper_value = 1
          clear_word(); return
        }
        # These words keep the next word at command position.
        if (value ~ /^[A-Za-z_][A-Za-z0-9_]*=/ || value == "env" || value == "command" || value == "exec" || value == "builtin" || value == "time" || value == "nohup" || value == "sudo" || value == "nice" || value == "!" || value == "do" || value == "then" || value == "if" || value == "elif" || value == "else" || value == "while" || value == "until") {
          if (value !~ /^[A-Za-z_][A-Za-z0-9_]*=/) wrapper = value
          clear_word(); return
        }
        wrapper = 0
        if (!open_window(value)) {
          # Non-host prefix: keep looking for a later phrase window.
          prefixed = 1
          clear_word(); return
        }
      } else if (active) {
        if (opaque_word) value = ".*"
        if (stage == 1 && value == "api") api = 1
        if (option_value) option_value = 0
        else if (value ~ /^-/) {
          if (value == "-R" || value == "--repo" || value == "--hostname" || value == "--host") option_value = 1
          altered = 1
        } else if (stage == 1 && \
            ((("gh" ~ ("^" cli "$")) && ("pr" ~ ("^" value "$"))) || \
             (("glab" ~ ("^" cli "$")) && ("mr" ~ ("^" value "$"))))) {
          gap = opaque_word
          stage = 2; altered = altered || changed
          if (!opaque_word) phrase_lit = cmd_lit = 1
        } else if (stage == 2 && gap && \
            ((("gh" ~ ("^" cli "$")) && value == "pr") || (("glab" ~ ("^" cli "$")) && value == "mr"))) {
          # An expansion filled the subcommand slot. A later literal
          # subcommand word confirms the phrase, also after an opaque host.
          gap = 0; cmd_lit = phrase_lit = 1; altered = 1
        } else if (stage == 2 && "merge" ~ ("^" value "$")) {
          if (!opaque_word) phrase_lit = 1
          # At command position, any literal phrase word confirms a changed
          # phrase. Behind a non-host prefix, an ordinary argument list can
          # fill the window, so the host word or the subcommand word must be
          # literal. At command position, a window with no literal phrase
          # word stays clear unless a later bare PR number confirms it.
          if (!(altered || changed || redirected || depth > 0)) active = 0
          else if (prefixed ? cmd_lit : phrase_lit) { hit = 1; active = 0 }
          else if (!prefixed && !phrase_lit) stage = 3
          else restart_window(value)
        } else if (stage == 3) {
          if (value ~ /^[0-9]+$/ && !opaque_word) { hit = 1; active = 0 }
          # The same gap can shift the verb: a literal verb word after an
          # expansion in the subcommand slot and the verb slot.
          else if (gap && value == "merge" && !opaque_word) { hit = 1; active = 0 }
          else restart_window(value)
        } else if (api) {
          # Keep api set so a later path word can still match.
          active = 0
        } else {
          # Broken phrase: treat the current word as a fresh prefix window.
          restart_window(value)
        }
      }
      clear_word()
    }
    function mark_opaque() {
      if (length(w) < 128) w = w ".*"
      changed = opaque_word = 1
      if (q == "") opaque_unquoted = 1
    }
    function unknown(endchar,    level,t) {
      mark_opaque()
      if (endchar == "") return
      level = 1
      while (i < n && level) {
        t = substr(s, ++i, 1)
        if ((endchar == ")" && t == "(") || (endchar == "}" && t == "{")) level++
        if (t == endchar) level--
      }
    }
    function scan(text,    c,nx,t,rest,body) {
      s = text; n = length(s); q = w = raw = ""; changed = opaque_word = opaque_unquoted = walk_failed = snh = lines_ready = 0; reset()
      for (i = 1; i <= n; i++) {
        c = substr(s, i, 1); nx = substr(s, i + 1, 1)
        if (c == sq || c == dq) {
          if (q == c) { q = ""; changed = 1; continue }
          if (q == "") { q = c; changed = 1; continue }
        }
        if (q == "" && c == "#" && (i == 1 || substr(s, i - 1, 1) ~ /[ \t\n;|&()]/)) {
          finish()
          while (i < n && substr(s, i + 1, 1) != "\n") i++
          continue
        }
        if (q != sq && c == bs) {
          unknown(""); i++
          if (length(raw) < 4094) raw = raw bs substr(s,i,1)
          else if (nested) scan_error = 1
          continue
        }
        if (q != sq && c == "$") {
          rest = substr(s, i + 1, 70)
          if (nx == "{") { i++; unknown("}") }
          else if (nx == "(") {
            mark_opaque(); i++
            body = consume_group(")")
            queue_body(body)
          } else if (nx == sq && q == "") {
            # An ANSI-C quote ends at the next single quote without a
            # backslash before it.
            mark_opaque(); i++
            while (i < n) {
              t = substr(s, ++i, 1)
              if (t == bs) i++
              else if (t == sq) break
            }
          } else if (nx == sq || nx == dq) {
            # In double quotes, "$" before a single quote is text. A "$"
            # before a double quote starts a normal double-quoted string.
            unknown("")
          } else {
            unknown("")
            if (match(rest, /^[A-Za-z_][A-Za-z0-9_]*/)) {
              i += RLENGTH
              while (i < n && substr(s, i + 1, 1) ~ /[A-Za-z0-9_]/) i++
            }
            else if (nx ~ /[0-9@*#?$!_-]/) i++
          }
          continue
        }
        if (q != sq && c == "`") {
          mark_opaque()
          body = consume_group("`")
          queue_body(body)
          continue
        }
        if (q == "" && c == "{" && nx ~ /[ \t\n]/ && w == "") { finish(); reset(); continue }
        if (q == "" && c == "{") { unknown("}"); continue }
        # A lone "[" word is the test command, not a glob character class.
        if (q == "" && c ~ /[*?[]/ && !(c == "[" && w == "" && nx ~ /[ \t\n;|&()<>]/)) {
          unknown(c == "[" ? "]" : ""); continue
        }
        # Process substitution bodies are nested command sources.
        if (q == "" && (c == "<" || c == ">") && nx == "(") {
          finish()
          i++
          body = consume_group(")")
          queue_body(body)
          skip_target = 0
          continue
        }
        if (q == "" && c == "<" && nx == "<" && substr(s, i + 2, 1) != "<") {
          if (w ~ /^[0-9]+$/) w = ""
          finish(); redirected = 1
          body = heredoc_word()
          if (body != "") { sc_word[++snh] = body; sc_dash[snh] = hd_dash_last }
          continue
        }
        if (q == "" && (c ~ /[<>]/ || (c == "&" && nx == ">"))) {
          if (w ~ /^[0-9]+$/) w = ""
          finish(); redirected = 1
          while (i < n && substr(s, i + 1, 1) ~ /[<>|!&]/) i++
          while (i < n && substr(s, i + 1, 1) ~ /[ \t]/) i++
          # Parse the target with the normal word reader. Its substitutions
          # execute even when the redirect belongs to an ordinary command.
          skip_target = 1
          continue
        }
        if (q == "" && c ~ /[ \t\n;|&()]/) {
          finish()
          if (c ~ /[\n;|&()]/) reset()
          if (c == "\n" && snh) take_heredocs()
          continue
        }
        if (length(raw) < 4096) raw = raw c
        else if (nested) scan_error = 1
        # A long literal path still needs its final host segment.
        if (c == "/" && length(w) >= 128) w = ""
        if (length(w) < 128) {
          if (c ~ /[A-Za-z0-9_\/=-]/) w = w c
          else if (c == ".") w = w "\\."
          else w = w "!"
        }
      }
      finish()
    }
    BEGIN {
      sq = sprintf("%c",39); dq = sprintf("%c",34); bs = sprintf("%c",92)
      original = ENVIRON["MERGE_SPLIT_INPUT"]
      nested = original ~ /(^|[ \t;|&\/])(bash|sh|zsh|eval|source)([ \t]|$)/
      budget = 3 * length(original)
      scan(original)
      for (j = 1; j <= np && !hit && !scan_error; j++) {
        depth = levels[j]; in_data = datas[j]; in_tail = tails[j]; scan(pending[j])
      }
      print scan_error ? "unavailable" : (hit ? "split" : "clear")
    }
  ' 2>/dev/null) || return 2
  case "$result" in
    split) return 0 ;;
    clear) return 1 ;;
    *) return 2 ;;
  esac
}

# Scan both original and continuation-joined text. A comment must not hide
# a command by joining its final backslash to the next line (#1564).
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
    local scan_status
    _has_split_merge_phrase "$cmd"; scan_status=$?
    if [ "$scan_status" -ne 1 ]; then return 0; fi
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
  case "$cmd" in
    *pulls/*)
      pr=$(echo "$cmd" | grep -oE 'repos/[^/[:space:]]+/[^/[:space:]]+/pulls/[0-9]+/merge' | grep -oE '/pulls/[0-9]+/' | grep -oE '[0-9]+' | head -1)
      ;;
  esac

  # 1b. glab api path extraction — the /merge_requests/<N>/merge segment (#767).
  #     Same URL-path discipline as step 1: the MR iid lives in the path, so
  #     redirections cannot affect it. The `/merge` suffix keeps this from
  #     grabbing an iid out of a non-merge URL (e.g. `/merge_requests/42/notes`).
  if [ -z "$pr" ]; then
    case "$cmd" in
      *merge_requests/*)
        pr=$(echo "$cmd" | grep -oE 'merge_requests/[0-9]+/merge' | grep -oE '[0-9]+' | head -1)
        ;;
    esac
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
  #    The text-only mode (second argument `text-only`) skips this step.
  #    The dispatcher prefetch uses it, so it never calls the forge to
  #    find the key (AgDR-0256 D1). The gates keep the default mode.
  if [ -z "$pr" ] && [ "${2:-}" = text-only ]; then
    echo ""
    return 0
  fi
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
  # Gates can reuse their raw scan only when the data view is identical.
  # Standalone callers still scan the command here.
  # Any status other than clear (1) is unresolved: fail closed (A1 / #1803).
  if [ "$cmd" = "$1" ] && [ -n "${2:-}" ]; then
    [ "$2" -eq 1 ] || return 0
  else
    local split_st=0
    _has_split_merge_phrase "$cmd"
    split_st=$?
    [ "$split_st" -eq 1 ] || return 0
  fi

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
  wspan=""
  case "$cmd" in
    *tracker_pr_merge*)
      wspan=$(echo "$cmd" | grep -oE '\btracker_pr_merge\b[^|;&)]*')
      ;;
  esac
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
# --- PR metadata snapshot readers (AgDR-0256, me2resh/apexyard#1759) ---
#
# The dispatcher fetches the PR metadata one time for a merge and exports
# the trusted values as APEXYARD_PRMETA_* variables. Only the file list is
# on disk, and its SHA-256 digest is in the environment. These readers give
# a gate a snapshot value only when every check passes. Any failed check is
# a miss. A miss makes the caller fetch from the forge, as before. A miss
# never allows a merge.
#
# A reader accepts the snapshot only when APEXYARD_PRMETA_OWNER_PID equals
# the gate's $PPID. This stops a stale, inherited or forged value from a
# process that is not the dispatcher. It is a guard against accidental
# inheritance, not authentication (AgDR-0256 D2 rules 7 to 13).
#
# APEXYARD_DEBUG_PRMETA=1 prints one stderr line for each read: hit, or
# miss and the reason. The line never holds the file list.

# Prints a debug line when APEXYARD_DEBUG_PRMETA=1.
_prmeta_debug() {
  if [ "${APEXYARD_DEBUG_PRMETA:-}" = 1 ]; then
    printf 'prmeta: %s\n' "$*" >&2
  fi
  return 0
}

# Returns 0 when $1 is a valid [HOST/]OWNER/REPO value for a gh call.
# The CI gate and the dispatcher prefetch use this one check.
merge_repo_is_valid() {
  local repo="${1:-}" host="" api_repo=""
  api_repo="$repo"
  if [[ "$repo" == */*/* ]]; then
    host="${repo%%/*}"
    api_repo="${repo#*/}"
  fi
  if [[ ! "$api_repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] ||
     [[ "$api_repo" == ./* || "$api_repo" == ../* ||
        "$api_repo" == */. || "$api_repo" == */.. ]] ||
     { [ -n "$host" ] && [[ ! "$host" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]]; }; then
    return 1
  fi
  return 0
}

# Reads stdin and prints its SHA-256 digest as 64 lowercase hex characters.
# Returns 1 when no digest tool is present or the output has a bad shape.
# The tools are called with `command -p`, so the default PATH is used and
# a shell function cannot replace them. cksum is not allowed: CRC is not
# collision-resistant.
prmeta_sha256() {
  local out=""
  if command -p -v shasum >/dev/null 2>&1; then
    out=$(command -p shasum -a 256 2>/dev/null) || return 1
    out="${out%% *}"
  elif command -p -v sha256sum >/dev/null 2>&1; then
    out=$(command -p sha256sum 2>/dev/null) || return 1
    out="${out%% *}"
  elif command -p -v openssl >/dev/null 2>&1; then
    out=$(command -p openssl dgst -sha256 2>/dev/null) || return 1
    out="${out##*= }"
  else
    return 1
  fi
  out=$(printf '%s' "$out" | command -p tr 'A-F' 'a-f') || return 1
  if [[ ! "$out" =~ ^[0-9a-f]{64}$ ]]; then
    return 1
  fi
  printf '%s\n' "$out"
}

# Returns 0 when the exported scalars are bound to this gate and to the
# key <pr> <repo>, and every scalar has a valid shape. Prints the reason
# for a miss to the debug line.
_prmeta_scalars_ok() {
  local pr="${1:-}" repo="${2:-}" what="${3:-}"
  local owner="${APEXYARD_PRMETA_OWNER_PID:-}" count="${APEXYARD_PRMETA_COUNT:-}"
  local branch="${APEXYARD_PRMETA_BRANCH:-}" base="${APEXYARD_PRMETA_BASE:-}"
  if [ -z "$owner" ]; then
    _prmeta_debug "miss $what (no snapshot)"
    return 1
  fi
  if [ "$owner" != "$PPID" ]; then
    _prmeta_debug "miss $what (owner pid is not the parent)"
    return 1
  fi
  if [ -z "$pr" ] || [ -z "$repo" ] ||
     [ "${APEXYARD_PRMETA_PR:-}" != "$pr" ] ||
     [ "${APEXYARD_PRMETA_REPO:-}" != "$repo" ]; then
    _prmeta_debug "miss $what (key differs)"
    return 1
  fi
  if [[ ! "${APEXYARD_PRMETA_HEAD:-}" =~ ^[0-9a-f]{40}$ ]]; then
    _prmeta_debug "miss $what (bad head shape)"
    return 1
  fi
  if [ -z "$branch" ] || [ -z "$base" ] ||
     [[ "$branch" == *[[:cntrl:]]* ]] || [[ "$base" == *[[:cntrl:]]* ]]; then
    _prmeta_debug "miss $what (bad branch or base shape)"
    return 1
  fi
  if [[ ! "$count" =~ ^(0|[1-9][0-9]*)$ ]] || [ "${#count}" -gt 4 ] || [ "$count" -gt 3000 ]; then
    _prmeta_debug "miss $what (bad count shape)"
    return 1
  fi
  return 0
}

# prmeta_get <field> <pr> <repo>: prints one snapshot scalar and returns 0
# on a hit. <field> is head, branch, base or count. Returns 1 on a miss.
prmeta_get() {
  local field="${1:-}" value=""
  if ! _prmeta_scalars_ok "${2:-}" "${3:-}" "$field"; then
    return 1
  fi
  case "$field" in
    head) value="${APEXYARD_PRMETA_HEAD:-}" ;;
    branch) value="${APEXYARD_PRMETA_BRANCH:-}" ;;
    base) value="${APEXYARD_PRMETA_BASE:-}" ;;
    count) value="${APEXYARD_PRMETA_COUNT:-}" ;;
    *)
      _prmeta_debug "miss $field (unknown field)"
      return 1
      ;;
  esac
  _prmeta_debug "hit $field"
  printf '%s\n' "$value"
}

# prmeta_file_list <pr> <repo>: prints the snapshot file list and returns 0
# on a hit. Returns 1 on a miss.
#
# The reader reads the file one time, into memory, and uses only the value
# that it hashed (AgDR-0256 D2 rules 15 to 20). The canonical bytes are
# `printf '%s\n' "$L"`. The digest and the line count must match the
# exported values. An empty list is a miss.
prmeta_file_list() {
  local pr="${1:-}" repo="${2:-}" dir="${APEXYARD_PRMETA_DIR:-}"
  local want="${APEXYARD_PRMETA_FILES_SHA256:-}" count="${APEXYARD_PRMETA_COUNT:-}"
  local list="" sum="" lines="" mode="" LC_ALL=C
  if ! _prmeta_scalars_ok "$pr" "$repo" files; then
    return 1
  fi
  if [ "$count" = 0 ]; then
    _prmeta_debug "miss files (count is 0)"
    return 1
  fi
  if [ -z "$dir" ] || [[ ! "$want" =~ ^[0-9a-f]{64}$ ]]; then
    _prmeta_debug "miss files (no file list)"
    return 1
  fi
  if [ ! -d "$dir" ] || [ -L "$dir" ] || [ ! -O "$dir" ]; then
    _prmeta_debug "miss files (directory is not safe)"
    return 1
  fi
  mode=$(command -p ls -ld "$dir" 2>/dev/null) || mode=""
  mode="${mode%% *}"
  case "$mode" in
    drwx------|drwx------.|drwx------@) ;;
    *)
      _prmeta_debug "miss files (directory mode is not 0700)"
      return 1
      ;;
  esac
  if [ ! -f "$dir/files" ] || [ -L "$dir/files" ]; then
    _prmeta_debug "miss files (not a regular file)"
    return 1
  fi
  # Read at most 4 MiB + 1 byte. A longer result is a miss. The braces keep
  # a bash warning about a NUL byte off the gate's stderr.
  { list=$(command -p head -c 4194305 "$dir/files" 2>/dev/null); } 2>/dev/null || list=""
  if [ "${#list}" -gt 4194304 ]; then
    _prmeta_debug "miss files (file is larger than 4 MiB)"
    return 1
  fi
  if [ -z "$list" ]; then
    _prmeta_debug "miss files (empty list)"
    return 1
  fi
  if ! sum=$(printf '%s\n' "$list" | prmeta_sha256); then
    _prmeta_debug "miss files (no digest tool)"
    return 1
  fi
  if [ "$sum" != "$want" ]; then
    _prmeta_debug "miss files (digest differs)"
    return 1
  fi
  lines=$(printf '%s\n' "$list" | command -p wc -l | command -p tr -d ' ')
  if [ "$lines" != "$count" ]; then
    _prmeta_debug "miss files (line count differs)"
    return 1
  fi
  _prmeta_debug "hit files"
  printf '%s\n' "$list"
}

# Echoes the PR's base branch name, or empty on failure. Reads the snapshot
# first. On a miss it calls `gh pr view --json baseRefName`, as the review
# gate did inline before AgDR-0256. Empty <repo> gives empty, as before.
resolve_pr_base_ref() {
  local pr_number="${1:-}" cmd_repo="${2:-}" base=""
  if [ -z "$pr_number" ] || [ -z "$cmd_repo" ]; then
    echo ""
    return
  fi
  if base=$(prmeta_get base "$pr_number" "$cmd_repo"); then
    echo "$base"
    return
  fi
  base=$(apexyard_gh pr view "$pr_number" --repo "$cmd_repo" --json baseRefName -q '.baseRefName' 2>/dev/null)
  echo "$base"
}

resolve_pr_head() {
  local pr_number="$1"
  local cmd_repo="$2"
  local sha=""

  if [ -z "$pr_number" ]; then
    echo ""
    return
  fi

  # Snapshot first (AgDR-0256). A miss falls through to the forge call.
  if sha=$(prmeta_get head "$pr_number" "$cmd_repo"); then
    echo "$sha"
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
    sha=$(apexyard_gh pr view "$pr_number" --repo "$cmd_repo" --json headRefOid --jq '.headRefOid' 2>/dev/null)
  else
    sha=$(apexyard_gh pr view "$pr_number" --json headRefOid --jq '.headRefOid' 2>/dev/null)
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

  # Snapshot first (AgDR-0256). A miss falls through to the forge call.
  if branch=$(prmeta_get branch "$pr_number" "$cmd_repo"); then
    echo "$branch"
    return
  fi

  if [ "$(_forge_kind_for "$cmd_repo")" = glab ]; then
    if [ -n "$cmd_repo" ]; then
      branch=$(glab mr view "$pr_number" -R "$cmd_repo" --output json 2>/dev/null | jq -r '.source_branch // empty' 2>/dev/null)
    else
      branch=$(glab mr view "$pr_number" --output json 2>/dev/null | jq -r '.source_branch // empty' 2>/dev/null)
    fi
  elif [ -n "$cmd_repo" ]; then
    branch=$(apexyard_gh pr view "$pr_number" --repo "$cmd_repo" --json headRefName -q '.headRefName' 2>/dev/null)
  else
    branch=$(apexyard_gh pr view "$pr_number" --json headRefName -q '.headRefName' 2>/dev/null)
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
