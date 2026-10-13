#!/usr/bin/env bash
# Validate the scaffold schema without a schema-library dependency.
set -u
if [ "$#" -ne 1 ]; then echo 'Usage: validate-spec.sh <spec.json>' >&2; exit 2; fi
[ -r "$1" ] || { echo 'spec: cannot read file' >&2; exit 1; }
reason=$(jq -sr '
  def fault($f): error($f);
  try (
    if length != 1 then fault("spec: expected one object") else .[0] end |
    if type != "object" then fault("spec: expected object") else . end |
    if (keys - ["specVersion","scale","answers","openQuestions","createdAt"] | length) > 0 then fault("spec: additional field") else . end |
    if .specVersion != "0.1" then fault("specVersion: expected 0.1") else . end |
    if (.scale as $s | ["demo","small","production"] | index($s)) == null then fault("scale: invalid tier") else . end |
    if (.answers | type) != "object" then fault("answers: expected object") else . end |
    . as $spec |
    (.answers | to_entries[] | .key as $key | .value |
      if type != "object" then fault("answers."+$key+": expected object") else . end |
      if (keys - ["value","source","reason"] | length) > 0 then fault("answers."+$key+": additional field") else . end |
      if has("value") | not then fault("answers."+$key+".value: required") else . end |
      if (.source as $s | ["owner","recommendation","onboarding","prd"] | index($s)) == null then fault("answers."+$key+".source: invalid source") else . end |
      if (.source == "recommendation" and (has("reason") | not)) or (has("reason") and (.reason | type) != "string") then fault("answers."+$key+".reason: expected string") else . end |
      empty),
    ($spec |
      if (.openQuestions | type) != "array" then fault("openQuestions: expected array") else . end |
      if all(.openQuestions[]; type == "string") | not then fault("openQuestions: expected strings") else . end |
      if (.createdAt | type) != "string" then fault("createdAt: expected date-time") else . end |
      if (.createdAt | test("^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])[Tt]([01][0-9]|2[0-3]):[0-5][0-9]:([0-5][0-9]|60)(\\.[0-9]+)?([Zz]|[+-]([01][0-9]|2[0-3]):[0-5][0-9])$")) | not then fault("createdAt: expected date-time") else . end |
      (.createdAt | capture("^(?<year>[0-9]{4})-(?<month>[0-9]{2})-(?<day>[0-9]{2})") | map_values(tonumber)) as $date |
      ([31,(if ($date.year % 4 == 0 and ($date.year % 100 != 0 or $date.year % 400 == 0)) then 29 else 28 end),31,30,31,30,31,31,30,31,30,31][$date.month - 1]) as $days |
      if $date.day > $days then fault("createdAt: invalid calendar day") else . end |
      "")
  ) catch .
' "$1" 2>/dev/null) || reason='spec: invalid JSON'
[ -z "$reason" ] && exit 0
printf '%s\n' "$reason" >&2
exit 1
