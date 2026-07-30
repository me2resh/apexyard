#!/bin/bash
# Heredoc-body stripping — an ADDITIVE-refinement helper, never a gate filter.
#
# Not a hook itself (prefixed `_lib-`). Sourced by `_lib-extract-push-ref.sh`
# via `. "$(dirname "$0")/_lib-strip-heredoc.sh"`.
#
# WHY THIS EXISTS, AND WHY IT IS ITS OWN FILE (me2resh/apexyard#1066)
# --------------------------------------------------------------------
# A heredoc body (a commit message, a PR body, review prose written via
# `cat > file <<EOF ... EOF`) is literal payload, not a command. Scanning
# the WHOLE raw command text for `git push` / `git commit` — as
# `is_tag_push` / `extract_push_ref` originally did — matches prose that
# merely *mentions* a git command before the real invocation. This function
# strips CONFIRMED heredoc bodies so the ref-extraction / tag-push-exemption
# questions in `_lib-extract-push-ref.sh` see the real command, not prose.
#
# It was split into its own file (rather than living inline in
# `_lib-extract-push-ref.sh`) because it is a genuinely standalone parsing
# primitive with more than one consumer: `_lib-extract-push-ref.sh` uses it
# today, and `verify-commit-refs.sh`'s `resolve_commit_workdir()` (added in
# #1073) parses the same kind of raw-command-text shape (`git -C <path>`,
# `cd <path> &&`) and is a natural second adopter, per the coordinator's
# review. See docs/agdr/AgDR-0113-heredoc-stripper-additive-only.md for the
# full three-way design record and — critically — the governance rule
# below, which every adopter of this file MUST follow.
#
# ============================================================================
# GOVERNANCE — READ BEFORE USING THIS FUNCTION ANYWHERE NEW
# ============================================================================
# `strip_heredoc_bodies` is a SUBTRACTIVE pre-filter: it decides what a
# caller is even ALLOWED to see. That is fundamentally different from
# `extract_push_ref`, which is ADDITIVE: it tries to answer "what is the
# ref", and if it gets that wrong, the caller still has the raw command and
# an independent local-state fallback to fall back on — the failure is
# local and visible.
#
# A bug in a SUBTRACTIVE filter is silent and global: if this function ever
# over-strips (removes text that was actually a real, executing command),
# and a caller used its OUTPUT to decide "is there even a git push/commit
# command here at all", that caller's gate silently never fires. This is
# not hypothetical — it is exactly the bug a security review caught in the
# first version of the #1066 fix (me2resh/apexyard#1075): both
# `validate-branch-name.sh` and `block-main-push.sh` ran their presence
# checks (`grep -qE 'git push'` / `'git commit'`) against text this
# function had already filtered, so eight distinct malformed-heredoc shapes
# (see the AgDR) made the filter eat the real command, and the gate exited
# 0 without ever asking whether a push was happening.
#
# THE RULE: use `strip_heredoc_bodies` (directly, or via `extract_push_ref` /
# `is_tag_push` in `_lib-extract-push-ref.sh`) ONLY to refine an ADDITIVE
# question — "given that a real git operation is independently known (from
# RAW, unfiltered text) to be happening, which ref / is it exempt" — and
# NEVER to decide whether a gate should fire at all. The presence check
# that answers "is there a push/commit here" MUST always run against the
# raw, unfiltered command string. If you are about to write
# `if echo "$STRIPPED_TEXT" | grep -q 'git push'` as a gating condition,
# stop — that is exactly the mistake this comment exists to prevent.
#
# Strips heredoc BODY text (and the heredoc's own start/terminator lines)
# from a command string, but ONLY for heredocs that are CONFIRMED — both:
#
#   1. ANCHORED: after the delimiter word, the rest of that line (trimmed of
#      leading whitespace) is empty, a `#` comment, or a plain output
#      redirection (`>`, `>>`, an fd redirect like `2>`, or `&>`) — nothing
#      else. A `<<` sitting inside a quoted string, an arithmetic
#      expression (`$((1 << N))`), or followed by `&&` / `||` / `;` / a
#      pipe / another `<<` fails this check and is never treated as a
#      heredoc start. This is what makes `"shift with << N" && git push
#      origin main` and `X=$((1 << N)); git push origin main` and `git
#      commit -m "use a << b shift"` all leave the real command untouched.
#
#   2. TERMINATED: scanning forward from the candidate start, some later
#      line — after tab-stripping for `<<-` — exactly equals the delimiter.
#      If no such line exists anywhere in the rest of the command, the
#      candidate is REJECTED: nothing is stripped for it, and the command
#      from that point on is returned UNCHANGED. An unterminated heredoc
#      (or one whose delimiter this parser can't compute exactly — a
#      backslash-escaped delimiter like `<<E\OF`, a quoted multi-word
#      delimiter like `<<'E O F'`, a delimiter containing a `.` like
#      `<<END.OF`) will therefore never find its (differently-shaped) real
#      terminator line and is safely left un-stripped rather than eating
#      the remainder of the command looking for a terminator that will
#      never arrive. See the AgDR for the deliberate residue this leaves:
#      those exotic delimiter shapes are recognised as *heredoc-like* but
#      never actually stripped, which is safe (nothing is hidden) but means
#      a LEGITIMATE use of one of those shapes doesn't get the "prose is
#      hidden from presence checks" nicety either. Given presence checks
#      never consult this function's output (per the governance rule
#      above), that residue has no safety impact — only a minor UX one.
#
# A line containing a here-STRING (`<<<`) is never treated as a heredoc
# start, so `wc -l <<< "$var"` is left untouched.
#
# Returns: prints the command with CONFIRMED heredoc bodies removed. Always
# exits 0.
strip_heredoc_bodies() {
  local cmd="$1"
  local -a lines=()
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    lines+=("$line")
  done <<< "$cmd"

  local n=${#lines[@]}
  local -a skip=()
  local -a is_start=()
  local -a prefix=()
  local idx
  for ((idx = 0; idx < n; idx++)); do
    skip[idx]=0
    is_start[idx]=0
    prefix[idx]=""
  done

  local tab
  tab="$(printf '\t')"

  local i=0
  while [ "$i" -lt "$n" ]; do
    if [ "${skip[i]}" -eq 1 ]; then
      i=$((i + 1))
      continue
    fi

    local cur="${lines[i]}"
    local marker=""
    case "$cur" in
      *'<<<'*) marker="" ;; # here-string on this line — never a heredoc start
      *'<<'*)
        marker=$(echo "$cur" \
          | grep -oE '<<-?[[:space:]]*['"'"'"]?[A-Za-z_][A-Za-z0-9_]*['"'"'"]?' \
          | head -1)
        ;;
    esac

    if [ -z "$marker" ]; then
      i=$((i + 1))
      continue
    fi

    # --- Anchor check -------------------------------------------------
    # Everything after the matched delimiter word, on the SAME line, must
    # be empty / a comment / a plain redirection. Anything else (a closing
    # quote followed by more text, `&&`, `||`, `;`, a bare pipe, another
    # `<<`) means this `<<` was not actually in redirect position.
    local rest rest_trimmed anchor_ok
    rest="${cur#*"$marker"}"
    rest_trimmed="${rest#"${rest%%[![:space:]]*}"}"
    anchor_ok=0
    case "$rest_trimmed" in
      '') anchor_ok=1 ;;
      '#'*) anchor_ok=1 ;;
      '>'*) anchor_ok=1 ;;
      '&>'*) anchor_ok=1 ;;
      [0-9]'>'*) anchor_ok=1 ;;
    esac

    if [ "$anchor_ok" -ne 1 ]; then
      i=$((i + 1))
      continue
    fi

    # --- Compute the delimiter word -----------------------------------
    local strip_tabs terminator
    strip_tabs=0
    case "$marker" in
      '<<-'*) strip_tabs=1 ;;
    esac
    terminator="${marker#<<}"
    terminator="${terminator#-}"
    terminator="${terminator#"${terminator%%[![:space:]]*}"}"
    case "$terminator" in
      \"*\") terminator="${terminator#\"}"; terminator="${terminator%\"}" ;;
      \'*\') terminator="${terminator#\'}"; terminator="${terminator%\'}" ;;
    esac

    # --- Confirm termination by scanning FORWARD ----------------------
    local j found check_line
    found=0
    for ((j = i + 1; j < n; j++)); do
      check_line="${lines[j]}"
      if [ "$strip_tabs" -eq 1 ]; then
        while [ "${check_line:0:1}" = "$tab" ]; do
          check_line="${check_line:1}"
        done
      fi
      if [ "$check_line" = "$terminator" ]; then
        found=1
        break
      fi
    done

    if [ "$found" -ne 1 ]; then
      # Unterminated (or a delimiter shape we can't compute exactly, so it
      # will never match) — do NOT strip. Move past just this candidate;
      # everything from here on is left completely untouched.
      i=$((i + 1))
      continue
    fi

    # Confirmed: lines i+1..j are body+terminator — drop them. Line i keeps
    # only whatever precedes the heredoc operator (it may hold a real
    # command, e.g. `cd foo && cat > x.txt <<EOF`).
    prefix[i]="${cur%%<<*}"
    is_start[i]=1
    local k
    for ((k = i + 1; k <= j; k++)); do
      skip[k]=1
    done
    i=$((j + 1))
  done

  local out=""
  for ((idx = 0; idx < n; idx++)); do
    if [ "${skip[idx]}" -eq 1 ]; then
      continue
    fi
    if [ "${is_start[idx]}" -eq 1 ]; then
      out+="${prefix[idx]}"$'\n'
    else
      out+="${lines[idx]}"$'\n'
    fi
  done

  printf '%s' "$out"
}
