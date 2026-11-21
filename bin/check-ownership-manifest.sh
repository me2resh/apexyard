#!/usr/bin/env bash
# Check that each shipped path has an owner.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd) || exit 2
# shellcheck source=bin/_lib-ownership.sh
. "$root/bin/_lib-ownership.sh"
paths=''
usage() {
  echo 'Usage: bin/check-ownership-manifest.sh [--manifest FILE] [--paths FILE|-] [-h|--help]'
}
while [ "$#" -gt 0 ]; do
  case "$1" in
    --manifest|--paths)
      [ "$#" -ge 2 ] && [ -n "$2" ] || { usage >&2; exit 2; }
      case "$1" in
        --manifest) OWNERSHIP_MANIFEST="$2" ;;
        --paths) paths="$2" ;;
      esac
      shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
ownership_validate_manifest || exit 2
if [ -z "$paths" ]; then
  # Read NUL-separated names, so git does not quote a non-ASCII path.
  listing=$(mktemp "${TMPDIR:-/tmp}/ownership-ls.XXXXXX") || exit 2
  trap 'rm -f "$listing"' EXIT
  git -C "$root" ls-files -z > "$listing" || { echo 'git ls-files failed' >&2; exit 2; }
  input=$(tr '\000' '\n' < "$listing")
elif [ "$paths" = '-' ]; then
  input=$(cat) || exit 2
else
  input=$(cat "$paths") || exit 2
fi
result=$(printf '%s\n' "$input" | ownership_classify_stream) || exit 2
printf '%s\n' "$result" | awk -F '\t' '
  NF {
    total++
    if ($1 == "unmatched") {
      sub(/^[^\t]*\t[^\t]*\t/, "")
      print "unmatched: " $0 > "/dev/stderr"; missing++
    } else count[$1]++
  }
  END {
    if (!total) {
      print "No paths to classify." > "/dev/stderr"
      exit 2
    }
    if (missing) {
      print "Add a glob for it to .claude/ownership-manifest.yaml." > "/dev/stderr"
      exit 1
    }
    printf "ownership manifest: %d paths classified (framework %d, adopter %d, shared %d)\n", total, count["framework"], count["adopter"], count["shared"]
  }'
