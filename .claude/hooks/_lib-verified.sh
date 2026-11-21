#!/bin/bash
# Read Git's trailer block. Body prose does not count as a trailer.
verified_value() {
  local values value count=0 result=missing
  values=$(git interpret-trailers --parse | sed -n 's/^[Vv][Ee][Rr][Ii][Ff][Ii][Ee][Dd]:[[:space:]]*/value:/p')
  while IFS= read -r value; do
    [ -n "$value" ] || continue
    value="${value#value:}"
    count=$((count + 1))
    case "$value" in
      e2e|tests|ci-only|none) result="$value" ;;
      *) result=invalid ;;
    esac
  done <<< "$values"
  [ "$count" -le 1 ] || result=invalid
  printf '%s\n' "$result"
}

verified_warn() {
  local value
  value=$(verified_value)
  case "$value" in
    missing) printf 'WARN: missing Verified: trailer. Use e2e, tests, ci-only, or none.\n' >&2 ;;
    invalid) printf 'WARN: invalid Verified: trailer. Use one of e2e, tests, ci-only, or none.\n' >&2 ;;
  esac
  return 0
}

# Read the literal body of the existing supported cat-heredoc message shape.
# Never evaluate shell text. Return 1 when its body cannot be identified.
verified_heredoc_body() {
  local line marker delimiter="" strip_tabs=0 body="" check tab
  tab=$(printf '\t')
  while IFS= read -r line || [ -n "$line" ]; do
    if [ -n "$delimiter" ]; then
      check="$line"
      if [ "$strip_tabs" -eq 1 ]; then
        while [ "${check:0:1}" = "$tab" ]; do check="${check:1}"; done
      fi
      if [ "$check" = "$delimiter" ]; then
        printf '%s' "$body"
        return 0
      fi
      body+="$check"$'\n'
      continue
    fi
    marker=$(printf '%s\n' "$line" | sed -nE "s/.*\\$\\(cat[[:space:]]+<[<](-?)[[:space:]]*['\\\"]?([A-Za-z_][A-Za-z0-9_]*)['\\\"]?[[:space:]]*$/\\1:\\2/p")
    [ -n "$marker" ] || continue
    case "$marker" in -:*) strip_tabs=1 ;; esac
    delimiter="${marker#*:}"
  done
  return 1
}
