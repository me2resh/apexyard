#!/usr/bin/env bash
# Check the issue filter without a network request.
set -eu
root=$(cd "$(dirname "$0")/../../../.." && pwd)
sb=$(mktemp -d "${TMPDIR:-/tmp}/orbit-ticket-workflow.XXXXXX")
trap 'rm -rf "$sb"' EXIT
mkdir "$sb/bin"
cat > "$sb/bin/gh" <<'MOCK'
#!/usr/bin/env bash
set -eu
json='' limit=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --json) json=$2; shift ;;
    --limit) limit=$2; shift ;;
  esac
  shift
done
[ "$json" = title,body ] || { echo 'FAIL: Request title and body.' >&2; exit 1; }
[ "$limit" = 1000 ] || { echo 'FAIL: Request 1000 issues.' >&2; exit 1; }
[ "$GH_TOKEN" = local-test ] || exit 1
printf '%s\n' '[{"title":"[Slice] Next","body":"`slice-demo-next`"},{"title":"[Task] Build","body":"`slice-demo-task`"},{"title":"Text [Slice]","body":"`slice-demo-text`"}]'
MOCK
chmod +x "$sb/bin/gh"
active=0
while IFS= read -r line; do
  case "$line" in
    '      - name: Read slice tickets') active=1 ;;
    '      - name: Lint records') break ;;
    '          gh '*|'            jq '*) [ "$active" -eq 0 ] || printf '%s\n' "${line#          }" >> "$sb/run" ;;
  esac
done < "$root/.github/workflows/orbit-records-lint.yml"
export GH_TOKEN=local-test GITHUB_REPOSITORY=local/demo RUNNER_TEMP="$sb"
PATH="$sb/bin:$PATH" bash -eo pipefail "$sb/run"
[ "$(cat "$sb/orbit-tickets")" = slice-demo-next ] || { echo 'FAIL: Only Slice issues can supply IDs.'; exit 1; }
echo 'PASS slice ticket workflow.'
