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
# dedent, so `public: true` could bleed into a NEIGHBOURING entry (one whose
# first key wasn't `name:`) or into a nested map / block scalar inside the
# SAME entry. This version tracks the list item's own indent column and
# scopes `public:` strictly to that column.
#
# Entry-boundary contract:
#   - The FIRST `- <key>:` list item seen establishes `entry_indent` — the
#     column of its `-`. Every later list item at that SAME column starts a
#     new entry, regardless of which key it opens (`- name:`, `- repo:`,
#     `- workspace:`, ...) — apexyard#1457 Rex B2 / Hakim case A / A2.
#   - Any line (dash or not) at or to the left of `entry_indent` closes the
#     current entry — a top-level key such as `defaults:` included (Hakim
#     case E).
#   - A field is only read as one of THIS entry's top-level keys
#     (`name:`/`repo:`/`repos:`/`workspace:`/`public:`) when it sits at the
#     entry's own field column (the column where the opening list item's
#     key text starts). A `public: true` nested one level deeper — inside a
#     map (Hakim case C) or a block scalar body — is at a DEEPER column and
#     is never read as the entry's flag.
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
#   # "no registered projects".
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
# one NAME but several REPO lines, all sharing that entry's PUBLIC flag).
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
    BEGIN { entry_indent = -1; in_block = 0 }

    function unquote(s) { gsub(/^["\x27]|["\x27]$/, "", s); return s }

    function flush() {
      if (have_entry) {
        print "PUBLIC=" (is_public ? 1 : 0)
        for (i = 1; i <= nname; i++) print "NAME=" enames[i]
        for (i = 1; i <= nrepo; i++) print "REPO=" erepos[i]
        for (i = 1; i <= nws; i++) print "WORKSPACE=" ews[i]
      }
      have_entry = 0; is_public = 0; nname = 0; nrepo = 0; nws = 0
      current_list = ""; list_indent = -1; field_col = -1
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
        current_list = "repos"
        list_indent = field_col
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
          # A dash to the LEFT of the established entry column also closes
          # the current entry (an unrelated top-level list).
          flush()
          next
        }
        # A nested "-" deeper than entry_indent: a repos: block-list item
        # (state-gated) or an unrelated nested list/sub-item — never a new
        # entry (apexyard#1457 Hakim "nested - name: list item" case).
        if (have_entry && current_list == "repos" && indent > list_indent) {
          item = content
          sub(/^-[[:space:]]+/, "", item)
          gsub(/[[:space:]]+$/, "", item)
          if (item != "") { nrepo++; erepos[nrepo] = unquote(item) }
        }
        next
      }

      # A non-dash line at or to the left of the entry column closes the
      # entry — a top-level key such as `defaults:` included (Hakim case E).
      if (indent <= entry_indent) {
        flush()
        next
      }

      if (!have_entry) next

      if (indent == field_col) {
        dispatch(content)
        next
      }

      # Deeper than field_col and not a gated repos: continuation: a
      # nested map (Hakim case C) or unrelated sub-structure. Not one of
      # this entry'\''s own keys — ignored on purpose.
    }
    END { flush() }
  ' "$registry"
}
