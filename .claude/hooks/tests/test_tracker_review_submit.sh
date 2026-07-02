#!/bin/bash
# test_tracker_review_submit.sh — the #758 review-submission abstraction.
#
# tracker_review_submit dispatches PR/MR review posting to the per-project git
# host CLI, mirroring tracker_create. It is a FUNCTION taking args (the review
# body reaches the CLI via a file / a quoted -m value / an env var — never an
# eval'd string), with built-in adapters for gh / glab and a `review_command`
# template for the `custom` kind. Returns the CLI's exit status; kind=none is a
# shape-only no-op that returns 3 and echoes the body for manual filing.
#
# Tests use MOCK CLIs (a fake gh/glab/custom on PATH) — no real review is posted.
#
# Cases:
#   1. gh happy path → correct `gh pr review` verb + --body-file
#   2. gh verdict verbs → approve / request-changes map to the right flag
#   3. gh verdict normalisation → an unknown verdict falls back to --comment
#   4. gh failure → the CLI's non-zero exit propagates
#   5. kind=none → returns 3, echoes the body (shape-only, not a CLI error)
#   6. per-project glab override → mr approve / mr note create dispatch [needs YAML]
#   7. per-project custom review_command → env-passed body, injection-safe [needs YAML]
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

# Mock gh: capture argv (one per line) to $GH_CAPTURE, exit 0.
install_gh_mock() {
  local sb="$1"
  cat > "$sb/bin/gh" <<'EOF'
#!/bin/bash
[ -n "${GH_CAPTURE:-}" ] && printf '%s\n' "$@" > "$GH_CAPTURE"
exit 0
EOF
  chmod +x "$sb/bin/gh"
}

# ---------------------------------------------------------------------------
SB=$(make_sandbox)
install_gh_mock "$SB"
BODY="$SB/rev.md"; printf 'APPROVED — verdict in body.\nSecond line.\n' > "$BODY"
cd "$SB" || { echo "FAIL: cd sandbox"; exit 1; }
# shellcheck source=/dev/null
. "$SB/.claude/hooks/_lib-tracker.sh"

# Case 1 — gh comment: correct verb + --body-file pointing at our file.
tracker_clear_cache
PATH="$SB/bin:$PATH" GH_CAPTURE="$SB/c1" tracker_review_submit "o/r" 42 comment "$BODY"; rc=$?
assert_eq "gh comment → exit 0" "0" "$rc"
assert_eq "gh comment → 'pr review' subcommand" "review" "$(sed -n '2p' "$SB/c1")"
assert_eq "gh comment → PR number passed"       "42"     "$(sed -n '3p' "$SB/c1")"
assert_eq "gh comment → --comment verb"         "1"      "$(grep -c -- '--comment' "$SB/c1")"
assert_eq "gh comment → --body-file used (not inline --body)" "1" "$(grep -c -- '--body-file' "$SB/c1")"
got_bf=$(awk 'p{print;exit} /^--body-file$/{p=1}' "$SB/c1")
assert_eq "gh comment → --body-file points at our file" "$BODY" "$got_bf"

# Case 2 — verdict verbs map to the right gh flag.
tracker_clear_cache
PATH="$SB/bin:$PATH" GH_CAPTURE="$SB/c2a" tracker_review_submit "o/r" 42 approve "$BODY" >/dev/null
assert_eq "gh approve → --approve verb" "1" "$(grep -c -- '--approve' "$SB/c2a")"
tracker_clear_cache
PATH="$SB/bin:$PATH" GH_CAPTURE="$SB/c2b" tracker_review_submit "o/r" 42 request-changes "$BODY" >/dev/null
assert_eq "gh request-changes → --request-changes verb" "1" "$(grep -c -- '--request-changes' "$SB/c2b")"

# Case 3 — an unknown verdict normalises to --comment (never a raw injection).
tracker_clear_cache
PATH="$SB/bin:$PATH" GH_CAPTURE="$SB/c3" tracker_review_submit "o/r" 42 'bogus; rm -rf /' "$BODY" >/dev/null
assert_eq "gh unknown verdict → normalised to --comment"      "1" "$(grep -c -- '--comment' "$SB/c3")"
assert_eq "gh unknown verdict → no stray --approve"           "0" "$(grep -c -- '--approve' "$SB/c3")"

# Case 4 — the CLI's non-zero exit propagates (2>/dev/null must not mask it).
cat > "$SB/bin/gh" <<'EOF'
#!/bin/bash
exit 1
EOF
chmod +x "$SB/bin/gh"
tracker_clear_cache
PATH="$SB/bin:$PATH" tracker_review_submit "o/r" 42 comment "$BODY"; rc=$?
assert_eq "gh failure → non-zero exit propagates" "1" "$rc"

# Case 4b — a non-numeric PR id is rejected before any dispatch/eval (matches the
# documented "{pr} is numeric" contract; defense-in-depth for the custom eval).
install_gh_mock "$SB"
tracker_clear_cache
PATH="$SB/bin:$PATH" GH_CAPTURE="$SB/cbad" tracker_review_submit "o/r" '9; rm -rf /' comment "$BODY"; rc=$?
assert_eq "non-numeric PR id → rejected (non-zero)" "1" "$rc"
assert_eq "non-numeric PR id → no CLI invoked"      "no" "$([ -f "$SB/cbad" ] && echo yes || echo no)"
rm -rf "$SB"

# Case 5 — kind=none: no CLI call; returns 3 and echoes the body for manual
# filing. NOT a failure path.
SBN=$(make_sandbox)
cat > "$SBN/.claude/project-config.defaults.json" <<'JSON'
{ "tracker": { "kind": "none" } }
JSON
(
  cd "$SBN" || exit 1
  # shellcheck source=/dev/null
  . "$SBN/.claude/hooks/_lib-tracker.sh"
  tracker_clear_cache
  bf=$(mktemp); printf 'REVIEW BODY TO FILE MANUALLY\n' > "$bf"
  out=$(tracker_review_submit "o/r" 42 comment "$bf"); rc=$?
  out2=$(tracker_review_submit "o/r" 42 comment); rc2=$?
  rm -f "$bf"
  printf '%s|%s|%s|%s\n' "$rc" "$out" "$rc2" "$out2"
) > "$SBN/r"
IFS="|" read -r n_rc n_out nb_rc nb_out < "$SBN/r"
assert_eq "kind=none → exit 3 (shape-only, not a CLI error)" "3" "$n_rc"
assert_eq "kind=none (with body) → echoes body for manual filing" "REVIEW BODY TO FILE MANUALLY" "$n_out"
assert_eq "kind=none (no body) → exit 3" "3" "$nb_rc"
assert_eq "kind=none (no body) → empty stdout" "" "$nb_out"
rm -rf "$SBN"

# Case 6 — per-project glab override dispatches glab (needs a YAML parser).
# The glab mock APPENDS each invocation (space-joined) so approve+note (two
# calls) are both observable.
if [ "$HAVE_YAML" = yes ]; then
  SB2=$(make_sandbox "version: 1
projects:
  - name: gl
    repo: g/p
    tracker:
      kind: glab")
  cat > "$SB2/bin/glab" <<'EOF'
#!/bin/bash
[ -n "${GLAB_CAPTURE:-}" ] && printf '%s\n' "$*" >> "$GLAB_CAPTURE"
exit 0
EOF
  chmod +x "$SB2/bin/glab"
  printf 'glab review body\n' > "$SB2/rev.md"
  (
    cd "$SB2" || exit 1
    # shellcheck source=/dev/null
    . "$SB2/.claude/hooks/_lib-tracker.sh"
    # comment → a single `mr note create` with -m
    tracker_clear_cache
    : > "$SB2/capc"
    PATH="$SB2/bin:$PATH" GLAB_CAPTURE="$SB2/capc" tracker_review_submit "g/p" 7 comment "$SB2/rev.md"; rcc=$?
    note_c=$(grep -c 'mr note create' "$SB2/capc")
    m_c=$(grep -c -- '-m' "$SB2/capc")
    # request-changes → also a note (GitLab has no request-changes state)
    tracker_clear_cache
    : > "$SB2/capr"
    PATH="$SB2/bin:$PATH" GLAB_CAPTURE="$SB2/capr" tracker_review_submit "g/p" 7 request-changes "$SB2/rev.md" >/dev/null
    note_r=$(grep -c 'mr note create' "$SB2/capr")
    # approve (with body) → an `mr approve` AND a note
    tracker_clear_cache
    : > "$SB2/capa"
    PATH="$SB2/bin:$PATH" GLAB_CAPTURE="$SB2/capa" tracker_review_submit "g/p" 7 approve "$SB2/rev.md" >/dev/null
    appr_a=$(grep -c 'mr approve' "$SB2/capa")
    note_a=$(grep -c 'mr note create' "$SB2/capa")
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$rcc" "$note_c" "$m_c" "$note_r" "$appr_a" "$note_a"
  ) > "$SB2/result"
  IFS=$'\t' read -r g_rc g_notec g_mc g_noter g_appra g_notea < "$SB2/result"
  assert_eq "glab comment → exit 0"                        "0" "$g_rc"
  assert_eq "glab comment → posts via 'mr note create'"    "1" "$g_notec"
  assert_eq "glab comment → passes body via -m"            "1" "$g_mc"
  assert_eq "glab request-changes → posts a note (no MR request-changes state)" "1" "$g_noter"
  assert_eq "glab approve (with body) → calls 'mr approve'" "1" "$g_appra"
  assert_eq "glab approve (with body) → also attaches a note" "1" "$g_notea"
  rm -rf "$SB2"
else
  echo "SKIP: glab per-project case (no yq / python3+PyYAML)"
fi

# Case 7 — per-project custom review_command. The body passes via ENV
# ($TRACKER_REVIEW_BODY_FILE), never string-substituted — so a review body full
# of shell metacharacters cannot inject. {verdict} / {pr} / {owner_repo} ARE
# substituted (trusted: enum / numeric / registry slug). (needs a YAML parser.)
if [ "$HAVE_YAML" = yes ]; then
  SB3=$(make_sandbox "version: 1
projects:
  - name: cu
    repo: c/u
    tracker:
      kind: custom
      review_command: 'mycli review -R {owner_repo} --pr {pr} --verdict {verdict} --bodyfile \"\$TRACKER_REVIEW_BODY_FILE\"'")
  cat > "$SB3/bin/mycli" <<'EOF'
#!/bin/bash
[ -n "${MYCLI_CAPTURE:-}" ] && printf '%s\n' "$@" > "$MYCLI_CAPTURE"
exit 0
EOF
  chmod +x "$SB3/bin/mycli"
  # A body path whose CONTENTS are hostile — proves the file route is inert.
  printf 'hi"; touch PWNED; echo "\n' > "$SB3/rev.md"
  (
    cd "$SB3" || exit 1
    # shellcheck source=/dev/null
    . "$SB3/.claude/hooks/_lib-tracker.sh"
    tracker_clear_cache
    PATH="$SB3/bin:$PATH" MYCLI_CAPTURE="$SB3/cap" tracker_review_submit "c/u" 9 request-changes "$SB3/rev.md"; rc=$?
    verdict_seen=$(awk 'p{print;exit} /^--verdict$/{p=1}' "$SB3/cap")
    pr_seen=$(awk 'p{print;exit} /^--pr$/{p=1}' "$SB3/cap")
    pwned=no; [ -e "$SB3/PWNED" ] && pwned=yes
    printf '%s\t%s\t%s\t%s\n' "$rc" "$verdict_seen" "$pr_seen" "$pwned"
  ) > "$SB3/result"
  IFS=$'\t' read -r c_rc c_verdict c_pr c_pwned < "$SB3/result"
  assert_eq "custom → exit 0"                              "0" "$c_rc"
  assert_eq "custom → {verdict} substituted"              "request-changes" "$c_verdict"
  assert_eq "custom → {pr} substituted"                   "9" "$c_pr"
  assert_eq "custom → NO shell injection from body (no PWNED)" "no" "$c_pwned"
  rm -rf "$SB3"
else
  echo "SKIP: custom per-project case (no yq / python3+PyYAML)"
fi

echo "=========================================="
echo "PASS: $PASS  FAIL: $FAIL"
if [ "$FAIL" -gt 0 ]; then printf "Failed:%b\n" "$FAILED"; exit 1; fi
exit 0
