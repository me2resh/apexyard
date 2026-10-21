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
# $2 enables ancestor checks for removal and recursive writes.
pt_protected_form() { pt_nocase pt_protected_form_nocase "$@"; }
pt_protected_form_nocase() {
  local p="$1" ancestors="${2:-0}" root base env_path
  for root in ${PT_ROOTS[@]+"${PT_ROOTS[@]}"}; do
    case "$p" in "$root/.claude/settings.json"|"$root/.claude/settings.local.json"|"$root/.claude/hooks"|"$root/.claude/hooks/"*) return 0 ;; esac
    if [ "$ancestors" = 1 ]; then case "$root/.claude/hooks/" in "$p/"*) return 0 ;; esac; fi
  done
  if [ "${#PT_ROOTS[@]}" = 0 ]; then
    case "$p" in */.claude/settings*.json|*/.claude/hooks*) return 0 ;; esac
  fi
  for base in "$PT_USER" "$PT_HOME_CONFIG"; do
    case "$p" in "$base/settings.json"|"$base/session-env"|"$base/session-env/"*|"$base/shell-snapshots"|"$base/shell-snapshots/"*) return 0 ;; esac
    if [ "$ancestors" = 1 ]; then case "$base/" in "$p/"*) return 0 ;; esac; fi
  done
  case "$p" in "$PT_PIN_DIR"/ops-root-*|"$PT_PIN_DIR"/gate-session-*|"$PT_PIN_DIR"/resolve-cache-*|"$PT_PIN_DIR"/projctx|"$PT_PIN_DIR"/projctx/*) return 0 ;; esac
  if [ "$ancestors" = 1 ]; then case "$PT_PIN_DIR/" in "$p/"*) return 0 ;; esac; fi
  if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
    env_path=$(pt_physical "$CLAUDE_ENV_FILE") || pt_block 'cannot resolve the harness environment file.'
    [[ "$p" != "$env_path" ]] || return 0
    if [ "$ancestors" = 1 ]; then case "$env_path" in "$p/"*) return 0 ;; esac; fi
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
