#!/usr/bin/env bash
# Validate the closed scaffold schema with jq.
set -eu
[ "$#" -eq 1 ] || { printf 'Usage: validate-spec.sh <spec.json>\n' >&2; exit 2; }
[ -r "$1" ] || { printf 'spec: cannot read file\n' >&2; exit 1; }
schema="$(cd "$(dirname "$0")/.." && pwd)/spec.schema.json"
jq -se --slurpfile schema "$schema" '
  def valid($s):
    . as $v |
    (if $s.type then type == $s.type else true end) and
    (if $s.const then . == $s.const else true end) and
    (if $s.enum then ($s.enum | index($v)) != null else true end) and
    (if $s.minLength then length >= $s.minLength else true end) and
    (if $s.minimum != null then . >= $s.minimum else true end) and
    (if $s.maximum != null then . <= $s.maximum else true end) and
    (if $s.type == "object" then
      (($s.required // []) - keys | length) == 0 and
      (if $s.additionalProperties == false then (keys - ($s.properties | keys) | length) == 0 else true end) and
      all(to_entries[]; . as $entry | .value | valid($s.properties[$entry.key])) and
      (if .source == "recommendation" then (.reason | type) == "string" and (.reason | length) > 0 else true end)
    elif $s.type == "array" then all(.[]; valid($s.items)) and
      (if $s.uniqueItems then length == (unique | length) else true end)
    else true end);
  def calendar:
    (.createdAt | capture("^(?<y>[0-9]{4})-(?<m>[0-9]{2})-(?<d>[0-9]{2})") | map_values(tonumber)) as $date |
    $date.d <= ([31,(if ($date.y % 4 == 0 and ($date.y % 100 != 0 or $date.y % 400 == 0)) then 29 else 28 end),31,30,31,30,31,31,30,31,30,31][$date.m - 1]);
  length == 1 and (.[0] | valid($schema[0]) and
    (.answers.scale == null or .answers.scale.value == .scale) and
    (.createdAt | test("^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9](\\.[0-9]+)?(Z|[+-]([01][0-9]|2[0-3]):[0-5][0-9])$")) and calendar)
' "$1" >/dev/null 2>&1 || { printf 'spec: invalid field, source, value, reason, or date-time\n' >&2; exit 1; }
