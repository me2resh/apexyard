#!/bin/bash
# test_tracker_create.sh — the #670 creation abstraction (Part B engine).
#
# tracker_create dispatches issue creation to the per-project tracker CLI,
# mirroring tracker_view. It is a FUNCTION taking args (never a string-templated
# eval of title/body — those are arbitrary text), with built-in adapters for
# gh / glab and a `create_command` template for the `custom` kind. Returns
# normalised JSON {ref, url} on stdout, exit 0; non-zero + empty on failure.
#
# Tests use MOCK CLIs (a fake gh/glab on PATH) — no real issues are created.
#
# Cases:
#   1. gh happy path → {ref, url} parsed from the issue URL
#   2. arg-safety   → a title with spaces + quotes arrives as ONE --title arg
#                     (proves no word-splitting / injection)
#   3. gh body      → the body reaches gh via --body-file (file contents intact)
#   4. per-project glab override dispatches glab (custom kind) [needs YAML parser]
#   5. per-project custom create_command template [needs YAML parser]
#
# Exit 0 = all pass. Exit 1 on first failure.

set -u
unset APEXYARD_OPS_PIN_DIR CLAUDE_CODE_SESSION_ID 2>/dev/null || true

HOOK_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TRACKER_LIB="$HOOK_DIR/_lib-tracker.sh"
CONFIG_LIB="$HOOK_DIR/_lib-read-config.sh"
PORTFOLIO_LIB="$HOOK_DIR/_lib-portfolio-paths.sh"
OPSROOT_LIB="$HOOK_DIR/_lib-ops-root.sh"

PASS=0
FAIL=0
FAILED=""
pass() { PASS=$((PASS+1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL+1)); FAILED="$FAILED\n  - $1"; echo "FAIL: $1"; echo "    expected: [$2]"; echo "    actual:   [$3]"; }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "$2" "$3"; fi; }

HAVE_YAML=no
if command -v yq >/dev/null 2>&1 || python3 -c 'import yaml' >/dev/null 2>&1; then HAVE_YAML=yes; fi

# Build a single-fork sandbox; $1 optional registry body (per-project trackers).
make_sandbox() {
  local sb registry_body="${1:-}"
  sb=$(mktemp -d); sb=$(cd "$sb" && pwd -P)
  mkdir -p "$sb/.claude/hooks" "$sb/bin"
  touch "$sb/onboarding.yaml"
  cp "$TRACKER_LIB"   "$sb/.claude/hooks/_lib-tracker.sh"
  cp "$CONFIG_LIB"    "$sb/.claude/hooks/_lib-read-config.sh"
  cp "$PORTFOLIO_LIB" "$sb/.claude/hooks/_lib-portfolio-paths.sh"
  [ -f "$OPSROOT_LIB" ] && cp "$OPSROOT_LIB" "$sb/.claude/hooks/_lib-ops-root.sh"
  cat > "$sb/.claude/project-config.defaults.json" <<'JSON'
{ "tracker": { "kind": "gh" } }
JSON
  if [ -n "$registry_body" ]; then
    printf '%s\n' "$registry_body" > "$sb/apexyard.projects.yaml"
  else
    printf 'version: 1\nprojects: []\n' > "$sb/apexyard.projects.yaml"
  fi
  echo "$sb"
}

# Mock gh: capture argv (one per line) to $GH_CAPTURE, print an issue URL.
install_gh_mock() {
  local sb="$1"
  cat > "$sb/bin/gh" <<'EOF'
#!/bin/bash
[ -n "${GH_CAPTURE:-}" ] && printf '%s\n' "$@" > "$GH_CAPTURE"
# Only the create path prints a URL; everything else is a no-op success.
if [ "$1" = "issue" ] && [ "$2" = "create" ]; then
  echo "https://github.com/o/r/issues/123"
fi
EOF
  chmod +x "$sb/bin/gh"
}

# ---------------------------------------------------------------------------
SB=$(make_sandbox)
install_gh_mock "$SB"
BODY="$SB/body.md"; printf 'Body line one.\nBody line two.\n' > "$BODY"
cd "$SB" || { echo "FAIL: cd sandbox"; exit 1; }
# shellcheck source=/dev/null
. "$SB/.claude/hooks/_lib-tracker.sh"

# Case 1 — gh happy path: parse {ref, url}.
tracker_clear_cache
out=$(PATH="$SB/bin:$PATH" GH_CAPTURE="$SB/cap1" tracker_create "o/r" "Add login" "$BODY")
assert_eq "tracker_create gh → ref parsed from URL"  "123" "$(printf '%s' "$out" | jq -r '.ref // empty' 2>/dev/null)"
assert_eq "tracker_create gh → url parsed"           "https://github.com/o/r/issues/123" "$(printf '%s' "$out" | jq -r '.url // empty' 2>/dev/null)"

# Case 2 — arg-safety: a title with spaces + a quote must arrive as ONE --title arg.
tracker_clear_cache
TRICKY='weird "title" with spaces'
PATH="$SB/bin:$PATH" GH_CAPTURE="$SB/cap2" tracker_create "o/r" "$TRICKY" "$BODY" >/dev/null
# The capture file has one arg per line; the line after "--title" is the value.
got_title=$(awk 'p{print;exit} /^--title$/{p=1}' "$SB/cap2")
assert_eq "tracker_create gh → title passed as a single arg (injection-safe)" "$TRICKY" "$got_title"

# Case 3 — body reaches gh via --body-file pointing at a file with our contents.
got_bodyflag=$(grep -c -- '--body-file' "$SB/cap2")
assert_eq "tracker_create gh → uses --body-file (not inline --body)" "1" "$got_bodyflag"

# Failure contract — a CLI that errors / prints no URL → non-zero exit + EMPTY
# stdout (PR-C's skills branch on this to decide "did the issue get created?").
cat > "$SB/bin/gh" <<'EOF'
#!/bin/bash
exit 1
EOF
chmod +x "$SB/bin/gh"
tracker_clear_cache
out=$(PATH="$SB/bin:$PATH" tracker_create "o/r" "Add login" "$BODY"); rc=$?
assert_eq "tracker_create gh failure → non-zero exit" "1" "$rc"
assert_eq "tracker_create gh failure → empty stdout"  ""  "$out"

rm -rf "$SB"

# Shape-only contract — kind=none does not call a CLI; it returns 3 and emits
# the body (if given) to stdout for manual/external filing. NOT a failure path.
SBN=$(make_sandbox)
cat > "$SBN/.claude/project-config.defaults.json" <<'JSON'
{ "tracker": { "kind": "none" } }
JSON
(
  cd "$SBN" || exit 1
  # shellcheck source=/dev/null
  . "$SBN/.claude/hooks/_lib-tracker.sh"
  tracker_clear_cache
  out=$(tracker_create "o/r" "t"); rc=$?
  bf=$(mktemp); printf 'TICKET BODY LINE\n' > "$bf"
  out_body=$(tracker_create "o/r" "t" "$bf"); rcb=$?
  rm -f "$bf"
  printf '%s|%s|%s|%s\n' "$rc" "$out" "$rcb" "$out_body"
) > "$SBN/r"
IFS="|" read -r n_rc n_out nb_rc nb_out < "$SBN/r"
assert_eq "tracker_create kind=none → exit 3 (shape-only, not a CLI error)" "3" "$n_rc"
assert_eq "tracker_create kind=none (no body) → empty stdout" "" "$n_out"
assert_eq "tracker_create kind=none (with body) → exit 3" "3" "$nb_rc"
assert_eq "tracker_create kind=none (with body) → emits body for manual filing" "TICKET BODY LINE" "$nb_out"
rm -rf "$SBN"

# Case 4 — per-project glab override dispatches glab (needs a YAML parser).
if [ "$HAVE_YAML" = yes ]; then
  SB2=$(make_sandbox "version: 1
projects:
  - name: gl
    repo: g/p
    tracker:
      kind: glab")
  cat > "$SB2/bin/glab" <<'EOF'
#!/bin/bash
[ -n "${GLAB_CAPTURE:-}" ] && printf '%s\n' "$@" > "$GLAB_CAPTURE"
if [ "$1" = "issue" ] && [ "$2" = "create" ]; then
  echo "Creating issue in g/p..."
  echo "https://gitlab.com/g/p/-/issues/45"
fi
EOF
  chmod +x "$SB2/bin/glab"
  printf 'glab body\n' > "$SB2/body.md"
  (
    cd "$SB2" || exit 1
    # shellcheck source=/dev/null
    . "$SB2/.claude/hooks/_lib-tracker.sh"
    tracker_clear_cache
    out=$(PATH="$SB2/bin:$PATH" GLAB_CAPTURE="$SB2/cap" tracker_create "g/p" "GL title" "$SB2/body.md")
    ref=$(printf '%s' "$out" | jq -r '.ref // empty' 2>/dev/null)
    url=$(printf '%s' "$out" | jq -r '.url // empty' 2>/dev/null)
    desc=$(grep -c -- '--description' "$SB2/cap" 2>/dev/null || echo 0)
    printf '%s\t%s\t%s\n' "$ref" "$url" "$desc"
  ) > "$SB2/result"
  IFS=$'\t' read -r r_ref r_url r_desc < "$SB2/result"
  assert_eq "tracker_create glab → ref parsed from URL"  "45" "$r_ref"
  assert_eq "tracker_create glab → url parsed"           "https://gitlab.com/g/p/-/issues/45" "$r_url"
  assert_eq "tracker_create glab → uses --description (body)" "1" "$r_desc"
  rm -rf "$SB2"
else
  echo "SKIP: tracker_create glab per-project case (no yq / python3+PyYAML)"
fi

# Case 5 — per-project custom create_command. The title/body pass via ENV
# ($TRACKER_TITLE / $TRACKER_BODY_FILE), never string-substituted — so a title
# full of shell metacharacters cannot inject. (needs a YAML parser.)
if [ "$HAVE_YAML" = yes ]; then
  SB3=$(make_sandbox "version: 1
projects:
  - name: cu
    repo: c/u
    tracker:
      kind: custom
      create_command: 'mycli new -R {owner_repo} --title \"\$TRACKER_TITLE\" --bodyfile \"\$TRACKER_BODY_FILE\"'")
  cat > "$SB3/bin/mycli" <<'EOF'
#!/bin/bash
[ -n "${MYCLI_CAPTURE:-}" ] && printf '%s\n' "$@" > "$MYCLI_CAPTURE"
echo "https://example.com/c/u/issues/77"
EOF
  chmod +x "$SB3/bin/mycli"
  printf 'custom body\n' > "$SB3/body.md"
  (
    cd "$SB3" || exit 1
    # shellcheck source=/dev/null
    . "$SB3/.claude/hooks/_lib-tracker.sh"
    tracker_clear_cache
    EVIL='hi"; touch PWNED; echo "'
    out=$(PATH="$SB3/bin:$PATH" MYCLI_CAPTURE="$SB3/cap" tracker_create "c/u" "$EVIL" "$SB3/body.md")
    ref=$(printf '%s' "$out" | jq -r '.ref // empty' 2>/dev/null)
    title_seen=$(awk 'p{print;exit} /^--title$/{p=1}' "$SB3/cap")
    pwned=no; [ -e "$SB3/PWNED" ] && pwned=yes
    printf '%s\t%s\t%s\n' "$ref" "$title_seen" "$pwned"
  ) > "$SB3/result"
  IFS=$'\t' read -r c_ref c_title c_pwned < "$SB3/result"
  assert_eq "tracker_create custom → ref parsed"                       "77" "$c_ref"
  assert_eq "tracker_create custom → title passed verbatim (env arg)"  'hi"; touch PWNED; echo "' "$c_title"
  assert_eq "tracker_create custom → NO shell injection (no PWNED)"    "no" "$c_pwned"
  rm -rf "$SB3"
else
  echo "SKIP: tracker_create custom per-project case (no yq / python3+PyYAML)"
fi

echo "=========================================="
echo "PASS: $PASS  FAIL: $FAIL"
if [ "$FAIL" -gt 0 ]; then printf "Failed:%b\n" "$FAILED"; exit 1; fi
exit 0
