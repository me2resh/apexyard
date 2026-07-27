#!/bin/bash
# _lib-read-config.sh — shared reader for .claude/project-config.*.json
#
# Source this library from any hook or skill that needs to read project config.
# Defaults ship at .claude/project-config.defaults.json (committed, upstream-
# maintained). User overrides live at .claude/project-config.json (optional;
# each fork decides whether to commit or gitignore it).
#
# Merge strategy: SHALLOW at the top level. If the user defines `ticket`, their
# entire `ticket` subtree replaces the default. To extend a subtree, copy the
# default fields and add/modify. This keeps merge behaviour predictable without
# requiring a deep-merge jq function, and matches the "config file as a whole"
# mental model most teams expect.
#
# Usage:
#   source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-read-config.sh"
#   config_get '.ticket.prefix_whitelist[]'
#   config_get '.branch.type_whitelist[]'
#   config_get '.ticket.label_priority_scheme'
#
# Silent fallback behaviour:
#   - No defaults file present: emit '{}' and an error on stderr. Callers should
#     treat config_get as "unknown" and apply their own safety.
#   - jq not installed: emit '{}' and a one-time warning on stderr.

# ------------------------------------------------------------------------------
# Internal state: cache merged config per-process so repeated reads are cheap.
# ------------------------------------------------------------------------------
# `_CR` holds a literal carriage return, used by config_get to strip the CRLF
# line endings Windows (Git Bash / MSYS2) jq.exe emits. Defined as a real
# character rather than writing `s/\r$//` because `\r` is NOT specified by POSIX
# as a BRE escape — whether sed expands it, matches a literal `r`, or errors is
# implementation-defined. GNU sed and current macOS/BSD sed both happen to
# expand it, but relying on that is relying on an accident: a sed that treats
# `\r` as a literal `r` would silently strip the last character off any value
# ending in `r` (`…-reviewer` -> `…-reviewe`) — a wrong-value bug, not a
# no-op, and one that only shows up on whichever platform we didn't test.
# A real CR byte is unambiguous on every implementation.
# See me2resh/apexyard#1019.
_CR=$(printf '\r')
_CONFIG_CACHE=""
_CONFIG_WARNED_NO_JQ=""
_CONFIG_ROOT_CACHE=""

# _config_repo_root: resolve the directory that holds .claude/project-config.*.
#
# When the operator is inside a managed-project workspace clone at
# workspace/<project>/, `git rev-parse --show-toplevel` returns the project
# clone's git root — NOT the ops fork. The project clone usually has no
# .claude/project-config.json (or a different one), so config_get falls back
# to the framework defaults file which doesn't exist either, and tracker.kind
# silently resolves to "gh" even when the operator configured Linear / Jira /
# Asana / custom at the ops-fork level (me2resh/apexyard#310).
#
# Fix: walk up looking for the ops-fork anchor (.apexyard-fork marker for
# split-portfolio v2, or onboarding.yaml + apexyard.projects.yaml for v1)
# FIRST. Fall back to `git rev-parse --show-toplevel` only when no ops fork
# is found anywhere above $PWD — preserves the legacy behaviour for adopters
# running these hooks outside an apexyard fork entirely (bare clones, CI
# sandboxes, etc.).
#
# Result is cached per-process — the walk is cheap but called by every
# config_get invocation, so caching matches the _CONFIG_CACHE pattern.
_config_repo_root() {
  if [ -n "$_CONFIG_ROOT_CACHE" ]; then
    echo "$_CONFIG_ROOT_CACHE"
    return 0
  fi
  local root=""
  # Try the ops-fork resolver first. _lib-ops-root.sh lives next to this
  # file in .claude/hooks/, so locate it via BASH_SOURCE — not via
  # `git rev-parse` (which would defeat the whole point of this fix).
  local lib_dir
  # zsh-safe warning (me2resh/apexyard#950): these helpers are #!/bin/bash and
  # rely on ${BASH_SOURCE[0]} for self-location, which is a bash-only feature —
  # it is EMPTY under zsh, so an operator who `source`s this lib in an
  # interactive zsh shell (a common manual config-verification move during
  # setup) would silently resolve to the wrong dir and chase a phantom bug.
  # Emit a one-line advisory so the failure is loud, not silent. (A real zsh
  # self-location expansion was rejected — this file has other bash-only
  # constructs that don't source cleanly under zsh anyway, so "run it under
  # bash" is the honest guidance.)
  if [ -n "${ZSH_VERSION:-}" ]; then
    printf 'apexyard: source the .claude/hooks/_lib-*.sh helpers under bash, not zsh — path resolution is unreliable under zsh. Wrap manual checks in `bash -c '"'"'...'"'"'`.\n' >&2
  fi
  # `:-` default (#1025): under zsh, a bare ${BASH_SOURCE[0]} reference is
  # a hard "parameter not set" error whenever the caller's shell has
  # nounset active, on top of the already-documented empty-value hazard
  # above. The `git rev-parse` fallback a few lines below is what actually
  # recovers root in that case.
  lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-}")" 2>/dev/null && pwd)"
  if [ -f "$lib_dir/_lib-ops-root.sh" ]; then
    # shellcheck source=/dev/null
    . "$lib_dir/_lib-ops-root.sh"
    if command -v resolve_ops_root >/dev/null 2>&1; then
      root=$(resolve_ops_root "$PWD")
    fi
  fi
  # Fallback: legacy behaviour for non-apexyard environments. Lets these
  # hooks remain usable in bare clones / CI sandboxes that don't ship the
  # ops-fork anchors.
  if [ -z "$root" ]; then
    root=$(git rev-parse --show-toplevel 2>/dev/null)
  fi
  _CONFIG_ROOT_CACHE="$root"
  echo "$root"
}

_config_defaults_file() {
  local root
  root=$(_config_repo_root)
  [ -n "$root" ] && echo "$root/.claude/project-config.defaults.json"
}

_config_overrides_file() {
  local root
  root=$(_config_repo_root)
  [ -n "$root" ] && echo "$root/.claude/project-config.json"
}

_config_load() {
  # Check jq availability once per process.
  if ! command -v jq >/dev/null 2>&1; then
    if [ -z "$_CONFIG_WARNED_NO_JQ" ]; then
      echo "WARN: jq not installed; project config unavailable. Install jq to enable config-driven hooks." >&2
      _CONFIG_WARNED_NO_JQ=1
    fi
    echo '{}'
    return 0
  fi

  local defaults overrides
  defaults=$(_config_defaults_file)
  overrides=$(_config_overrides_file)

  if [ -z "$defaults" ] || [ ! -f "$defaults" ]; then
    # No defaults file — repo may not be an apexyard fork (e.g. project-inside-workspace).
    echo '{}'
    return 0
  fi

  if [ -f "$overrides" ]; then
    # Shallow merge: user overrides win at top-level keys.
    jq -s '.[0] * .[1]' "$defaults" "$overrides" 2>/dev/null || cat "$defaults"
  else
    cat "$defaults"
  fi
}

# ------------------------------------------------------------------------------
# Public: config_get <jq-filter>
#   Outputs the result of applying the filter to the merged config.
#   Returns an empty string (not an error) when the filter matches nothing.
# ------------------------------------------------------------------------------
config_get() {
  local filter="${1:-.}"
  if [ -z "$_CONFIG_CACHE" ]; then
    _CONFIG_CACHE=$(_config_load)
  fi
  if command -v jq >/dev/null 2>&1; then
    # printf '%s', NOT echo: under an XSI/POSIX shell `echo` interprets backslash
    # escapes, collapsing a valid JSON escape in the cached config (e.g. `\\0` in
    # a pre_push command value) into an invalid one — jq then aborts on the whole
    # document and config_get returns empty for EVERY key, silently dropping all
    # project-config overrides (incl. split-portfolio portfolio.* paths).
    # See me2resh/apexyard#629.
    #
    # The trailing-CR strip is for Windows (Git Bash / MSYS2), where the native
    # jq.exe writes stdout through a text-mode CRT handle and rewrites every
    # emitted \n into \r\n.
    #
    # EVERY read is affected, single-value included. Command substitution
    # strips trailing NEWLINES only, so `$(printf 'gh\r\n')` is `gh\r` — the
    # CR survives. Do not gate this strip to iterating filters on the belief
    # that scalar reads are safe: dozens of single-value reads would silently
    # regress, among them `.tracker.kind` and the `$`-anchored
    # `.tracker.id_pattern`, where a trailing CR breaks the match. ("Dozens"
    # is deliberate. Three independent sweeps produced three different counts
    # — the figure moves with the scope swept (`.claude/hooks/` vs all
    # production `.sh` vs including docs) and with how call forms are matched.
    # Roughly 40 under `.claude/hooks/`, more repo-wide. No exact census is
    # stated here because none of the three reproduced, and the argument does
    # not need one: what matters is that the scalar half is large and would
    # regress silently.)
    #
    # A MULTI-line filter (e.g. `.branch.type_whitelist[]`) is merely where
    # the damage became VISIBLE rather than where it was unique: callers join
    # with `paste -sd'|' -`, building an alternation with carriage returns
    # inside it that can never match a real branch name or PR title — and
    # since the branch/PR validators BLOCK, Windows adopters could not create
    # a compliant branch or PR at all. Ten hooks read multi-line config
    # values, so the fix belongs here rather than at each call site.
    # See me2resh/apexyard#1019.
    #
    # Deliberately surgical: this removes a CR only at end-of-line, not every
    # CR in the stream. A `tr -d '\r'` would also corrupt a config value that
    # legitimately contains a carriage return mid-string. `$_CR` holds a real
    # CR byte rather than a `\r` escape — see its definition above for why the
    # escape form is not portable.
    printf '%s' "$_CONFIG_CACHE" | jq -r "$filter" 2>/dev/null | sed "s/${_CR}\$//"
  else
    return 0
  fi
}

# ------------------------------------------------------------------------------
# Public: config_get_or <jq-filter> <fallback>
#   Like config_get, but returns <fallback> if the filter yields an empty
#   string, "null", or an error. Useful for single-value lookups with sensible
#   in-code defaults (e.g. when a hook runs outside an apexyard repo).
# ------------------------------------------------------------------------------
config_get_or() {
  local filter="$1"
  local fallback="$2"
  local value
  value=$(config_get "$filter")
  if [ -z "$value" ] || [ "$value" = "null" ]; then
    echo "$fallback"
  else
    echo "$value"
  fi
}
