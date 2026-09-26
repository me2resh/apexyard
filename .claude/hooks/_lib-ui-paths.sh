#!/bin/bash
# _lib-ui-paths.sh — the single source of "what counts as UI" for the design
# review gate.
#
# Before me2resh/apexyard#1390, this pattern list was defined TWICE: once
# inline in require-design-review-for-ui.sh, and again as a separate,
# narrower hard-coded copy inside the /approve-design skill's own step 5
# instructions. The two lists could drift — and had: the skill's copy never
# saw .astro, .mdx, or the template-engine formats added below. Both
# consumers now call the functions in this file instead of keeping their own
# copy, so there is exactly one list to update.
#
# Usage:
#   . "$(dirname "$0")/_lib-ui-paths.sh"
#   UI_GLOBS=$(ui_effective_globs "$REPO_ROOT")        # newline-separated
#   PATTERN=$(ui_effective_globs_pipe "$REPO_ROOT")    # single grep -E arg

# ui_default_globs: the shipped default UI path patterns (regex), one per
# line. Note: .tsx$ / .jsx$ (and friends) are EXACT-suffix anchored — they
# must not match plain .ts / .js, which are often backend/server files. Keep
# this list in sync with the "What counts as UI" comment block in
# require-design-review-for-ui.sh.
ui_default_globs() {
  cat <<'GLOBS'
\.tsx$
\.jsx$
\.vue$
\.svelte$
\.astro$
\.mdx$
\.hbs$
\.njk$
\.liquid$
\.css$
\.scss$
\.sass$
\.less$
design-tokens
GLOBS
}

# ui_effective_globs REPO_ROOT: the default patterns above, or the project's
# `.ui_paths` override when one is set. `.ui_paths` REPLACES the defaults
# wholesale — same array-override semantics as every other project-config
# array key (see docs/project-config.md). One pattern per line.
#
# The `.ui_paths` read keeps only non-blank string entries (Hakim's LOW-2,
# me2resh/apexyard#1397). A raw `.[]` turns a non-string override entry
# (`null`, an object, or a nested array) into the literal pattern `null`,
# `{"a":1}`, etc. — a pattern that matches almost no real file. Every
# entry an adopter's `.ui_paths` array carries that isn't a usable regex
# silently narrows the design gate toward "nothing matches" instead of
# falling back to the shipped defaults. Filtering to non-blank strings
# and falling back to the defaults when nothing valid remains keeps the
# override intentional: a malformed override degrades to the safe
# (fail-closed) default list rather than to an empty, always-passing gate.
ui_effective_globs() {
  local repo_root="$1"
  if [ -n "$repo_root" ] && [ -f "${repo_root}/.claude/project-config.json" ] && command -v jq >/dev/null 2>&1; then
    local custom
    custom=$(jq -r '.ui_paths // [] | map(select(type == "string" and test("\\S"))) | .[]' "${repo_root}/.claude/project-config.json" 2>/dev/null)
    if [ -n "$custom" ]; then
      printf '%s\n' "$custom"
      return 0
    fi
  fi
  ui_default_globs
}

# ui_effective_globs_pipe REPO_ROOT: ui_effective_globs, joined with `|` into
# a single alternation suitable for one `grep -E` argument.
ui_effective_globs_pipe() {
  ui_effective_globs "$1" | paste -sd'|' -
}
