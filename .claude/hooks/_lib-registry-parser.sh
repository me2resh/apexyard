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
# Usage:
#   source ".../_lib-registry-parser.sh"
#   while IFS= read -r entry; do
#     case "$entry" in
#       PUBLIC=*)    current_public=${entry#PUBLIC=} ;;
#       NAME=*)      name=${entry#NAME=}; names+=("$name"); names_public+=("$current_public") ;;
#       REPO=*)      repo=${entry#REPO=}; repos+=("$repo"); repos_public+=("$current_public") ;;
#       WORKSPACE=*) ws=${entry#WORKSPACE=}; workspaces+=("$ws"); workspaces_public+=("$current_public") ;;
#     esac
#   done < <(registry_parse_entries "$registry")
#
# Output contract: one `PUBLIC=0` or `PUBLIC=1` line precedes every entry's
# NAME=/REPO=/WORKSPACE= lines. A consumer that tracks "current_public" as it
# reads, and pairs it with each NAME=/REPO=/WORKSPACE= line that follows,
# gets a per-token public flag even though names/repos/workspaces are flat,
# order-preserving streams (an entry can hold zero or many of each — a
# multi-repo project has one NAME but several REPO lines, all sharing the
# same entry's PUBLIC flag).
#
# A missing `public:` field defaults to PUBLIC=0 (private). The hooks that
# consume this must fail closed on any parse ambiguity — never assume public.
registry_parse_entries() {
  local registry="$1"
  [ -f "$registry" ] || return 0
  awk '
    function unquote(s) { gsub(/^["\x27]|["\x27]$/, "", s); return s }
    function flush() {
      if (have_entry) {
        print "PUBLIC=" (is_public ? 1 : 0)
        for (i = 1; i <= nname; i++) print "NAME=" enames[i]
        for (i = 1; i <= nrepo; i++) print "REPO=" erepos[i]
        for (i = 1; i <= nws; i++) print "WORKSPACE=" ews[i]
      }
      have_entry = 0; is_public = 0; nname = 0; nrepo = 0; nws = 0; current_list = ""
    }
    /^[[:space:]]*- name:/ {
      flush()
      have_entry = 1
      nname++; enames[nname] = unquote($3)
      current_list = ""
      next
    }
    /^[[:space:]]*repo:/ {
      nrepo++; erepos[nrepo] = unquote($2)
      current_list = ""
      next
    }
    /^[[:space:]]*public:[[:space:]]*true[[:space:]]*(#.*)?$/ {
      is_public = 1
      current_list = ""
      next
    }
    /^[[:space:]]*workspace:/ {
      nws++; ews[nws] = unquote($2)
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
        if (item != "") { nrepo++; erepos[nrepo] = unquote(item) }
      }
      current_list = ""
      next
    }
    /^[[:space:]]*repos:[[:space:]]*(#.*)?$/ { current_list = "repos"; next }
    /^[[:space:]]*[A-Za-z_][A-Za-z0-9_-]*:/ { current_list = ""; next }
    /^[[:space:]]*-[[:space:]]+/ {
      if (current_list == "repos") {
        item = $0
        sub(/^[[:space:]]*-[[:space:]]+/, "", item)
        gsub(/[[:space:]]+$/, "", item)
        nrepo++; erepos[nrepo] = unquote(item)
      }
      next
    }
    END { flush() }
  ' "$registry"
}
