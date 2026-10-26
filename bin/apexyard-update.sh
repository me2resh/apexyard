#!/usr/bin/env bash
# Show upstream changes, then start the update skill.
set -euo pipefail
check=0
case "${1:-}" in
  --check) check=1; shift ;;
  -h|--help) echo 'Usage: apexyard update [--check]'; exit 0 ;;
esac
[ "$#" -eq 0 ] || { echo 'Usage: apexyard update [--check]' >&2; exit 2; }
root=${APEXYARD_UPDATE_ROOT:?Run apexyard update from the CLI.}
ref=${APEXYARD_FRAMEWORK_REF:-main}
git -C "$root" remote get-url upstream >/dev/null 2>&1 || {
  echo 'apexyard update: upstream remote not found' >&2; exit 2;
}
[ -s "$root/.claude/framework-version" ] || {
  echo 'apexyard update: framework-version not found' >&2; exit 2;
}
# This is the framework version that apexyard --version also prints.
IFS= read -r version < "$root/.claude/framework-version"
git -C "$root" fetch upstream "$ref"
lib_dir=${APEXYARD_LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}
if [ -f "$lib_dir/_lib-ownership.sh" ]; then
  # shellcheck disable=SC1091
  source "$lib_dir/_lib-ownership.sh"
else
  echo 'ownership manifest library not found' >&2
  ownership_class() { echo unknown; }
  ownership_is_security() { return 1; }
fi
# Check the comparison before the process substitution, which cannot report errors.
git -C "$root" diff --name-only "$version" FETCH_HEAD >/dev/null
# Use arrays so paths with spaces remain complete.
security=() other=()
while IFS= read -r -d '' path; do
  owner=$(ownership_class "$path") || owner=unmatched
  if ownership_is_security "$path"; then
    security+=("$path [$owner]")
  else
    other+=("$path [$owner]")
  fi
done < <(git -C "$root" diff --name-only -z "$version" FETCH_HEAD)
printf '!!! SECURITY-OWNED CHANGES !!!\n'
for line in ${security[@]+"${security[@]}"}; do printf '  %s\n' "$line"; done
printf 'Other changes:\n'
for line in ${other[@]+"${other[@]}"}; do printf '  %s\n' "$line"; done
[ "$check" -eq 0 ] || exit 0
agent=${APEXYARD_AGENT_CMD:-claude}
if command -v "$agent" >/dev/null 2>&1; then
  cd "$root"
  exec "$agent" /update
fi
echo 'Run /update in your agent tool.'
