# Resolve the ops root

Run this snippet in bash. It sets `ops_root`.
The session pin identifies the ops fork from workspace clones.
Split-portfolio v2 stores configuration in a sibling repo. That repo does not contain the hook library.
Use the pin first. If the pin cannot locate the library, search the parents of `PWD`.
Then call `resolve_ops_root` to select the ops root. See #381 and #559.

```bash
ops_lib=""
pin_file="${APEXYARD_OPS_PIN_DIR:-$HOME/.claude/apexyard}/ops-root-${CLAUDE_CODE_SESSION_ID:-}"
if [ -z "${APEXYARD_OPS_DISABLE_PIN:-}" ] && [ -n "${CLAUDE_CODE_SESSION_ID:-}" ] && [ -f "$pin_file" ]; then
  IFS= read -r pinned_root < "$pin_file" || pinned_root=""
  [ -f "$pinned_root/.claude/hooks/_lib-ops-root.sh" ] && ops_lib="$pinned_root/.claude/hooks/_lib-ops-root.sh"
fi
if [ -z "$ops_lib" ]; then
  r="$PWD"
  while [ "$r" != / ]; do
    [ -f "$r/.claude/hooks/_lib-ops-root.sh" ] && { ops_lib="$r/.claude/hooks/_lib-ops-root.sh"; break; }
    r=$(dirname "$r")
  done
fi
[ -n "$ops_lib" ] || { echo "Cannot find the ops-root library." >&2; exit 1; }
source "$ops_lib" || exit 1
ops_root=$(resolve_ops_root)
[ -n "$ops_root" ] || { echo "Cannot resolve the ops root." >&2; exit 1; }
```

All 17 skills that resolve the ops root outside /approve-merge use this one line. It tries the session pin first and skips it when APEXYARD_OPS_DISABLE_PIN is set or the pin has no hook library. Then it walks up from PWD to find the library. `resolve_ops_root` makes the final choice. It re-checks the pin against the fork anchors and walks up when the pin is stale.

```text
ops_root=$(p="${APEXYARD_OPS_PIN_DIR:-$HOME/.claude/apexyard}/ops-root-${CLAUDE_CODE_SESSION_ID:-}"; r=""; [ -z "${APEXYARD_OPS_DISABLE_PIN:-}" ] && [ -f "$p" ] && IFS= read -r r < "$p"; [ -f "$r/.claude/hooks/_lib-ops-root.sh" ] || { r="$PWD"; while [ -n "$r" ] && [ ! -f "$r/.claude/hooks/_lib-ops-root.sh" ]; do r=${r%/*}; done; }; [ -f "$r/.claude/hooks/_lib-ops-root.sh" ] && . "$r/.claude/hooks/_lib-ops-root.sh" && resolve_ops_root) && [ -n "$ops_root" ] || { echo "No ops root. See docs/skills/shared/ops-root.md." >&2; exit 1; }
```
