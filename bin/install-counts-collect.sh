#!/usr/bin/env bash
# Collect GitHub counters. Write one JSON line to stdout.
set -euo pipefail
[ "$#" -eq 0 ] || { echo 'Usage: install-counts-collect.sh' >&2; exit 2; }
repo=${GH_REPO:-me2resh/apexyard}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# Slurp all pages, including an empty release list.
gh api --paginate --slurp "repos/$repo/releases?per_page=100" > "$work/releases.json"
printf 'null\n' > "$work/tap.json"
if [ -n "${TAP_TRAFFIC_TOKEN:-}" ]; then
  GH_TOKEN=$TAP_TRAFFIC_TOKEN gh api 'repos/me2resh/homebrew-tap/traffic/clones?per=week' > "$work/tap.json"
else
  echo '::notice::TAP_TRAFFIC_TOKEN is absent. Skipping tap traffic.' >&2
fi
jq -cn --arg collected_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --slurpfile releases "$work/releases.json" --slurpfile tap "$work/tap.json" '
  {collected_at: $collected_at,
   releases: [$releases[0][][] | select(.draft == false) |
     .tag_name as $tag |
     {tag: $tag, asset: ([.assets[] |
       select(.name == ("apexyard-" + $tag + ".tar.gz")) |
       {id, name, download_count}] | first // null)}],
   tap: $tap[0]}'
