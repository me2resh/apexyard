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

The skills that write the active-issue marker use this short form. It reads the pin only. Use the full snippet above when the pin may be missing.

```text
ops_root=$(. "$(<"${APEXYARD_OPS_PIN_DIR:-$HOME/.claude/apexyard}/ops-root-${CLAUDE_CODE_SESSION_ID:-}")/.claude/hooks/_lib-ops-root.sh" && resolve_ops_root) && [ -n "$ops_root" ] || { echo "No ops root. See docs/skills/shared/ops-root.md." >&2; exit 1; }
```
