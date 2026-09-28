#!/bin/bash
# _lib-registry-parser.sh — one shared parser for apexyard.projects.yaml,
# used by every leak hook that needs to build a scrub list of registered
# private identifiers: check-private-refs-staged.sh,
# check-private-refs-runtime.sh, block-private-refs-in-public-repos.sh.
#
# apexyard#1455 — before this file, each of those three hooks carried its own
# copy of an awk state machine, and none of them read the optional
# `public: true` field, so a registered project marked public was still
# treated as private and blocked. This file centralizes the parse so the
# field is handled once, for every consumer.
#
# apexyard#1457 review round 4 (Rex A/B, Hakim S1/S4/S5/S8/S9) — three
# rounds of entry-boundary special-casing (round 2: scope `public:` to its
# own entry; round 3: anchor on `projects:`, accept compact lists and bare
# dashes) kept finding new valid YAML shapes that made the STRUCTURAL
# parser anchor on the wrong key, or leave the `projects:` value and never
# come back — each one a fresh way to silently drop real private tokens.
# Round 4 inverted the design instead of adding another special case:
#
#   - The PRIVATE set is greedy and structure-independent. It matches
#     every `name:`, `repo:`, `repos:` item and `workspace:` value ANYWHERE
#     in the file — the same nesting/indent-blind matching the leak hooks
#     used before apexyard#1455 — with no dependence on finding a
#     `projects:` key at all. The structural parser can never remove a
#     token from this set; it can only add an EXEMPTION on top of it.
#   - The PUBLIC set is proven only. A separate, still-structural pass
#     finds tokens that belong to an entry with `public: true`, strictly
#     under the file's real top-level `projects` key (accepting the
#     unquoted, single-quoted and double-quoted spellings, with an
#     optional trailing `&anchor` or `!tag`). If the parse of that key is
#     ambiguous — for example two top-level `projects` keys, two YAML
#     documents, or a tab anywhere in the file's indentation — the public
#     set is empty for the whole file, not just for the ambiguous part.
#
# apexyard#1457 review round 5 (Hakim HIGH-7) — the round-4 exemption rule
# compared PER-VALUE OCCURRENCE COUNTS between the two passes ("exempt iff
# greedy count == public count"), on the assumption that both passes end a
# `repos:` block list on the same line. They do not: the greedy pass ends
# the list at ANY key-shaped line (including a list item that is itself a
# map, `- primary: ...`), while the public pass only ends it at the
# entry's own field column. A public entry whose `repos:` list has a map
# item before a shared slug could then have the SAME count (1) as a
# private entry holding that same slug elsewhere — exempting a token that
# is genuinely private in a second location. Fixed by comparing LINE
# NUMBERS instead of counts: both passes now record the line each value
# occurred on, and a token is exempt only when EVERY line where the greedy
# pass found it is ALSO a line the public pass attributes to a proven
# public entry. A public-pass line can then never "balance out" a private
# line the greedy pass counted elsewhere, because they are different line
# numbers by construction.
#
# Explicitly out of scope (pre-existing gaps that already fail open on
# `dev` today, named in the PR body rather than fixed here): flow-style
# YAML (`projects: [{name: ..., repo: ...}]`, `- {name: ..., repo: ...}`)
# and a value-level anchor (`repo: &r org/repo`, referenced later via
# `*r`). Both are rare in a hand-written registry and are a follow-up.
# Also out of scope (usability, not a leak — the greedy pass is
# deliberately indent/nesting-blind): a nested `name:` key with a common
# word as its value (e.g. `deploy: name: prod` in a private entry) makes
# that word a private token throughout the codebase. Named in the PR body
# as a follow-up.
#
# Usage:
#   source ".../_lib-registry-parser.sh"
#   parsed=$(registry_parse_entries "$registry"); rc=$?
#   # rc non-zero means the parse failed (e.g. the file became unreadable
#   # mid-call) — the caller must fail closed (BLOCK), never treat that as
#   # "no registered projects". A stderr warning (see below) may also
#   # explain a suppressed public set even though rc is 0.
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
# each `NAME=`/`REPO=`/`WORKSPACE=` line it governs. The flag is computed
# per unique VALUE, not per registry entry — apexyard#1457 round 4 made
# the private (name/repo/workspace) set a flat, structure-independent
# scan, so there is no longer a stable "this entry's tokens" grouping in
# that part of the stream at all. Every distinct value in the private
# (greedy) set is emitted exactly once. A separate `PAIR=name<TAB>repo`
# line — one per (name, repo) combination of an entry that actually has
# both — carries the per-entry association that a consumer needing it
# (the #1431 upstream bare-name exemption) cannot reconstruct from
# NAME=/REPO= adjacency any more. `PAIR=` lines are NOT preceded by a
# `PUBLIC=` line and do not affect `current_public` tracking; skip them
# in a `case` that only wants tokens, as shown above.
#
# When the public set is suppressed for the whole file (ambiguity — see
# above), one line is written to STDERR naming the cause (apexyard#1457
# round 5, Rex/Hakim advisory). That line is diagnostic only: it never
# appears on stdout, so it cannot be mistaken for a PUBLIC=/NAME=/PAIR=
# line by a caller reading this function's output.
#
# A missing `public:` field, a `public:` value other than exactly `true`,
# a SECOND `public:` key in the same entry, or ANY ambiguity in the
# public-set parse, all default to PUBLIC=0 (private). Every caller MUST
# fail closed — block, never silently allow — whenever this function is
# undefined (the library failed to load) or returns non-zero (apexyard#1457
# Rex B1 / Hakim HIGH-2). See each hook's own "registry parser sanity check"
# comment for the exact fail-closed gate.
#
# This whole file's guarantee — a private token can never disappear from
# the scrub list — holds for valid YAML input. A file this parser cannot
# make sense of at all (mismatched quotes, a broken block scalar, etc.) is
# outside what any of the three passes above claim to handle correctly;
# the ambiguity gate catches the shapes named above, not every possible
# malformed file.
registry_parse_entries() {
  local registry="$1"
  [ -r "$registry" ] || return 1
  awk '
    BEGIN {
      # Public (structural) pass state.
      p_state = "before"; p_top_col = -1; p_projects_seen = 0; p_ambiguous = 0
      p_ambiguous_reason = ""
      p_entry_indent = -1; p_field_col = -1; p_have_entry = 0
      p_public_count = 0; p_public_all_true = 1
      p_name_key_count = 0; p_repo_key_count = 0; p_workspace_key_count = 0
      p_repos_key_count = 0
      p_in_block = 0
      # Private (greedy) pass state.
      g_current_list = ""; g_repos_indent = -1
    }

    function unquote(s) { gsub(/^["\x27]|["\x27]$/, "", s); return s }

    function mark_ambiguous(reason) {
      if (!p_ambiguous) { p_ambiguous = 1; p_ambiguous_reason = reason }
    }

    # ------------------------------------------------------------------
    # PUBLIC (structural) pass — helper functions.
    # ------------------------------------------------------------------

    function is_projects_key(text) {
      return (text ~ /^(\x27projects\x27|"projects"|projects):[[:space:]]*((&[A-Za-z0-9_.-]+|![^[:space:]]*)[[:space:]]*)?(#.*)?$/)
    }

    function p_flush() {
      if (p_have_entry) {
        # apexyard#1457 round 5 (Hakim item 3) — an entry is public only
        # when it has EXACTLY ONE `public:` key and that key'\''s value is
        # exactly `true`. A second `public:` key (even a second `true`)
        # or any other value makes the entry private.
        #
        # apexyard#1457 round 6 (Hakim D1, advisory) — the same rule
        # extends to `name:`, `repo:`, `repos:` and `workspace:`: a
        # second occurrence of any one of them in the same entry (most
        # often a missing "- " typo that lets a whole SECOND project'\''s
        # fields land inside the entry above it as duplicate keys) also
        # makes the entry private. This does not affect the PAIR=
        # association below, which always reflects whatever the
        # structural walk actually saw.
        entry_is_public = (p_public_count == 1 && p_public_all_true &&
          p_name_key_count <= 1 && p_repo_key_count <= 1 &&
          p_workspace_key_count <= 1 && p_repos_key_count <= 1)
        if (entry_is_public) {
          for (i = 1; i <= p_nname; i++) PNL[p_enames[i], p_ename_lines[i]] = 1
          for (i = 1; i <= p_nrepo; i++) PRL[p_erepos[i], p_erepo_lines[i]] = 1
          for (i = 1; i <= p_nws; i++)  PWL[p_ews[i], p_ews_lines[i]] = 1
        }
        # apexyard#1457 round 4 — the #1431 upstream bare-name exemption in
        # check-private-refs-staged.sh needs to know which repo(s) belong
        # to the SAME registry entry as a given name, regardless of that
        # entry'\''s public/private status. Pairs a name with EVERY repo of
        # the entry, including each `repos:` item.
        for (i = 1; i <= p_nname; i++)
          for (j = 1; j <= p_nrepo; j++)
            { n_pairs++; PairList[n_pairs] = p_enames[i] "\t" p_erepos[j] }
      }
      p_have_entry = 0; p_nname = 0; p_nrepo = 0; p_nws = 0
      p_public_count = 0; p_public_all_true = 1
      p_name_key_count = 0; p_repo_key_count = 0; p_workspace_key_count = 0
      p_repos_key_count = 0
      p_current_list = ""; p_field_col = -1
    }

    # One field key ("name:", "repo:", ...) of the entry currently open in
    # the PUBLIC pass, at its own field column. `ln` is the line number
    # this key line is on, recorded alongside each value so the line-based
    # exemption correlation (apexyard#1457 round 5) can compare it against
    # the greedy pass'\''s own recorded line for the same value.
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
        # apexyard#1457 round 5 (Hakim item 3) — count EVERY `public:` key,
        # and require the value to be exactly `true`. Deferred to p_flush,
        # which knows the entry'\''s TOTAL count once it closes.
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
      # apexyard#1457 Hakim LOW-3 — strip a trailing CR so a CRLF registry
      # parses identically to LF.
      line = $0
      sub(/\r$/, "", line)

      # apexyard#1457 round 5 (Hakim item 2) — a tab ANYWHERE in a line'\''s
      # own indentation makes the whole file ambiguous for the public
      # pass. YAML forbids tabs as indentation; a registry that has one
      # cannot be trusted to have been parsed the same way this awk
      # program and a real YAML loader would agree on. Checked
      # unconditionally, before anything else, on every physical line.
      match(line, /^[ \t]*/)
      if (substr(line, 1, RLENGTH) ~ /\t/) mark_ambiguous("a tab character in the registry'\''s indentation (line " NR ")")

      # ------------------------------------------------------------------
      # PRIVATE (greedy) pass — runs on EVERY line, unconditionally, with
      # no state machine and no dependence on the PUBLIC pass below. This
      # mirrors the indent/nesting-blind matching the leak hooks used
      # before apexyard#1455: a `name:`/`repo:`/`workspace:` value, or a
      # `repos:` list item (block or flow), is private wherever it sits.
      # Each match records the CURRENT line number alongside the value
      # (apexyard#1457 round 5, Hakim HIGH-7) so exemption can be decided
      # by line-level correlation with the public pass, not raw counts.
      #
      # apexyard#1457 round 6 (Rex B6) — an armed `repos:` list must stay
      # open across EVERY dash item AT OR DEEPER THAN the column of the
      # `repos:` key itself, whatever that item looks like. The round-4/5
      # version let the `repo:`/`workspace:`/`name:` checks below match a
      # `- repo: x` or `- workspace: x` LIST ITEM first, which then
      # closed the list (by falling into a branch that resets
      # `g_current_list`) and dropped every plain item after it — a
      # fail-open regression, because the greedy set must never lose a
      # token. This gate runs FIRST, before those specific-key checks,
      # and treats a dash line at or deeper than the `repos:` key column
      # as a repos-item continuation while the list is armed: a plain
      # item is recorded as-is; a one-line map item (`- repo: x`) is
      # recorded by its value, stripping the "key:" wrapper generically
      # (not only for "repo"/"workspace"/"name" — ANY key); the list
      # stays open either way. A later, deeper-than-the-repos:-key,
      # non-dash line is read as another key of that SAME map item (Rex:
      # "for a map item, record the value of each of its keys") —
      # closing the gap that already exists on `dev` for a
      # `- primary: x` item followed by a `mirror: true` continuation.
      #
      # The list closes on a non-dash line at or left of the `repos:`
      # key column (the literal Rex rule) — and ALSO on a dash line
      # SHALLOWER than that column, which this scan only reaches once
      # the entry that owned the `repos:` list has already ended (the
      # dash then belongs to an outer list, most commonly the NEXT
      # top-level entry own opening dash). Without that second closing
      # condition, a `repos:` list left open with nothing after it would
      # swallow the following entry own fields as if they were more
      # items of THIS list, dropping that entry real name/repo token
      # from the greedy set entirely — the exact class of bug this whole
      # gate exists to prevent.
      # ------------------------------------------------------------------
      g_handled = 0
      match(line, /^[ \t]*/); g_indent = RLENGTH; g_content = substr(line, g_indent + 1)
      if (g_current_list == "repos" && g_content != "" && g_content !~ /^#/) {
        if (g_indent >= g_repos_indent && (g_content ~ /^-[[:space:]]+/ || g_content ~ /^-[[:space:]]*(#.*)?$/)) {
          gitem = g_content
          sub(/^-[[:space:]]*/, "", gitem)
          gsub(/[[:space:]]+$/, "", gitem)
          if (gitem ~ /^[A-Za-z_][A-Za-z0-9_-]*:[[:space:]]*[^[:space:]]/) {
            sub(/^[A-Za-z_][A-Za-z0-9_-]*:[[:space:]]*/, "", gitem)
            sub(/[[:space:]]*(#.*)?$/, "", gitem)
          }
          if (gitem != "") GRL[unquote(gitem), NR] = 1
          g_handled = 1
        } else if (g_content !~ /^-/ && g_indent > g_repos_indent) {
          gitem = g_content
          if (gitem ~ /^[A-Za-z_][A-Za-z0-9_-]*:[[:space:]]*[^[:space:]]/) {
            sub(/^[A-Za-z_][A-Za-z0-9_-]*:[[:space:]]*/, "", gitem)
            sub(/[[:space:]]*(#.*)?$/, "", gitem)
            if (gitem != "") GRL[unquote(gitem), NR] = 1
          }
          g_handled = 1
        } else {
          g_current_list = ""
        }
      }
      if (!g_handled) {
        if (line ~ /^[[:space:]]*-?[[:space:]]*name:[[:space:]]*[^[:space:]]/) {
          gv = line; sub(/^[[:space:]]*-?[[:space:]]*name:[[:space:]]*/, "", gv); sub(/[[:space:]]*(#.*)?$/, "", gv)
          GNL[unquote(gv), NR] = 1
          g_current_list = ""
        } else if (line ~ /^[[:space:]]*-?[[:space:]]*repo:[[:space:]]*[^[:space:]]/) {
          gv = line; sub(/^[[:space:]]*-?[[:space:]]*repo:[[:space:]]*/, "", gv); sub(/[[:space:]]*(#.*)?$/, "", gv)
          GRL[unquote(gv), NR] = 1
          g_current_list = ""
        } else if (line ~ /^[[:space:]]*-?[[:space:]]*workspace:[[:space:]]*[^[:space:]]/) {
          gv = line; sub(/^[[:space:]]*-?[[:space:]]*workspace:[[:space:]]*/, "", gv); sub(/[[:space:]]*(#.*)?$/, "", gv)
          GWL[unquote(gv), NR] = 1
          g_current_list = ""
        } else if (line ~ /^[[:space:]]*-?[[:space:]]*repos:[[:space:]]*\[/) {
          gval = line
          sub(/^[[:space:]]*-?[[:space:]]*repos:[[:space:]]*/, "", gval)
          sub(/^\[/, "", gval); sub(/\][[:space:]]*(#.*)?$/, "", gval)
          gn = split(gval, gparts, ",")
          for (gi = 1; gi <= gn; gi++) {
            gitem2 = gparts[gi]; gsub(/^[[:space:]]+|[[:space:]]+$/, "", gitem2)
            if (gitem2 != "") GRL[unquote(gitem2), NR] = 1
          }
          g_current_list = ""
        } else if (line ~ /^[[:space:]]*-?[[:space:]]*repos:[[:space:]]*(#.*)?$/) {
          g_current_list = "repos"; g_repos_indent = g_indent
        } else if (line ~ /^[[:space:]]*-[[:space:]]+/) {
          # A dash line while no repos: list is armed — not a list item
          # of anything this pass tracks; nothing to record.
        } else if (line ~ /^[[:space:]]*[A-Za-z_][A-Za-z0-9_-]*:/) {
          g_current_list = ""
        }
      }

      # ------------------------------------------------------------------
      # PUBLIC (structural) pass — finds tokens belonging to an entry
      # with `public: true`, strictly under the file'\''s real top-level
      # `projects` key. Every branch below fails closed by construction:
      # it can only ADD to PNL/PRL/PWL, never remove anything from
      # GNL/GRL/GWL above.
      # ------------------------------------------------------------------
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

          # A block scalar opened on THIS line ("key: |", "key: >-3", an
          # optional trailing comment) swallows every later line indented
          # deeper than THIS line'\''s own column, until a dedent — whatever
          # state we are in, and whatever key it is (Hakim S4: a top-level
          # block scalar whose prose happens to contain "projects:" and a
          # "- name:" line must never be read as either).
          if (p_content ~ /^[A-Za-z_][A-Za-z0-9_-]*:[[:space:]]*[|>][+-]?[0-9]*[[:space:]]*(#.*)?$/) {
            p_in_block = 1; p_block_indent = p_indent
          }

          if (p_state == "in") {
            if (p_content ~ /^-[[:space:]]*(#.*)?$/) {
              # A bare "-" line opens an entry with no key on this line at
              # all; its field column is deferred to the next real line.
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
              # A non-dash line at or left of the top-level column ends the
              # projects: value — a top-level key such as `defaults:`
              # included. Do NOT `next` past it: re-check the SAME line as
              # a possible new `projects:` key below (Hakim HIGH-5 fix
              # item 2 — S1'\''s duplicate top-level key).
              p_flush()
              p_state = "after"
            } else if (p_have_entry) {
              if (p_field_col == -1) {
                p_field_col = p_indent
                p_dispatch(p_content, NR)
              } else if (p_indent == p_field_col) {
                p_dispatch(p_content, NR)
              }
              # else: deeper than field_col — a nested map or unrelated
              # sub-structure. Not this entry'\''s own key; ignored (the
              # PRIVATE pass above already covers it independently).
            }
          }

          if (p_state != "in") {
            # Only a line at the file'\''s own top-level column can open (or
            # re-open) the projects: block — never a nested key (Hakim S5)
            # or one read out of a block scalar'\''s prose (Hakim S4, closed
            # above by the universal block-scalar skip).
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

      # apexyard#1457 round 5 (Hakim HIGH-7) — correlate by LINE, not by
      # count. A greedy line for value v is only safe to exempt when that
      # EXACT line is also one the public pass attributed to a proven
      # public entry. One pass over each greedy line-index array builds a
      # per-value (total lines, matched lines) tally; a value is exempt
      # only when every one of its lines matched.
      for (key in GNL) {
        split(key, kp, SUBSEP); v = kp[1]
        n_total[v]++
        if (key in PNL) n_matched[v]++
      }
      for (v in n_total) {
        pub = (!p_ambiguous && n_matched[v] == n_total[v])
        print "PUBLIC=" (pub ? 1 : 0)
        print "NAME=" v
      }
      delete n_total; delete n_matched

      for (key in GRL) {
        split(key, kp, SUBSEP); v = kp[1]
        n_total[v]++
        if (key in PRL) n_matched[v]++
      }
      for (v in n_total) {
        pub = (!p_ambiguous && n_matched[v] == n_total[v])
        print "PUBLIC=" (pub ? 1 : 0)
        print "REPO=" v
      }
      delete n_total; delete n_matched

      # apexyard#1457 round 4 — name<->repo pairs, gated by the SAME
      # ambiguity flag as the public set: if the structural walk could not
      # tell which `projects:` key was real, its notion of entry
      # boundaries is equally untrustworthy, so no pairing is asserted at
      # all rather than asserting a possibly-wrong one.
      if (!p_ambiguous) {
        for (i = 1; i <= n_pairs; i++) print "PAIR=" PairList[i]
      }

      for (key in GWL) {
        split(key, kp, SUBSEP); v = kp[1]
        n_total[v]++
        if (key in PWL) n_matched[v]++
      }
      for (v in n_total) {
        pub = (!p_ambiguous && n_matched[v] == n_total[v])
        print "PUBLIC=" (pub ? 1 : 0)
        print "WORKSPACE=" v
      }

      # apexyard#1457 round 5 (Rex/Hakim advisory, item 4) — one line to
      # STDERR naming why the public set is suppressed, if it is. Never
      # written to stdout, so it cannot be mistaken for a PUBLIC=/NAME=/
      # PAIR= line by a caller reading this function'\''s output.
      if (p_ambiguous) {
        print "WARN: registry_parse_entries: the public-entry exemption is suppressed for the whole file — " p_ambiguous_reason > "/dev/stderr"
      }
    }
  ' "$registry"
}

# apexyard#1457 round 3, Hakim MEDIUM (elevated to blocking); round 4,
# Rex fix item 3 ("use the same key rule" as the public-set anchor) — a
# heuristic, text-only check for "does this registry plainly look like it
# registers at least one project?", independent of the awk parse above.
# Every leak hook calls this when its own parse produced zero NAME/REPO/
# WORKSPACE tokens; if this returns true anyway, that is not "no
# registered projects" — it is the parse failing to find shapes that ARE
# there, and the caller must block rather than silently allow every
# private reference. Deliberately lenient about indentation (unlike the
# structural pass'\''s top-level-column anchor) — this is a heuristic
# sanity check, not the security-critical exemption boundary, so matching
# a `projects:`-shaped line at ANY indent is the right (more suspicious,
# not less) direction for a advisory gate.
registry_has_project_shape() {
  local registry="$1"
  [ -r "$registry" ] || return 1
  grep -qE "^[[:space:]]*([\"']projects[\"']|projects):[[:space:]]*((&[A-Za-z0-9_.-]+|![^[:space:]]*)[[:space:]]*)?(#.*)?\$" "$registry" 2>/dev/null || return 1
  grep -qE '(^|[[:space:]])name:[[:space:]]*[^[:space:]]' "$registry" 2>/dev/null || return 1
  return 0
}
