#!/bin/bash
# Shared session state for the tamper controls. No tool-supplied code is run.
# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/_lib-path-resolve.sh" || return 2

pt_block() { printf 'BLOCKED: %s\n' "$*" >&2; exit 2; }
# The default macOS volume ignores letter case. So a protected-form test must
# also ignore case, or a case variant of a path passes. Run the named function
# with nocasematch set, then restore the option. Option and verb tests stay
# case-sensitive. On a case-sensitive volume this only adds blocks.
pt_nocase() {
  local rc=0 was=0
  shopt -q nocasematch && was=1
  shopt -s nocasematch
  "$@" || rc=$?
  [ "$was" = 1 ] || shopt -u nocasematch
  return "$rc"
}
pt_lexical() {
  printf '%s\n' "$1" | awk -F/ '{n=0; for(i=1;i<=NF;i++){if($i==""||$i==".")continue;if($i==".."){if(n)n--;continue} a[++n]=$i} p="";for(i=1;i<=n;i++)p=p "/" a[i];print (p==""?"/":p)}'
}
pt_physical() {
  local p link
  p=$(_resolve_real_path "$1")
  [ -n "$p" ] || return 1
  if [ -L "$p" ]; then
    link=$(readlink "$p") || return 1
    case "$link" in /*) p="$link" ;; *) p="$(dirname "$p")/$link" ;; esac
    p=$(_resolve_real_path "$p")
  fi
  pt_lexical "$p"
}
pt_settings() {
  if [ -f "$1" ]; then jq -cS '.' "$1"; else printf '{}\n'; fi
}
pt_hash() { jq -cS "$1 // null" | shasum -a 256 | awk '{print $1}'; }
pt_record() {
  local data hooks env disabled
  data=$(pt_settings "$1") || return 2
  hooks=$(printf '%s' "$data" | pt_hash '.hooks') || return 2
  env=$(printf '%s' "$data" | pt_hash '.env') || return 2
  disabled=$(printf '%s' "$data" | jq -c '.disableAllHooks // false') || return 2
  jq -n --arg path "$1" --arg hooks "$hooks" --arg env "$env" --argjson disabled "$disabled" \
    '{path:$path,hooks:$hooks,env:$env,disableAllHooks:$disabled}'
}
pt_init() {
  local input="$1" project sid pin
  command -v jq >/dev/null 2>&1 || return 2
  jq -e 'type=="object"' >/dev/null 2>&1 <<<"$input" || return 2
  sid=$(jq -r '.session_id // empty' <<<"$input")
  sid=${sid:-${CLAUDE_CODE_SESSION_ID:-}}
  case "$sid" in *[!a-zA-Z0-9_-]*) return 2 ;; esac
  PT_PIN_DIR=$(pt_physical "${APEXYARD_OPS_PIN_DIR:-$HOME/.claude/apexyard}") || return 2
  PT_SESSION="$PT_PIN_DIR/gate-session-$sid"
  PT_SNAPSHOT="$PT_SESSION/snapshot.json"
  PT_OPS=""; PT_PROJECT=""; PT_HAS_SNAPSHOT=0
  pin="$PT_PIN_DIR/ops-root-$sid"
  if [ -f "$pin" ]; then
    IFS= read -r PT_OPS < "$pin" || return 2
    PT_OPS=$(pt_physical "$PT_OPS") || return 2
  fi
  if [ -e "$PT_SNAPSHOT" ]; then
    export PT_HAS_SNAPSHOT=1
    jq -e '(.ops_root|type=="string") and (.project_dir|type=="string") and (.settings|type=="object")' "$PT_SNAPSHOT" >/dev/null || return 2
    [ "$PT_OPS" = "$(jq -r '.ops_root' "$PT_SNAPSHOT")" ] || return 2
    PT_PROJECT=$(jq -r '.project_dir' "$PT_SNAPSHOT")
  else
    project=${CLAUDE_PROJECT_DIR:-}
    [ -z "$project" ] || PT_PROJECT=$(pt_physical "$project") || return 2
  fi
  PT_ROOTS=()
  [ -z "$PT_OPS" ] || PT_ROOTS[${#PT_ROOTS[@]}]="$PT_OPS"
  [ -z "$PT_PROJECT" ] || PT_ROOTS[${#PT_ROOTS[@]}]="$PT_PROJECT"
  PT_USER=$(pt_physical "${CLAUDE_CONFIG_DIR:-$HOME/.claude}") || return 2
  PT_HOME_CONFIG=$(pt_physical "$HOME/.claude") || return 2
}
# An ApexYard fork root holds .claude/hooks and an ops-root anchor
# (.apexyard-fork or onboarding.yaml), matching the resolver walk in
# settings.json and harness-adapters/agy/agy-hook.sh. Non-fork project roots
# and data-only portfolio siblings do not get the agy wiring forms.
pt_is_fork_root() {
  [ -d "$1/.claude/hooks" ] || return 1
  [ -f "$1/.apexyard-fork" ] || [ -f "$1/onboarding.yaml" ]
}
pt_has_fork_root() {
  local root
  for root in ${PT_ROOTS[@]+"${PT_ROOTS[@]}"}; do
    pt_is_fork_root "$root" && return 0
  done
  return 1
}
pt_live_fork_form() { pt_nocase pt_live_fork_form_nocase "$@"; }
pt_live_fork_form_nocase() {
  local p="$1" root
  for root in ${PT_ROOTS[@]+"${PT_ROOTS[@]}"}; do
    pt_is_fork_root "$root" || continue
    [[ "$p" != "$root" ]] || return 0
  done
  return 1
}
pt_live_fork() {
  local p="$1" lexical physical alt
  case "$p" in
    /*) ;;
    *)
      for alt in ${PT_ALTS[@]+"${PT_ALTS[@]}"}; do
        [ "$alt" = "${PT_CWD:-$PWD}" ] || ! pt_live_fork "$alt/$p" || return 0
      done
      if [ "${PT_OR_ACTIVE:-0}" = 1 ]; then
        for alt in ${PT_PENDING[@]+"${PT_PENDING[@]}"}; do
          [ "$alt" = "${PT_CWD:-$PWD}" ] || ! pt_live_fork "$alt/$p" || return 0
        done
      fi
      p="${PT_CWD:-$PWD}/$p" ;;
  esac
  lexical=$(pt_lexical "$p") || return 0
  physical=$(pt_physical "$p") || return 0
  pt_live_fork_form "$lexical" || pt_live_fork_form "$physical"
}
# agy hook wiring, relative to a live ApexYard fork root (AgDR-0320). Each
# path can switch the gates off under agy, or run another hook beside them:
#   .agents/hooks.json      the wiring that bin/sync-agy-adapter.sh writes
#   .agents/plugins/        plugin discovery; each plugin runs its own hooks.json
#   .agents/plugins.json    plugin registration
#   harness-adapters/agy/   the wrapper that the wiring runs
PT_ADAPTER_WIRING=(.agents/hooks.json .agents/plugins .agents/plugins.json harness-adapters/agy)
# $2 is the role. 0 checks the path itself. 1 also blocks an ancestor of
# protected state, for removal and recursive writes. 2 blocks an ancestor of
# the core state only, not of the agy wiring: it judges the folder that a
# copy or link goes into, whose new entries are judged on their own.
pt_protected_form() { pt_nocase pt_protected_form_nocase "$@"; }
pt_protected_form_nocase() {
  local p="$1" ancestors="${2:-0}" root base env_path rel wt rest sub
  for root in ${PT_ROOTS[@]+"${PT_ROOTS[@]}"}; do
    case "$p" in "$root/.claude/settings.json"|"$root/.claude/settings.local.json"|"$root/.claude/hooks"|"$root/.claude/hooks/"*) return 0 ;; esac
    if [ "$ancestors" != 0 ]; then case "$root/.claude/hooks/" in "$p/"*) return 0 ;; esac; fi
    if pt_is_fork_root "$root"; then
      for rel in "${PT_ADAPTER_WIRING[@]}"; do
        case "$p" in "$root/$rel"|"$root/$rel/"*) return 0 ;; esac
        if [ "$ancestors" = 1 ]; then case "$root/$rel/" in "$p/"*) return 0 ;; esac; fi
      done
      # agy also reads nested .agents/ hook config, so the same files are
      # protected at any depth under the fork root, except under workspace/
      # (managed-project clones are not on agy's path from the fork root, and
      # check_nested_agents denies every call if agy starts in one). Direct
      # form only, so an rm -rf of a parent folder still passes. An agent's rm
      # of the nested file is blocked, so a person removes it. A linked
      # worktree under .claude/worktrees/ is its own fork root, so its own
      # root wiring and workspace/ subtree are exempt. A case pattern * also
      # matches /, so the worktree name is split off by hand: the prefix is
      # cut by length, then the first path component.
      case "$p" in
        "$root/workspace"|"$root/workspace/"*) ;;
        "$root/.claude/worktrees/"*)
          wt="$root/.claude/worktrees/"
          rest=${p:${#wt}}
          case "$rest" in */*) sub=${rest#*/} ;; *) sub="" ;; esac
          case "$sub" in
            .agents|.agents/hooks.json|.agents/plugins.json|.agents/plugins|.agents/plugins/*) ;;
            workspace|workspace/*) ;;
            */.agents/hooks.json|*/.agents/plugins.json|*/.agents/plugins|*/.agents/plugins/*) return 0 ;;
            */.agents) [ "$ancestors" != 1 ] || return 0 ;;
          esac ;;
        "$root/"*/.agents/hooks.json|"$root/"*/.agents/plugins.json|"$root/"*/.agents/plugins|"$root/"*/.agents/plugins/*) return 0 ;;
        # A recursive copy, a link, or a removal whose target is a nested
        # .agents folder can bring a hook config with it. A plain write of a
        # file inside it still takes the forms above, so mkdir stays allowed.
        "$root/"*/.agents) [ "$ancestors" != 1 ] || return 0 ;;
      esac
    fi
  done
  if [ "${#PT_ROOTS[@]}" = 0 ]; then
    case "$p" in */.claude/settings*.json|*/.claude/hooks*) return 0 ;; esac
  fi
  for base in "$PT_USER" "$PT_HOME_CONFIG"; do
    case "$p" in "$base/settings.json"|"$base/session-env"|"$base/session-env/"*|"$base/shell-snapshots"|"$base/shell-snapshots/"*) return 0 ;; esac
    if [ "$ancestors" != 0 ]; then case "$base/" in "$p/"*) return 0 ;; esac; fi
  done
  case "$p" in "$PT_PIN_DIR"/ops-root-*|"$PT_PIN_DIR"/gate-session-*|"$PT_PIN_DIR"/resolve-cache-*|"$PT_PIN_DIR"/projctx|"$PT_PIN_DIR"/projctx/*) return 0 ;; esac
  if [ "$ancestors" != 0 ]; then case "$PT_PIN_DIR/" in "$p/"*) return 0 ;; esac; fi
  if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
    env_path=$(pt_physical "$CLAUDE_ENV_FILE") || pt_block 'cannot resolve the harness environment file.'
    [[ "$p" != "$env_path" ]] || return 0
    if [ "$ancestors" != 0 ]; then case "$env_path" in "$p/"*) return 0 ;; esac; fi
  fi
  return 1
}
pt_protected() {
  local p="$1" role="${2:-0}" physical lexical alt
  case "$p" in
    /*) ;;
    *)
      # A cd that fails at run time leaves an earlier directory in effect.
      # Judge a relative path against each directory that can be in effect.
      for alt in ${PT_ALTS[@]+"${PT_ALTS[@]}"}; do
        [ "$alt" = "${PT_CWD:-$PWD}" ] || ! pt_protected "$alt/$p" "$role" || return 0
      done
      if [ "${PT_OR_ACTIVE:-0}" = 1 ]; then
        for alt in ${PT_PENDING[@]+"${PT_PENDING[@]}"}; do
          [ "$alt" = "${PT_CWD:-$PWD}" ] || ! pt_protected "$alt/$p" "$role" || return 0
        done
      fi
      p="${PT_CWD:-$PWD}/$p" ;;
  esac
  lexical=$(pt_lexical "$p") || pt_block 'cannot normalize the target path.'
  physical=$(pt_physical "$p") || pt_block 'cannot resolve the target path.'
  pt_protected_form "$lexical" "$role" || pt_protected_form "$physical" "$role"
}
pt_live() { pt_nocase pt_live_nocase "$@"; }
pt_live_nocase() {
  local root p
  p=$(pt_physical "$1") || return 0
  for root in ${PT_ROOTS[@]+"${PT_ROOTS[@]}"}; do [[ "$root" != "$p" ]] || return 0; done
  return 1
}
