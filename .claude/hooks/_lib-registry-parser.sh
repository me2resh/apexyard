#!/bin/bash
# _lib-registry-parser.sh — one shared parser for apexyard.projects.yaml,
# used by every leak hook that needs to build a scrub list of registered
# private identifiers: check-private-refs-staged.sh,
# check-private-refs-runtime.sh, block-private-refs-in-public-repos.sh.
#
# apexyard#1455 — before this file, each of those three hooks carried its own
# copy of an awk state machine, and none of them read the optional
# `public: true` field, so a registered project marked public was still
# treated as private and blocked. This file centralizes the `public:` field
# handling so it is done once, for every consumer.
#
# apexyard#1457 review round 7 (Hakim HIGH-8, following B6/HIGH-7/HIGH-5/
# HIGH-6 in rounds 4-6) — every one of those findings traced back to the
# same decision: rounds 4-6 REWROTE the private-token scan as a new,
# hand-written, structure-independent "greedy" awk pass, meant to be a
# strict superset of the three hooks' original (pre-#1455) extraction. Each
# round found — and the next round re-broke — a fresh edge case in that
# rewrite: `public: true` bleeding across entries, an anchor guessing the
# wrong `projects:` key, a `repos:` list closing early on a one-key map
# item, an entry that opens with `- repos:` swallowing every entry after
# it. Patching the rewrite kept adding cases; it never closed the class.
#
# This version stops rewriting the private side and makes it correct BY
# CONSTRUCTION instead:
#
#   - The PRIVATE set is exactly what each hook's ORIGINAL (dev, commit
#     9ac9d9e) awk extraction produces — kept byte-for-byte, just wrapped
#     so each emitted token also carries the line it came from. `dev`'\''s
#     extraction is not one thing: `check-private-refs-staged.sh` and
#     `block-private-refs-in-public-repos.sh` share one awk program
#     (`_registry_dev_extract_standard`); `check-private-refs-runtime.sh`
#     has always had its own, slightly different one
#     (`_registry_dev_extract_runtime`), including that hook'\''s own
#     long-standing gap around block-list `repos:` items. Both are
#     reproduced here unchanged; this file does not "fix" either one, and
#     a caller can never end up with FEWER private tokens than dev found
#     for that same registry, because it is not deriving that set with new
#     logic at all — it is running dev'\''s own.
#   - The PUBLIC set is still proven, not assumed — unchanged from round 6:
#     a separate structural pass finds tokens belonging to an entry with
#     `public: true`, strictly under the file'\''s real top-level `projects`
#     key (unquoted, single- or double-quoted, with an optional `&anchor`
#     or `!tag`), with a second top-level `projects:` key, two YAML
#     documents, or ANY tab in the file'\''s indentation making the whole
#     file ambiguous (the public set then empties for the WHOLE file, and
#     one line goes to stderr naming the cause). An entry is public only
#     with EXACTLY ONE `public:` key whose value is exactly `true`; a
#     second occurrence of `name:`/`repo:`/`repos:`/`workspace:` in the
#     same entry also makes it private (closes a missing "- " typo path).
#   - A token is exempt only when EVERY line dev'\''s extraction found it on
#     is ALSO a line the structural pass attributes to a proven public
#     entry — the line-based correlation rounds 5-6 already established,
#     now comparing dev'\''s own line numbers against the structural pass'\''s.
#
# apexyard#1457 round 8 (Hakim HIGH-9/MEDIUM/LOW-1) — three targeted
# hardenings on top of round 7'\''s design, none of which touch the three
# hooks'\'' own bodies (every fix lands in this one shared file, so every
# consumer gets it the same way):
#   - `_registry_correlate` now also checks each individual WORD of a
#     multi-word `dev` value as its own token (`split_words()`), restoring
#     a behaviour dev'\''s shell loop had (word-splitting an unquoted
#     variable) that round 2'\''s move to indexed arrays lost. Applied to
#     both the private and the public side, so a legitimately public
#     multi-word token'\''s words are still exemptable.
#   - `_registry_correlate` splits each "value\tline" pair at the LAST
#     tab, not the first, and refuses to trust a proven-public value that
#     itself still contains a tab after that split — closing a forged
#     line-number path (Hakim MEDIUM).
#   - `registry_parse_entries` now runs dev'\''s private extraction against
#     a carriage-return-stripped COPY of the registry (Hakim LOW-1). This
#     is strictly MORE scanning than dev did (dev never stripped `\r`, so
#     a CRLF registry'\''s tokens never matched plain text) and can only
#     ever ADD private tokens `dev` itself never found, never remove any
#     — safe under the same "never fewer than dev" guarantee. The public
#     (structural) pass is intentionally left reading the registry as-is.
#
# Explicitly out of scope, unchanged from earlier rounds: flow-style YAML
# and a value-level anchor.
#
# Usage:
#   source ".../_lib-registry-parser.sh"
#   parsed=$(registry_parse_entries "$registry" "$style"); rc=$?
#   # $style is "runtime" for check-private-refs-runtime.sh, and anything
#   # else (conventionally "standard", or omitted) for the other two hooks.
#   # rc non-zero means the parse failed (e.g. the file became unreadable
#   # mid-call) — the caller must fail closed (BLOCK), never treat that as
#   # "no registered projects".
#   while IFS= read -r entry; do
#     case "$entry" in
#       PUBLIC=*)    current_public=${entry#PUBLIC=} ;;
#       NAME=*)      name=${entry#NAME=}; names+=("$name"); names_public+=("$current_public") ;;
#       REPO=*)      repo=${entry#REPO=}; repos+=("$repo"); repos_public+=("$current_public") ;;
#       WORKSPACE=*) ws=${entry#WORKSPACE=}; workspaces+=("$ws"); workspaces_public+=("$current_public") ;;
#       PAIR=*)      name_repo_pairs+=("${entry#PAIR=}") ;;  # "name<TAB>repo", same registry entry
#     esac
#   done <<EOF
#   $parsed
#   EOF
#
# Output contract: one `PUBLIC=0` or `PUBLIC=1` line immediately precedes
# each `NAME=`/`REPO=`/`WORKSPACE=` line it governs; every distinct value
# dev'\''s extraction produced is emitted exactly once. `PAIR=name<TAB>repo`
# lines carry the #1431 upstream bare-name exemption'\''s per-entry
# association, built by the structural pass (unaffected by public/private
# status); they are not preceded by a `PUBLIC=` line.
#
# A missing `public:` field, a `public:` value other than exactly `true`,
# a SECOND `public:`/`name:`/`repo:`/`repos:`/`workspace:` key, or ANY
# ambiguity in the public-set parse, all default to PUBLIC=0 (private).
# Every caller MUST fail closed — block, never silently allow — whenever
# this function is undefined (the library failed to load) or returns
# non-zero (apexyard#1457 Rex B1 / Hakim HIGH-2).
registry_parse_entries() {
  local registry="$1" style="${2:-standard}"
  [ -r "$registry" ] || return 1
  local privfile pubfile crfile rc
  privfile=$(mktemp 2>/dev/null) || return 1
  pubfile=$(mktemp 2>/dev/null) || { rm -f "$privfile"; return 1; }

  # apexyard#1457 round 8 (Hakim LOW-1) — run dev's private extraction
  # against a carriage-return-stripped COPY of the registry, not the
  # registry itself. dev's own awk never stripped "\r", so a CRLF
  # registry's private tokens carried a trailing "\r" that never matched
  # plain text (a pre-existing dev gap, accepted through round 7). This
  # is strictly MORE scanning than dev did, never less, so it cannot
  # regress the "never fewer tokens than dev" guarantee the differential
  # test enforces. The public (structural) pass is intentionally left
  # reading the registry as-is — untouched since round 6, and Rex found
  # nothing to fix in round 7 either.
  crfile=$(mktemp 2>/dev/null) || { rm -f "$privfile" "$pubfile"; return 1; }
  tr -d '\r' < "$registry" > "$crfile" 2>/dev/null

  if [ "$style" = "runtime" ]; then
    _registry_dev_extract_runtime "$crfile" > "$privfile" 2>/dev/null
  else
    _registry_dev_extract_standard "$crfile" > "$privfile" 2>/dev/null
  fi
  rc=$?
  rm -f "$crfile"
  if [ "$rc" -ne 0 ]; then rm -f "$privfile" "$pubfile"; return 1; fi

  _registry_public_pass "$registry" > "$pubfile"
  rc=$?
  if [ "$rc" -ne 0 ]; then rm -f "$privfile" "$pubfile"; return 1; fi

  _registry_correlate "$privfile" "$pubfile"
  rc=$?
  rm -f "$privfile" "$pubfile"
  return $rc
}

# ---------------------------------------------------------------------------
# Dev (9ac9d9e) private-token extraction — `check-private-refs-staged.sh`
# and `block-private-refs-in-public-repos.sh` share this program verbatim
# (module the `pending_name`/`NAMEREPO` bookkeeping, which fed the #1431
# exemption before this file existed and is superseded here by the
# structural pass'\''s `PAIR=` lines). Each token print gains a
# "\t<line-number>" suffix — the ONLY change from dev'\''s own program — so
# the exemption correlation below can compare by line, not by count
# (apexyard#1457 Hakim HIGH-7). WHICH tokens this finds is untouched.
# ---------------------------------------------------------------------------
_registry_dev_extract_standard() {
  local registry="$1"
  [ -r "$registry" ] || return 1
  awk '
    function unquote(value) { gsub(/^["\x27]|["\x27]$/, "", value); return value }
    /^[[:space:]]*- name:/ {
      pending_name = unquote($3)
      print "NAME=" pending_name "\t" NR; current_list = ""; next
    }
    /^[[:space:]]*repo:/ {
      repo_val = unquote($2)
      print "REPO=" repo_val "\t" NR
      pending_name = ""; current_list = ""; next
    }
    /^[[:space:]]*workspace:/ {
      print "WORKSPACE=" unquote($2) "\t" NR; current_list = ""; next
    }
    /^[[:space:]]*repos:[[:space:]]*\[/ {
      value = $0; sub(/^[^\[]*\[/, "", value); sub(/\].*$/, "", value)
      count = split(value, items, ",")
      for (i = 1; i <= count; i++) {
        item = items[i]; gsub(/^[[:space:]]+|[[:space:]]+$/, "", item)
        if (item != "") print "REPO=" unquote(item) "\t" NR
      }
      pending_name = ""; current_list = ""; next
    }
    /^[[:space:]]*repos:[[:space:]]*(#.*)?$/ { pending_name = ""; current_list = "repos"; next }
    /^[[:space:]]*[A-Za-z_][A-Za-z0-9_-]*:/ { current_list = ""; next }
    /^[[:space:]]*-[[:space:]]+/ {
      if (current_list == "repos") {
        value = $0; sub(/^[[:space:]]*-[[:space:]]+/, "", value)
        gsub(/[[:space:]]+$/, "", value); print "REPO=" unquote(value) "\t" NR
      }
    }
  ' "$registry"
}

# Dev (9ac9d9e) private-token extraction for `check-private-refs-
# runtime.sh` — its own separate program, unchanged from dev apart from
# the same "\t<line-number>" suffix. Includes that hook'\''s own long-
# standing behaviour around block-list `repos:` items (see the file
# header); not "fixed" here on purpose.
_registry_dev_extract_runtime() {
  local registry="$1"
  [ -r "$registry" ] || return 1
  awk '
    function unquote(value) { gsub(/^["\x27]|["\x27]$/, "", value); return value }
    function emit_repos(value,    n, parts, i, item) {
      gsub(/^[[:space:]]*\[[[:space:]]*/, "", value)
      gsub(/[[:space:]]*\][[:space:]]*$/, "", value)
      n = split(value, parts, ",")
      for (i = 1; i <= n; i++) {
        item = unquote(parts[i])
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", item)
        if (item != "") print "REPO=" item "\t" NR
      }
    }
    in_repos = 0
    /^[[:space:]]*- name:/ { print "NAME=" unquote($3) "\t" NR; next }
    /^[[:space:]]*repo:/ { print "REPO=" unquote($2) "\t" NR; next }
    /^[[:space:]]*repos:[[:space:]]*\[/ {
      value = $0
      sub(/^[^:]*:[[:space:]]*/, "", value)
      emit_repos(value)
      in_repos = 0
      next
    }
    /^[[:space:]]*repos:[[:space:]]*$/ { in_repos = 1; next }
    in_repos && /^[[:space:]]*-[[:space:]]+/ {
      value = $0
      sub(/^[[:space:]]*-[[:space:]]*/, "", value)
      if (value !~ /^[[:alnum:]_.-]+:/) print "REPO=" unquote(value) "\t" NR
      next
    }
    /^[^[:space:]-]/ { in_repos = 0 }
    /^[[:space:]]*workspace:/ { print "WORKSPACE=" unquote($2) "\t" NR; next }
  ' "$registry"
}

# ---------------------------------------------------------------------------
# The PUBLIC (structural) pass — unchanged since round 6 (Rex reviewed it
# again in round 7 and found nothing to fix). Finds tokens belonging to an
# entry with `public: true`, strictly under the file'\''s real top-level
# `projects` key, and the #1431 name<->repo `PAIR=` associations for every
# entry it walks. Emits its own `PUBNAME=`/`PUBREPO=`/`PUBWS=value\tline`
# lines (the "proven public, on this line" set) plus `PAIR=` lines; both
# are correlated against dev'\''s private extraction by `_registry_correlate`
# below, not by this function.
# ---------------------------------------------------------------------------
_registry_public_pass() {
  local registry="$1"
  [ -r "$registry" ] || return 1
  awk '
    BEGIN {
      p_state = "before"; p_top_col = -1; p_projects_seen = 0; p_ambiguous = 0
      p_ambiguous_reason = ""
      p_entry_indent = -1; p_field_col = -1; p_have_entry = 0
      p_public_count = 0; p_public_all_true = 1
      p_name_key_count = 0; p_repo_key_count = 0; p_workspace_key_count = 0
      p_repos_key_count = 0
      p_in_block = 0
      n_pub = 0; n_pair = 0
    }

    function unquote(s) { gsub(/^["\x27]|["\x27]$/, "", s); return s }

    function mark_ambiguous(reason) {
      if (!p_ambiguous) { p_ambiguous = 1; p_ambiguous_reason = reason }
    }

    function is_projects_key(text) {
      return (text ~ /^(\x27projects\x27|"projects"|projects):[[:space:]]*((&[A-Za-z0-9_.-]+|![^[:space:]]*)[[:space:]]*)?(#.*)?$/)
    }

    function p_flush() {
      if (p_have_entry) {
        entry_is_public = (p_public_count == 1 && p_public_all_true &&
          p_name_key_count <= 1 && p_repo_key_count <= 1 &&
          p_workspace_key_count <= 1 && p_repos_key_count <= 1)
        if (entry_is_public) {
          for (i = 1; i <= p_nname; i++) { n_pub++; PubOut[n_pub] = "PUBNAME=" p_enames[i] "\t" p_ename_lines[i] }
          for (i = 1; i <= p_nrepo; i++) { n_pub++; PubOut[n_pub] = "PUBREPO=" p_erepos[i] "\t" p_erepo_lines[i] }
          for (i = 1; i <= p_nws; i++)  { n_pub++; PubOut[n_pub] = "PUBWS=" p_ews[i] "\t" p_ews_lines[i] }
        }
        for (i = 1; i <= p_nname; i++)
          for (j = 1; j <= p_nrepo; j++)
            { n_pair++; PairOut[n_pair] = "PAIR=" p_enames[i] "\t" p_erepos[j] }
      }
      p_have_entry = 0; p_nname = 0; p_nrepo = 0; p_nws = 0
      p_public_count = 0; p_public_all_true = 1
      p_name_key_count = 0; p_repo_key_count = 0; p_workspace_key_count = 0
      p_repos_key_count = 0
      p_current_list = ""; p_field_col = -1
    }

    function p_dispatch(text, ln) {
      if (text ~ /^name:/) {
        v = text; sub(/^name:[[:space:]]*/, "", v); sub(/[[:space:]]*(#.*)?$/, "", v)
        p_nname++; p_enames[p_nname] = unquote(v); p_ename_lines[p_nname] = ln
        p_name_key_count++
        p_current_list = ""
        return
      }
      if (text ~ /^repo:/) {
        v = text; sub(/^repo:[[:space:]]*/, "", v); sub(/[[:space:]]*(#.*)?$/, "", v)
        p_nrepo++; p_erepos[p_nrepo] = unquote(v); p_erepo_lines[p_nrepo] = ln
        p_repo_key_count++
        p_current_list = ""
        return
      }
      if (text ~ /^workspace:/) {
        v = text; sub(/^workspace:[[:space:]]*/, "", v); sub(/[[:space:]]*(#.*)?$/, "", v)
        p_nws++; p_ews[p_nws] = unquote(v); p_ews_lines[p_nws] = ln
        p_workspace_key_count++
        p_current_list = ""
        return
      }
      if (text ~ /^public:/) {
        p_public_count++
        if (text !~ /^public:[[:space:]]+true[[:space:]]*(#.*)?$/) p_public_all_true = 0
        p_current_list = ""
        return
      }
      if (text ~ /^repos:[[:space:]]*\[/) {
        val = text
        sub(/^repos:[[:space:]]*/, "", val)
        sub(/^\[/, "", val); sub(/\][[:space:]]*(#.*)?$/, "", val)
        n = split(val, parts, ",")
        for (k = 1; k <= n; k++) {
          item = parts[k]; gsub(/^[[:space:]]+|[[:space:]]+$/, "", item)
          if (item != "") { p_nrepo++; p_erepos[p_nrepo] = unquote(item); p_erepo_lines[p_nrepo] = ln }
        }
        p_repos_key_count++
        p_current_list = ""
        return
      }
      if (text ~ /^repos:[[:space:]]*(#.*)?$/) {
        p_repos_key_count++
        p_current_list = "repos"
        return
      }
      p_current_list = ""
    }

    {
      line = $0
      sub(/\r$/, "", line)

      match(line, /^[ \t]*/)
      if (substr(line, 1, RLENGTH) ~ /\t/) mark_ambiguous("a tab character in the registry'\''s indentation (line " NR ")")

      p_skip = 0
      if (p_in_block) {
        match(line, /^[ \t]*/); p_ind = RLENGTH
        if (line == "" || p_ind > p_block_indent) p_skip = 1
        else p_in_block = 0
      }

      if (!p_skip) {
        match(line, /^[ \t]*/); p_indent = RLENGTH
        p_content = substr(line, p_indent + 1)

        if (p_content != "" && p_content !~ /^#/) {
          if (p_top_col == -1) p_top_col = p_indent

          if (p_content ~ /^[A-Za-z_][A-Za-z0-9_-]*:[[:space:]]*[|>][+-]?[0-9]*[[:space:]]*(#.*)?$/) {
            p_in_block = 1; p_block_indent = p_indent
          }

          if (p_state == "in") {
            if (p_content ~ /^-[[:space:]]*(#.*)?$/) {
              if (p_entry_indent == -1) p_entry_indent = p_indent
              if (p_indent == p_entry_indent) {
                p_flush(); p_have_entry = 1
              } else if (p_indent < p_entry_indent) {
                p_flush()
                if (p_indent <= p_top_col) p_state = "after"
              }
            } else if (p_content ~ /^-[[:space:]]+/) {
              if (p_entry_indent == -1) p_entry_indent = p_indent
              if (p_indent == p_entry_indent) {
                p_flush(); p_have_entry = 1
                p_rest = p_content
                sub(/^-[[:space:]]+/, "", p_rest)
                p_field_col = p_indent + (length(p_content) - length(p_rest))
                p_dispatch(p_rest, NR)
              } else if (p_indent < p_entry_indent) {
                p_flush()
                if (p_indent <= p_top_col) p_state = "after"
              } else if (p_have_entry && p_current_list == "repos") {
                p_item = p_content
                sub(/^-[[:space:]]+/, "", p_item)
                gsub(/[[:space:]]+$/, "", p_item)
                if (p_item != "") { p_nrepo++; p_erepos[p_nrepo] = unquote(p_item); p_erepo_lines[p_nrepo] = NR }
              }
            } else if (p_indent <= p_top_col) {
              p_flush()
              p_state = "after"
            } else if (p_have_entry) {
              if (p_field_col == -1) {
                p_field_col = p_indent
                p_dispatch(p_content, NR)
              } else if (p_indent == p_field_col) {
                p_dispatch(p_content, NR)
              }
            }
          }

          if (p_state != "in") {
            if (p_indent == p_top_col && is_projects_key(p_content)) {
              if (p_projects_seen) mark_ambiguous("a second top-level projects: key (line " NR ")")
              p_projects_seen = 1
              p_state = "in"
              p_entry_indent = -1
              p_have_entry = 0
            }
          }
        }
      }
    }
    END {
      p_flush()
      if (p_ambiguous) {
        print "WARN: registry_parse_entries: the public-entry exemption is suppressed for the whole file — " p_ambiguous_reason > "/dev/stderr"
      } else {
        for (i = 1; i <= n_pub; i++) print PubOut[i]
        for (i = 1; i <= n_pair; i++) print PairOut[i]
      }
    }
  ' "$registry"
}

# ---------------------------------------------------------------------------
# Correlates dev'\''s private extraction (privfile: NAME=/REPO=/WORKSPACE=
# value\tline) against the structural public pass (pubfile: PUBNAME=/
# PUBREPO=/PUBWS=value\tline, plus PAIR=name\trepo lines). A value is
# exempt only when EVERY line dev'\''s extraction found it on is also a line
# the public pass proved belongs to a public entry (apexyard#1457 Hakim
# HIGH-7) — never a raw count comparison.
# ---------------------------------------------------------------------------
_registry_correlate() {
  local privfile="$1" pubfile="$2"
  awk -v pubfile="$pubfile" '
    # apexyard#1457 round 8 (Hakim MEDIUM) — split each "value\tline" pair
    # at the LAST tab, not the first. A value that itself contains an
    # embedded tab (crafted or otherwise) used to let the FIRST-tab split
    # misread that embedded tab as the value/line separator, so an
    # attacker-chosen digit string right after it was read as the line
    # number, forging a PubN/PubR/PubW entry at an arbitrary line. The
    # trailing "\t[^\t]*$" match always lands on the real, final tab
    # regardless of how many earlier tabs the value itself holds.
    function last_tab_pos(s) {
      if (match(s, /\t[^\t]*$/)) return RSTART
      return 0
    }
    # apexyard#1457 round 8 (Hakim HIGH-9) — dev'\''s own hooks looped over
    # a space-joined string, so the shell split every multi-word token
    # (e.g. a `repos:` map item like "primary: acme-org/x", or a one-key
    # `- repo: acme-org/x` list item, both of which dev'\''s extraction
    # emits as one value with an embedded space) into separate words and
    # checked each word on its own. Round 2'\''s array change checks each
    # emitted value as ONE whole string instead, which a normal commit or
    # issue body never contains verbatim, silently dropping the real
    # per-word match dev had. This restores dev'\''s per-word behaviour once,
    # here, so every consumer (staged, runtime, public-tracker) gets it
    # without re-implementing it three times. Populates out[1..n]; out[1]
    # is always v itself, and is safe to keep even when it can never
    # match anything on its own, because the individual words that CAN
    # match are always included alongside it.
    function split_words(v, out,    n, m, parts, i, w, j, dup) {
      n = 0
      out[++n] = v
      if (v ~ /[ \t]/) {
        m = split(v, parts, /[ \t]+/)
        for (i = 1; i <= m; i++) {
          w = parts[i]
          if (w == "") continue
          dup = 0
          for (j = 1; j <= n; j++) { if (out[j] == w) { dup = 1; break } }
          if (!dup) out[++n] = w
        }
      }
      return n
    }
    function load_public(    tabpos, pkv, pln, v, warr, nw, wi) {
      while ((getline pline < pubfile) > 0) {
        if (pline ~ /^PAIR=/) { n_pair++; PairOut[n_pair] = substr(pline, 6); continue }
        tabpos = last_tab_pos(pline)
        if (tabpos == 0) continue
        pkv = substr(pline, 1, tabpos - 1)
        pln = substr(pline, tabpos + 1) + 0
        if (pkv ~ /^PUBNAME=/) v = substr(pkv, 9)
        else if (pkv ~ /^PUBREPO=/) v = substr(pkv, 9)
        else if (pkv ~ /^PUBWS=/) v = substr(pkv, 7)
        else continue
        # apexyard#1457 round 8 (Hakim MEDIUM, second half) — a proven-
        # public VALUE that itself still contains a tab, even after the
        # last-tab split above correctly located the real line-number
        # separator, is never trusted as proof of anything. It contributes
        # no PubN/PubR/PubW entry at all, so any private token sharing
        # that exact (value, line) stays private by default.
        if (v ~ /\t/) continue
        nw = split_words(v, warr)
        for (wi = 1; wi <= nw; wi++) {
          if (pkv ~ /^PUBNAME=/) PubN[warr[wi], pln] = 1
          else if (pkv ~ /^PUBREPO=/) PubR[warr[wi], pln] = 1
          else if (pkv ~ /^PUBWS=/) PubW[warr[wi], pln] = 1
        }
      }
      close(pubfile)
    }
    BEGIN { load_public() }
    {
      tabpos = last_tab_pos($0)
      if (tabpos == 0) next
      kv = substr($0, 1, tabpos - 1)
      ln = substr($0, tabpos + 1) + 0
      if (kv ~ /^NAME=/) {
        v = substr(kv, 6)
        nw = split_words(v, warr)
        for (wi = 1; wi <= nw; wi++) {
          wv = warr[wi]; key = wv SUBSEP ln
          if (!(key in SeenN)) { SeenN[key] = 1; totalN[wv]++; if (key in PubN) matchedN[wv]++ }
        }
      } else if (kv ~ /^REPO=/) {
        v = substr(kv, 6)
        nw = split_words(v, warr)
        for (wi = 1; wi <= nw; wi++) {
          wv = warr[wi]; key = wv SUBSEP ln
          if (!(key in SeenR)) { SeenR[key] = 1; totalR[wv]++; if (key in PubR) matchedR[wv]++ }
        }
      } else if (kv ~ /^WORKSPACE=/) {
        v = substr(kv, 11)
        nw = split_words(v, warr)
        for (wi = 1; wi <= nw; wi++) {
          wv = warr[wi]; key = wv SUBSEP ln
          if (!(key in SeenW)) { SeenW[key] = 1; totalW[wv]++; if (key in PubW) matchedW[wv]++ }
        }
      }
    }
    END {
      for (v in totalN) {
        pub = (matchedN[v] == totalN[v])
        print "PUBLIC=" (pub ? 1 : 0)
        print "NAME=" v
      }
      for (v in totalR) {
        pub = (matchedR[v] == totalR[v])
        print "PUBLIC=" (pub ? 1 : 0)
        print "REPO=" v
      }
      for (v in totalW) {
        pub = (matchedW[v] == totalW[v])
        print "PUBLIC=" (pub ? 1 : 0)
        print "WORKSPACE=" v
      }
      for (i = 1; i <= n_pair; i++) print "PAIR=" PairOut[i]
    }
  ' "$privfile"
}

# apexyard#1457 round 3, Hakim MEDIUM (elevated to blocking); round 4,
# Rex fix item 3 ("use the same key rule" as the public-set anchor) — a
# heuristic, text-only check for "does this registry plainly look like it
# registers at least one project?", independent of the parse above. Every
# leak hook calls this when its own parse produced zero NAME/REPO/
# WORKSPACE tokens; if this returns true anyway, that is not "no
# registered projects" — it is the parse failing to find shapes that ARE
# there, and the caller must block rather than silently allow every
# private reference.
registry_has_project_shape() {
  local registry="$1"
  [ -r "$registry" ] || return 1
  grep -qE "^[[:space:]]*([\"']projects[\"']|projects):[[:space:]]*((&[A-Za-z0-9_.-]+|![^[:space:]]*)[[:space:]]*)?(#.*)?\$" "$registry" 2>/dev/null || return 1
  grep -qE '(^|[[:space:]])name:[[:space:]]*[^[:space:]]' "$registry" 2>/dev/null || return 1
  return 0
}
