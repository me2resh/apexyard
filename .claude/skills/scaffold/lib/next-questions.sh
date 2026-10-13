#!/usr/bin/env bash
# Print unanswered question IDs in bank order.
set -eu
bank="$(cd "$(dirname "$0")/.." && pwd)/questions.json"
scale='' spec='' onboarding='' prd='' shape=''
bad() { printf 'input: %s\n' "$1" >&2; exit 2; }
while [ "$#" -gt 0 ]; do
  [ "$#" -ge 2 ] && [ -n "$2" ] || bad 'expected an option value'
  case "$1" in
    --scale) scale=$2 ;; --spec) spec=$2 ;; --onboarding) onboarding=$2 ;;
    --prd-answers) prd=$2 ;; --shape) shape=$2 ;; *) bad "unknown option $1" ;;
  esac
  shift 2
done
case "$scale" in demo|small|production) ;; *) bad 'scale must be demo, small, or production' ;; esac
case "$shape" in ''|'web app'|'API service'|'data pipeline'|'CLI tool'|other) ;; *) bad 'unknown shape' ;; esac
spec_json='{}' prd_json='{}' onboarding_json='{}'
if [ -n "$spec" ]; then
  bash "$(dirname "$0")/validate-spec.sh" "$spec" >/dev/null 2>&1 || bad 'invalid spec'
  spec_json=$(jq '.answers' "$spec")
fi
if [ -n "$prd" ]; then
  [ -r "$prd" ] || bad 'cannot read PRD answers'
  prd_json=$(jq -se 'if length == 1 and (.[0]|type) == "object" then .[0] else error("object required") end' "$prd" 2>/dev/null) || bad 'invalid PRD answers'
fi
if [ -n "$onboarding" ]; then
  [ -r "$onboarding" ] || bad 'cannot read onboarding'
  onboarding_json=$(awk '
    /^tech_stack:[[:space:]]*(#.*)?$/ { block=1; next }
    block && /^[^[:space:]#]/ { block=0 }
    block && /^  [a-zA-Z_]+:[[:space:]]*/ {
      line=$0; sub(/^  /,"",line); key=line; sub(/:.*/,"",key)
      sub(/^[^:]*:[[:space:]]*/,"",line); sub(/[[:space:]]+#.*/,"",line)
      gsub(/^[[:space:]"\047]+|[[:space:]"\047]+$/,"",line)
      if (line != "" && line !~ /^[\[{|>]/ && line !~ /^(null|~)$/) print key "\t" line
    }
  ' "$onboarding" | jq -Rn '
    [inputs | split("\t") | {key: .[0], value: .[1]}] | from_entries |
    with_entries(.key |= ({language:"language",hosting:"deployTarget",cloud:"cloud",database:"data"}[.] // .))
  ') || bad 'invalid onboarding'
fi
jq -r --arg scale "$scale" --arg shape "$shape" --argjson spec "$spec_json" --argjson prd "$prd_json" --argjson onboarding "$onboarding_json" '
  def value: if type == "object" and has("value") then .value else . end;
  ($shape | if . == "" then (($spec.shape // $onboarding.shape // $prd.shape // "") | value) else . end) as $shape |
  {demo:0,small:1,production:2} as $tiers |
  .[] | select(.id != "q01" and $tiers[.tier] <= $tiers[$scale]) |
  .specField as $field |
  select(($spec | has($field)) == false and ($onboarding | has($field)) == false and ($prd | has($field)) == false) |
  select(.appliesTo == null or (.appliesTo | index($shape)) != null) | .id
' "$bank" || bad 'cannot select questions'
