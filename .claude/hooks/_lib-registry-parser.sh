#!/bin/bash
# _lib-registry-parser.sh — one shared awk parser for apexyard.projects.yaml,
# used by every leak hook that needs to build a scrub list of registered
# private identifiers: check-private-refs-staged.sh,
# check-private-refs-runtime.sh, block-private-refs-in-public-repos.sh.
#
# apexyard#1455 — before this file, each of those three hooks carried its own
# copy of this awk state machine, and none of them read the optional
# `public: true` field, so a registered project marked public was still
# treated as private and blocked. This file centralizes the parse so the
# field is handled once, for every consumer.
#
# apexyard#1457 review round 2 (Rex B2 / Hakim HIGH-1) — the first version
# started a new entry only on a `- name:` line and never closed one on a
# dedent, so `public: true` could bleed into a NEIGHBOURING entry or a
# nested map / block scalar inside the SAME entry. Fixed by tracking the
# list item's own indent column and scoping `public:` strictly to it.
#
# apexyard#1457 review round 3 (Rex B4 / Hakim HIGH-3, HIGH-4) — the round-2
# parser anchored its entry column on the FIRST `- ` line anywhere in the
# file, so a top-level list or block scalar before `projects:` locked the
# column to the wrong value and dropped every real entry (HIGH-3). It also
# required a `repos:` block-list item to sit STRICTLY deeper than the
# `repos:` key, so a compact sequence (item dash at the SAME column as the
# key — valid YAML, and PyYAML's default output shape) lost its items
# (HIGH-4 / N1b, N2b), and it had no way to open an entry from a bare `-`
# line whose keys follow on the next lines (HIGH-4 / N4). This version:
#   - anchors the entry column on the first list item found AFTER the
#     `projects:` key, and ignores every line outside that key's value
#     entirely (a state machine: before / in / after);
#   - accepts a `repos:` item at any indent once `repos:` is armed for the
#     current entry, not only strictly-deeper ones;
#   - opens a new entry on a bare `-` line too, deferring its field column
#     to whichever indent the entry's first real key line uses;
#   - emits a safety-net `PUBLIC=0` token for any `name:`/`repo:`/
#     `workspace:` line the structural parse cannot place in an entry, so
#     an unanticipated shape still fails closed instead of dropping it.
#
# Entry-boundary contract:
#   - `entry_indent` is set ONLY from the first list item (`-`) encountered
#     after the `projects:` key line — never from a list or block scalar
#     that appears earlier in the file.
#   - Every later list item at that SAME column starts a new entry,
#     regardless of which key it opens (`- name:`, `- repo:`, a bare `-`
#     with its keys on the next lines, ...).
#   - Any non-dash line at or to the left of the `projects:` key's own
#     column ends the projects: value — a top-level key such as
#     `defaults:` included — and everything after that is ignored.
#   - A field is only read as one of THIS entry's top-level keys
#     (`name:`/`repo:`/`repos:`/`workspace:`/`public:`) when it sits at the
#     entry's own field column. A `public: true` nested one level deeper
#     (inside a map, or a block scalar body) is at a DEEPER column and is
#     never read as the entry's flag.
#   - A block scalar (`key: |` / `key: >`, with optional chomp/indent
#     indicators) swallows every following line indented deeper than its
#     own key, so a coincidental `public: true` string inside prose never
#     reaches the parser as a key.
#
# Usage:
#   source ".../_lib-registry-parser.sh"
#   parsed=$(registry_parse_entries "$registry"); rc=$?
#   # rc non-zero means the parse failed (e.g. the file became unreadable
#   # mid-call) — the caller must fail closed (BLOCK), never treat that as
#   # "no registered projects". A zero-token result alongside a registry
#   # that plainly has a projects:/name: shape is ALSO suspicious — see
#   # registry_has_project_shape() below and each hook's sanity gate.
#   while IFS= read -r entry; do
#     case "$entry" in
#       PUBLIC=*)    current_public=${entry#PUBLIC=} ;;
#       NAME=*)      name=${entry#NAME=}; names+=("$name"); names_public+=("$current_public") ;;
#       REPO=*)      repo=${entry#REPO=}; repos+=("$repo"); repos_public+=("$current_public") ;;
#       WORKSPACE=*) ws=${entry#WORKSPACE=}; workspaces+=("$ws"); workspaces_public+=("$current_public") ;;
#     esac
#   done <<EOF
#   $parsed
#   EOF
#
# Output contract: one `PUBLIC=0` or `PUBLIC=1` line precedes every entry's
# NAME=/REPO=/WORKSPACE= lines. A consumer that tracks "current_public" as it
# reads, and pairs it with each NAME=/REPO=/WORKSPACE= line that follows,
# gets a per-entry public flag even though names/repos/workspaces are flat
# streams (an entry can hold zero or many of each — a multi-repo project has
# one NAME but several REPO lines, all sharing that entry's PUBLIC flag). A
# safety-net token (apexyard#1457 round 3, Rex) is emitted the same way, as
# its own `PUBLIC=0` line followed by a single token — always private,
# since it could not be scoped to any real entry.
#
# A missing `public:` field defaults to PUBLIC=0 (private). Every caller
# MUST fail closed — block, never silently allow — whenever this function is
# undefined (the library failed to load) or returns non-zero (apexyard#1457
# Rex B1 / Hakim HIGH-2). See each hook's own "registry parser sanity check"
# comment for the exact fail-closed gate.
registry_parse_entries() {
  local registry="$1"
  [ -r "$registry" ] || return 1
  awk '
    BEGIN {
      state = "before"; projects_key_indent = -1; entry_indent = -1
      field_col = -1; in_block = 0
    }

    function unquote(s) { gsub(/^["\x27]|["\x27]$/, "", s); return s }

    function flush() {
      if (have_entry) {
        print "PUBLIC=" (is_public ? 1 : 0)
        for (i = 1; i <= nname; i++) print "NAME=" enames[i]
        for (i = 1; i <= nrepo; i++) print "REPO=" erepos[i]
        for (i = 1; i <= nws; i++) print "WORKSPACE=" ews[i]
      }
      have_entry = 0; is_public = 0; nname = 0; nrepo = 0; nws = 0
      current_list = ""; field_col = -1
    }

    # apexyard#1457 round 3, Rex safety net — a name:/repo:/workspace: line
    # the structural parse could not place in any entry is emitted anyway,
    # as its own always-private one-token "entry". An unanticipated YAML
    # shape then fails closed (still scrubbed) instead of vanishing.
    function safety_net(text) {
      if (text ~ /^name:[[:space:]]*[^[:space:]]/) {
        v = text; sub(/^name:[[:space:]]*/, "", v); sub(/[[:space:]]*(#.*)?$/, "", v)
        print "PUBLIC=0"; print "NAME=" unquote(v)
        return
      }
      if (text ~ /^repo:[[:space:]]*[^[:space:]]/) {
        v = text; sub(/^repo:[[:space:]]*/, "", v); sub(/[[:space:]]*(#.*)?$/, "", v)
        print "PUBLIC=0"; print "REPO=" unquote(v)
        return
      }
      if (text ~ /^workspace:[[:space:]]*[^[:space:]]/) {
        v = text; sub(/^workspace:[[:space:]]*/, "", v); sub(/[[:space:]]*(#.*)?$/, "", v)
        print "PUBLIC=0"; print "WORKSPACE=" unquote(v)
        return
      }
    }

    # Reads one field key ("name:", "repo:", ...) of the CURRENT entry, at
    # its own field column. Only called when the caller has already
    # confirmed the line sits at field_col.
    function dispatch(text) {
      # A block scalar opened on THIS key line ("notes: |", "notes: >-3",
      # an optional trailing comment) swallows everything indented deeper
      # than field_col until a dedent — regardless of which key it is.
      if (text ~ /^[A-Za-z_][A-Za-z0-9_-]*:[[:space:]]*[|>][+-]?[0-9]*[[:space:]]*(#.*)?$/) {
        in_block = 1; block_indent = field_col
      }

      if (text ~ /^name:/) {
        v = text; sub(/^name:[[:space:]]*/, "", v); sub(/[[:space:]]*(#.*)?$/, "", v)
        nname++; enames[nname] = unquote(v)
        current_list = ""
        return
      }
      if (text ~ /^repo:/) {
        v = text; sub(/^repo:[[:space:]]*/, "", v); sub(/[[:space:]]*(#.*)?$/, "", v)
        nrepo++; erepos[nrepo] = unquote(v)
        current_list = ""
        return
      }
      if (text ~ /^workspace:/) {
        v = text; sub(/^workspace:[[:space:]]*/, "", v); sub(/[[:space:]]*(#.*)?$/, "", v)
        nws++; ews[nws] = unquote(v)
        current_list = ""
        return
      }
      # Require at least one space (or the value is EOL/comment) after the
      # colon — apexyard#1457 Rex nit / Hakim HIGH-1 "public:true" shape:
      # YAML reads a colon with no following space as a plain scalar, not
      # a mapping key, so it must not be read as the flag.
      if (text ~ /^public:[[:space:]]+true[[:space:]]*(#.*)?$/) {
        is_public = 1
        current_list = ""
        return
      }
      if (text ~ /^repos:[[:space:]]*\[/) {
        val = text
        sub(/^repos:[[:space:]]*/, "", val)
        sub(/^\[/, "", val); sub(/\][[:space:]]*(#.*)?$/, "", val)
        n = split(val, parts, ",")
        for (k = 1; k <= n; k++) {
          item = parts[k]; gsub(/^[[:space:]]+|[[:space:]]+$/, "", item)
          if (item != "") { nrepo++; erepos[nrepo] = unquote(item) }
        }
        current_list = ""
        return
      }
      if (text ~ /^repos:[[:space:]]*(#.*)?$/) {
        # apexyard#1457 round 3, Rex B4.1 / Hakim N1b, N2b — the item list
        # may be a COMPACT sequence, whose dashes sit at this same field
        # column, not strictly deeper. `current_list` alone gates the
        # dash branch below now; no indent comparison is required.
        current_list = "repos"
        return
      }
      # Any other key at this column closes whatever list state was armed
      # (e.g. a `roles:` block list after `repos:` must not be misread as
      # more repos).
      current_list = ""
    }

    {
      # apexyard#1457 Hakim LOW-3 — strip a trailing CR so a CRLF registry
      # parses identically to LF; otherwise every emitted token keeps an
      # invisible \r and never matches plain text again.
      line = $0
      sub(/\r$/, "", line)

      # Block-scalar skip: once inside one, ignore every line indented
      # deeper than the key that opened it (or blank), until a dedent.
      if (in_block) {
        match(line, /^[ \t]*/); ind = RLENGTH
        if (line == "" || ind > block_indent) next
        in_block = 0
      }

      match(line, /^[ \t]*/); indent = RLENGTH
      content = substr(line, indent + 1)

      if (content == "" || content ~ /^#/) next

      # apexyard#1457 round 3, Hakim HIGH-3 — outside the `projects:`
      # key'\''s own value, nothing is read as an entry. This is the ONLY
      # place `entry_indent` gets (re-)armed, so an earlier top-level list
      # or block scalar — at any indent, containing any `- ` line — can
      # never set it to the wrong column.
      if (state != "in") {
        if (content ~ /^projects:[[:space:]]*(#.*)?$/) {
          projects_key_indent = indent
          entry_indent = -1
          state = "in"
        }
        next
      }

      if (content ~ /^-[[:space:]]*(#.*)?$/) {
        # A BARE "-" line (apexyard#1457 round 3, Rex B4.2 / Hakim N4):
        # opens an entry with no key on this line at all. Its field
        # column is deferred to whichever indent the next real line uses.
        if (entry_indent == -1) entry_indent = indent
        if (indent == entry_indent) {
          flush()
          have_entry = 1
          next
        }
        if (indent < entry_indent) {
          flush()
          if (indent <= projects_key_indent) state = "after"
        }
        next
      }

      if (content ~ /^-[[:space:]]+/) {
        if (entry_indent == -1) entry_indent = indent
        if (indent == entry_indent) {
          # A new entry, whatever key opens it (apexyard#1457 Rex B2 /
          # Hakim case A / A2 — not just "- name:").
          flush()
          have_entry = 1
          rest = content
          sub(/^-[[:space:]]+/, "", rest)
          field_col = indent + (length(content) - length(rest))
          dispatch(rest)
          next
        }
        if (indent < entry_indent) {
          # A dash to the LEFT of the established entry column. Only a
          # dedent to at/left of the projects: key'\''s own column
          # actually leaves the block; anything else is defensive (should
          # not occur in valid YAML nested under projects:).
          flush()
          if (indent <= projects_key_indent) state = "after"
          next
        }
        # A nested "-" deeper than entry_indent: a repos: block-list item
        # — compact or indented, any column, once armed (apexyard#1457
        # round 3, Rex B4.1 / Hakim N1b/N2b) — or an unrelated nested
        # list/sub-item, never a new entry (Hakim "nested - name:" case).
        if (have_entry && current_list == "repos") {
          item = content
          sub(/^-[[:space:]]+/, "", item)
          gsub(/[[:space:]]+$/, "", item)
          if (item != "") { nrepo++; erepos[nrepo] = unquote(item) }
        }
        next
      }

      # A non-dash line at or to the left of the `projects:` key'\''s own
      # column ends the projects: value entirely — a top-level key such
      # as `defaults:` included (Hakim case E).
      if (indent <= projects_key_indent) {
        flush()
        state = "after"
        next
      }

      if (!have_entry) { safety_net(content); next }

      if (field_col == -1) {
        # A bare "-" opened this entry (Rex B4.2); this line is its first
        # real key, and establishes field_col from its own indent.
        field_col = indent
        dispatch(content)
        next
      }

      if (indent == field_col) {
        dispatch(content)
        next
      }

      # Deeper than field_col and not a gated repos: continuation: a
      # nested map (Hakim case C) or unrelated sub-structure. Not one of
      # this entry'\''s own keys structurally — but still emitted under
      # PUBLIC=0 if it looks like one of the four flagged keys, so an
      # unanticipated nesting fails closed (apexyard#1457 round 3, Rex
      # safety net) rather than silently dropping a real token.
      safety_net(content)
    }
    END { flush() }
  ' "$registry"
}

# apexyard#1457 round 3, Hakim MEDIUM (elevated to blocking) — a heuristic,
# text-only check for "does this registry plainly look like it registers at
# least one project?", independent of the structural awk parse above. Every
# leak hook calls this when its own parse produced zero NAME/REPO/WORKSPACE
# tokens; if this returns true anyway, that is not "no registered
# projects" — it is the parser failing to find shapes that ARE there, and
# the caller must block rather than silently allow every private
# reference. Deliberately simple (line-oriented grep, not YAML-aware) so it
# stays independent of the awk state machine it is cross-checking.
registry_has_project_shape() {
  local registry="$1"
  [ -r "$registry" ] || return 1
  grep -qE '^[[:space:]]*projects:[[:space:]]*(#.*)?$' "$registry" 2>/dev/null || return 1
  grep -qE '(^|[[:space:]])name:[[:space:]]*[^[:space:]]' "$registry" 2>/dev/null || return 1
  return 0
}
