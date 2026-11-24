#!/bin/bash
# _lib-branch-suggest.sh — build the branch name /start-ticket suggests.
#
# /start-ticket step 3 used to describe the branch shape in prose and let the
# agent assemble it. That works for the default `{type}/{TICKET-ID}-{description}`
# shape but cannot express a tracker-native one: Jira's "Create branch" action
# names the branch `<KEY>-<number>-<summary-slug>`, and an adopter who wants
# /start-ticket to suggest that exact name has no way to say so
# (me2resh/apexyard#2083).
#
# `.branch.suggested_template` holds an optional template:
#
#   { "branch": { "suggested_template": "{id}-{title_slug}" } }
#
# Tokens:
#   {type}        branch type, guessed from the title prefix (see below)
#   {id}          the TICKET-ID the caller resolved (GH-123, ABC-123, …)
#   {title_slug}  kebab-case slug of the FULL title, stopwords trimmed from
#                 the edges, no length cap
#
# When the key is unset or empty the helper returns today's shape exactly:
# `<type>/<TICKET-ID>-<slug>`, with the slug capped at 40 characters. The cap
# belongs to the built-in default only — a template that names {title_slug}
# gets the whole summary, which is the point of the key.
#
# An unknown `{token}` is reported on stderr and the built-in shape is
# returned instead. suggested_branch is a suggestion written into the ticket
# marker; nothing gates on it, so a template typo must not stop a ticket from
# starting. The operator sees the warning and fixes the config.
#
# Usage: bin/apexyard-start-ticket sources this file and calls branch_suggest
# with the title it already holds. The title never goes on a command line.
#   . "$lib/_lib-read-config.sh"
#   . "$lib/_lib-branch-suggest.sh"
#   branch_suggest "GH-2083" "[Feature] Configurable branch-name shapes"
#   branch_suggest "GH-2083" "[Feature] Configurable branch-name shapes" fix

# Words dropped from the EDGES of a slug. Internal stopwords stay, because
# removing them mid-phrase tends to produce names nobody can read back
# ("add-the-thing" -> "add-thing" is fine, "api-for-users" -> "api-users" is
# not obviously better). Kept deliberately short.
_BRANCH_SUGGEST_STOPWORDS=" a an and are as at be but by for from in into is it of on or that the this to with "

# _branch_suggest_slug <text> — lowercase, non-alphanumerics collapsed to '-'.
_branch_suggest_slug() {
  # LC_ALL=C keeps tr and sed byte-oriented, so invalid UTF-8 in a title gives
  # the same slug on every platform.
  printf '%s' "$1" \
    | LC_ALL=C tr '[:upper:]' '[:lower:]' \
    | LC_ALL=C sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'
}

# _branch_suggest_trim_edges <slug> — drop stopwords from both ends.
_branch_suggest_trim_edges() {
  local slug="$1" head tail
  while [ -n "$slug" ]; do
    head="${slug%%-*}"
    case "$_BRANCH_SUGGEST_STOPWORDS" in
      *" $head "*) slug="${slug#"$head"}"; slug="${slug#-}" ;;
      *) break ;;
    esac
  done
  while [ -n "$slug" ]; do
    tail="${slug##*-}"
    case "$_BRANCH_SUGGEST_STOPWORDS" in
      *" $tail "*) slug="${slug%"$tail"}"; slug="${slug%-}" ;;
      *) break ;;
    esac
  done
  printf '%s' "$slug"
}

# _branch_suggest_truncate <slug> <max> — cap the length, never end on '-'.
_branch_suggest_truncate() {
  local slug="$1" max="$2"
  if [ "${#slug}" -gt "$max" ]; then
    slug="${slug:0:$max}"
    slug="${slug%-}"
  fi
  printf '%s' "$slug"
}

# _branch_suggest_type <title> — guess the type from the bracketed prefix.
# Mirrors the prefix table in .claude/rules/git-conventions.md and the ticket
# templates; anything unrecognised falls back to `feature`, which is what the
# skill did before this helper existed.
_branch_suggest_type() {
  local t
  t=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  case "$t" in
    "[feature]"*|"[feat]"*) echo feature ;;
    "[bug]"*|"[fix]"*) echo fix ;;
    "[docs]"*) echo docs ;;
    "[chore]"*) echo chore ;;
    "[refactor]"*) echo refactor ;;
    "[test]"*|"[testing]"*) echo test ;;
    "[ci]"*) echo ci ;;
    "[spike]"*) echo spike ;;
    "[prototype]"*) echo prototype ;;
    "[perf]"*) echo perf ;;
    *) echo feature ;;
  esac
}

# _branch_suggest_default <type> <id> <full-slug> — today's shape.
_branch_suggest_default() {
  local type="$1" id="$2" slug="$3"
  slug=$(_branch_suggest_truncate "$slug" 40)
  if [ -n "$slug" ]; then
    printf '%s/%s-%s\n' "$type" "$id" "$slug"
  else
    printf '%s/%s\n' "$type" "$id"
  fi
}

# _branch_suggest_valid_ref <name> — succeed only for a name safe to suggest.
# Rejects an empty name, one over 200 characters, a leading '-' or '/', a
# trailing '/' or '.', '..', '//', and characters outside [A-Za-z0-9._/-].
# When git is available it then has the final word.
_branch_suggest_valid_ref() {
  local n="$1"
  [ -n "$n" ] || return 1
  [ "${#n}" -le 200 ] || return 1
  case "$n" in
    -*|/*|*/|*.|*..*|*//*|*.lock|*/.*|*[!A-Za-z0-9._/-]*) return 1 ;;
  esac
  if command -v git >/dev/null 2>&1; then
    git check-ref-format --branch "$n" >/dev/null 2>&1 || return 1
  fi
  return 0
}

# branch_suggest <ticket-id> <title> [type] — print the suggested branch name.
branch_suggest() {
  local id="${1:-}" title="${2:-}" type="${3:-}"
  if [ -z "$id" ]; then
    echo "branch_suggest: a ticket ID is required" >&2
    return 2
  fi
  if [ -z "$type" ]; then
    type=$(_branch_suggest_type "$title")
  fi

  local full_slug
  # The bracketed prefix is the type marker, not part of the summary. Without
  # this, `[Feature] Add login` would slug to `feature-add-login` and the type
  # would appear twice in the default shape.
  local summary="$title"
  case "$summary" in
    \[*\]*) summary="${summary#*]}" ;;
  esac
  full_slug=$(_branch_suggest_trim_edges "$(_branch_suggest_slug "$summary")")

  local template=""
  if command -v config_get >/dev/null 2>&1; then
    template=$(config_get '.branch.suggested_template' 2>/dev/null)
  fi
  # config_get prints nothing for a missing key, but a JSON null would arrive
  # as the literal string.
  if [ -z "$template" ] || [ "$template" = "null" ]; then
    _branch_suggest_default "$type" "$id" "$full_slug"
    return 0
  fi

  local out="$template"
  # Quote the replacements so bash 5.2 patsub_replacement treats '&' literally.
  out="${out//\{type\}/"$type"}"
  out="${out//\{id\}/"$id"}"
  out="${out//\{title_slug\}/"$full_slug"}"

  # Any brace pair left over is a token this helper does not know.
  case "$out" in
    *'{'*'}'*)
      echo "branch_suggest: .branch.suggested_template has an unknown token: $out" >&2
      echo "branch_suggest: known tokens are {type}, {id}, {title_slug}" >&2
      _branch_suggest_default "$type" "$id" "$full_slug"
      return 0
      ;;
  esac

  out="${out%-}"

  # A template typo must not produce a name git rejects. Fall back to the
  # built-in shape instead.
  if ! _branch_suggest_valid_ref "$out"; then
    echo "branch_suggest: .branch.suggested_template rendered an invalid branch name: $out" >&2
    _branch_suggest_default "$type" "$id" "$full_slug"
    return 0
  fi
  printf '%s\n' "$out"
}
