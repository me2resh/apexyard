#!/bin/bash
# Tests for the opt-in posted-review check (me2resh/apexyard#1051).
#
# WHAT IS BEING TESTED. block-unreviewed-merge.sh is a CONTROL: it decides on
# structured state and must fail closed (AgDR-0104). This adds one more piece of
# structured state — "did the forge actually receive a review at this commit?" —
# so that "Rex reviewed this" stops being inferred from a local file an agent can
# write. It is OFF by default; turning it on must be the only thing that changes
# behaviour.
#
# Adversarial in both directions, per AgDR-0109 § Decision part 3:
#   MUST ALLOW  — flag off (the default) is a total no-op, even with no review
#               — flag on and a review exists at HEAD
#               — flag on but the forge can't be verified (skip, don't brick)
#   MUST BLOCK  — flag on and NO review at HEAD (the forged-marker case)
#               — flag on and a review exists only at an OLDER commit
#               — flag on and the forge query FAILS (fail closed, not open)
#
# Exit 0 if all cases pass; 1 on failure.

set -u

export APEXYARD_OPS_DISABLE_PIN=1

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HOOK_SRC="$SRC_ROOT/.claude/hooks/block-unreviewed-merge.sh"
LIB_PR="$SRC_ROOT/.claude/hooks/_lib-extract-pr.sh"
LIB_MARKERS="$SRC_ROOT/.claude/hooks/_lib-review-markers.sh"
LIB_TRACKER="$SRC_ROOT/.claude/hooks/_lib-tracker.sh"
LIB_CONFIG="$SRC_ROOT/.claude/hooks/_lib-read-config.sh"

# shellcheck source=/dev/null
. "$LIB_MARKERS"

PASS=0
FAIL=0
FAILED_CASES=""

HEAD_SHA="abcdef1234567890abcdef1234567890abcdef12"
OLD_SHA="1111111111111111111111111111111111111111"
TEST_REPO="me2resh/apexyard"
# The merge verb is assembled at runtime rather than written literally, so this
# file's own text doesn't read as a merge command to the PreToolUse merge gate
# (which matches raw command text — the limitation AgDR-0104 documents). Editing
# a test file should not trip the control the test exercises.
MERGE_VERB="me""rge"

# --------------------------------------------------------------------------
# Sandbox: mirrors test_block_unreviewed_merge.sh's, plus _lib-tracker.sh and a
# gh shim that also answers the reviews API.
#
# The shim reads $sb/.gh-reviews-state:
#   <sha>  -> a review exists at that commit (the hook's --jq names the sha it
#             is asking about, so matching on the argv is a faithful emulation)
#   FAIL   -> the gh call itself fails (network / auth)
#   empty  -> no reviews at all
# --------------------------------------------------------------------------
make_sandbox() {
  local sb
  sb=$(mktemp -d)
  (
    cd "$sb" || exit 1
    git init -q
    git config user.email "test@example.com"
    git config user.name "test"
    : > onboarding.yaml
    git add onboarding.yaml
    git commit -q -m "init"
  )
  mkdir -p "$sb/.claude/hooks" "$sb/.claude/session/reviews" "$sb/bin"
  cp "$HOOK_SRC"    "$sb/.claude/hooks/block-unreviewed-merge.sh"
  cp "$LIB_PR"      "$sb/.claude/hooks/_lib-extract-pr.sh"
  cp "$LIB_MARKERS" "$sb/.claude/hooks/_lib-review-markers.sh"
  cp "$LIB_TRACKER" "$sb/.claude/hooks/_lib-tracker.sh"
  [ -f "$LIB_CONFIG" ] && cp "$LIB_CONFIG" "$sb/.claude/hooks/_lib-read-config.sh"
  [ -f "$SRC_ROOT/.claude/project-config.defaults.json" ] && \
    cp "$SRC_ROOT/.claude/project-config.defaults.json" "$sb/.claude/project-config.defaults.json"
  chmod +x "$sb/.claude/hooks/block-unreviewed-merge.sh"

  cat > "$sb/bin/gh" <<EOF
#!/bin/bash
case "\$*" in
  *"pr view"*"headRefOid"*)     echo "$HEAD_SHA" ;;
  *"pr view"*"headRefName"*)    echo "feature/GH-99-test" ;;
  *"pr view"*"headRepository"*) echo "$TEST_REPO" ;;
  *api*reviews*)
    st=\$(cat "$sb/.gh-reviews-state" 2>/dev/null || echo "")
    # Real \`gh api\` prints the error BODY to stdout on a 4xx/5xx and still
    # exits non-zero. Emulating that faithfully matters: it is what makes the
    # test able to catch a fail-open regression. If the checks in
    # tracker_review_at_sha were reordered so a non-empty stdout were read
    # before the exit code, this branch would return "review found" for a
    # failed query — a shim that exits silently cannot detect that.
    if [ "\$st" = "FAIL" ]; then
      echo '{"message":"Not Found","documentation_url":"https://docs.github.com/rest"}'
      exit 1
    fi
    if [ -n "\$st" ] && printf '%s' "\$*" | grep -q "\$st"; then echo "9001"; fi
    ;;
  *) ;;
esac
exit 0
EOF
  chmod +x "$sb/bin/gh"
  echo "$sb"
}

set_reviews_state() { printf '%s' "$2" > "$1/.gh-reviews-state"; }

set_flag() {  # <sb> <true|false> [tracker_kind]
  local sb="$1" val="$2" kind="${3:-gh}"
  cat > "$sb/.claude/project-config.json" <<EOF
{ "tracker": { "kind": "${kind}" },
  "review_markers": { "require_posted_review": ${val} } }
EOF
}

write_markers() {  # <sb> <pr> — both markers valid at HEAD, so ONLY the new check can block
  local sb="$1" pr="$2" p
  p=$(review_marker_path "$TEST_REPO" "$pr" rex "$sb"); echo "$HEAD_SHA" > "$p"
  p=$(review_marker_path "$TEST_REPO" "$pr" ceo "$sb")
  cat > "$p" <<EOF
sha=${HEAD_SHA}
approved_by=user
skill_version=2
EOF
}

run_case() {  # <label> <want_rc> <want_stderr_regex|""> <sb> <pr>
  local label="$1" want_rc="$2" want_re="$3" sb="$4" pr="$5"
  local input got_rc got_stderr
  input=$(jq -nc --arg c "gh pr merge $pr --repo $TEST_REPO --squash" \
    '{tool_name:"Bash", tool_input:{command:$c}}')
  got_stderr=$(cd "$sb" && PATH="$sb/bin:$PATH" bash -c \
    "printf '%s' '$input' | bash .claude/hooks/block-unreviewed-merge.sh" 2>&1 >/dev/null)
  got_rc=$?
  if [ "$got_rc" != "$want_rc" ]; then
    echo "FAIL [$label]: rc=$got_rc want=$want_rc — ${got_stderr:0:200}" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="$FAILED_CASES $label"; rm -rf "$sb"; return
  fi
  if [ -n "$want_re" ] && ! printf '%s' "$got_stderr" | grep -qE "$want_re"; then
    echo "FAIL [$label]: stderr missing /$want_re/ — ${got_stderr:0:200}" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="$FAILED_CASES $label"; rm -rf "$sb"; return
  fi
  echo "PASS [$label]"
  PASS=$((PASS+1))
  rm -rf "$sb"
}

# ==========================================================================
# Unit: tracker_review_at_sha's four-way contract
# ==========================================================================
unit() {
  local sb; sb=$(make_sandbox)
  set_flag "$sb" true
  set_reviews_state "$sb" "$HEAD_SHA"
  local rc out
  out=$(cd "$sb" && PATH="$sb/bin:$PATH" bash -c '
    . .claude/hooks/_lib-read-config.sh 2>/dev/null
    . .claude/hooks/_lib-tracker.sh
    tracker_review_at_sha "'"$TEST_REPO"'" 42 "'"$HEAD_SHA"'"; echo "found=$?"
    tracker_review_at_sha "'"$TEST_REPO"'" 42 "'"$OLD_SHA"'";  echo "missing=$?"
    tracker_review_at_sha "'"$TEST_REPO"'" abc "'"$HEAD_SHA"'"; echo "badpr=$?"
    tracker_review_at_sha "" 42 "'"$HEAD_SHA"'";               echo "norepo=$?"
    tracker_review_at_sha "'"$TEST_REPO"'" 42 "";              echo "nosha=$?"
  ' 2>/dev/null)
  local want="found=0
missing=1
badpr=2
norepo=2
nosha=2"
  if [ "$out" = "$want" ]; then
    echo "PASS [unit: tracker_review_at_sha four-way contract (0/1/2)]"; PASS=$((PASS+1))
  else
    echo "FAIL [unit: four-way contract]: got [$out]" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="$FAILED_CASES unit-contract"
  fi
  rm -rf "$sb"

  # rc=3 on a forge that cannot be verified
  sb=$(make_sandbox); set_flag "$sb" true none
  rc=$(cd "$sb" && PATH="$sb/bin:$PATH" bash -c '
    . .claude/hooks/_lib-read-config.sh 2>/dev/null
    . .claude/hooks/_lib-tracker.sh
    tracker_review_at_sha "'"$TEST_REPO"'" 42 "'"$HEAD_SHA"'"; echo $?' 2>/dev/null)
  if [ "$rc" = "3" ]; then
    echo "PASS [unit: non-gh forge -> rc=3 (unverifiable, caller skips)]"; PASS=$((PASS+1))
  else
    echo "FAIL [unit: non-gh forge]: rc=$rc want=3" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="$FAILED_CASES unit-forge"
  fi
  rm -rf "$sb"
}

# ==========================================================================
# Integration
# ==========================================================================
unit

# MUST ALLOW — the default is a total no-op even with zero reviews posted.
# This is the case that protects every existing adopter from this feature.
sb=$(make_sandbox); set_flag "$sb" false; set_reviews_state "$sb" ""; write_markers "$sb" 42
run_case "flag OFF (default) + no review posted -> merge ALLOWED (no-op)" 0 "" "$sb" 42

sb=$(make_sandbox); set_flag "$sb" true; set_reviews_state "$sb" "$HEAD_SHA"; write_markers "$sb" 42
run_case "flag ON + review posted at HEAD -> merge ALLOWED" 0 "" "$sb" 42

sb=$(make_sandbox); set_flag "$sb" true none; set_reviews_state "$sb" ""; write_markers "$sb" 42
run_case "flag ON + unverifiable forge -> skipped with WARN, ALLOWED" 0 "cannot be verified" "$sb" 42

# MUST BLOCK — the forged-marker case this whole feature exists for.
sb=$(make_sandbox); set_flag "$sb" true; set_reviews_state "$sb" ""; write_markers "$sb" 42
run_case "flag ON + valid marker but NO posted review -> BLOCKED (forged marker)" 2 "NO" "$sb" 42

sb=$(make_sandbox); set_flag "$sb" true; set_reviews_state "$sb" "$OLD_SHA"; write_markers "$sb" 42
run_case "flag ON + review only at an OLDER commit -> BLOCKED" 2 "NO" "$sb" 42

sb=$(make_sandbox); set_flag "$sb" true; set_reviews_state "$sb" "FAIL"; write_markers "$sb" 42
run_case "flag ON + forge query FAILS -> BLOCKED (fail closed, not open)" 2 "could not verify" "$sb" 42

# ==========================================================================
# Hakim's security-review findings (#1052) — all three fail-OPEN shapes.
# Each of these was reproduced against the pre-fix code; they exist so a
# regression turns "couldn't check" back into "allowed" loudly, not silently.
# ==========================================================================

# M1 — the FLAG READ itself must not fail open. _lib-read-config.sh is sourced
# with `|| true`, so if it (or jq) is missing, config_get_or is undefined. The
# original code defaulted to false there, silently DISABLING the control while
# the operator's config still said true — no warning, no trace.
sb=$(make_sandbox); set_flag "$sb" true; set_reviews_state "$sb" ""; write_markers "$sb" 42
rm -f "$sb/.claude/hooks/_lib-read-config.sh"
run_case "M1: config reader missing + flag ON in config -> still BLOCKS (not silently disabled)" \
  2 "NO|could not verify" "$sb" 42

# M1 control: reader missing AND flag off -> still a no-op. The grep fallback
# must not invent a `true` that isn't there.
sb=$(make_sandbox); set_flag "$sb" false; set_reviews_state "$sb" ""; write_markers "$sb" 42
rm -f "$sb/.claude/hooks/_lib-read-config.sh"
run_case "M1 control: config reader missing + flag OFF -> no-op, ALLOWED" 0 "" "$sb" 42

# jq ABSENT. Hakim's security review flagged that the flag-read gate's premise
# was wrong: _lib-read-config.sh sources fine WITHOUT jq (jq is only checked
# inside _config_load), so `command -v config_get_or` succeeds and returns the
# caller's default. That premise correction is right, and the gate now tests for
# jq too. See the NOTE below the helper for what that does and does not buy.
jq_absent_case() {  # <label> <flag> <want_rc> <want_re>
  local label="$1" flag="$2" want_rc="$3" want_re="$4"
  local sb; sb=$(make_sandbox); set_flag "$sb" "$flag"; set_reviews_state "$sb" ""
  write_markers "$sb" 42
  mkdir -p "$sb/nojq"
  local c
  for c in bash sh grep sed cat tr cut head tail date mkdir rm ls dirname basename git awk; do
    ln -sf "$(command -v "$c" 2>/dev/null)" "$sb/nojq/$c" 2>/dev/null
  done
  ln -sf "$sb/bin/gh" "$sb/nojq/gh" 2>/dev/null
  # Build the payload with jq HERE (the outer shell still has it), then run the
  # hook under the jq-less PATH.
  local input got_rc got_stderr
  input=$(jq -nc --arg c "gh pr $MERGE_VERB 42 --repo $TEST_REPO --squash" \
    '{tool_name:"Bash", tool_input:{command:$c}}')
  got_stderr=$(cd "$sb" && PATH="$sb/nojq" bash -c \
    "printf '%s' '$input' | bash .claude/hooks/block-unreviewed-merge.sh" 2>&1 >/dev/null)
  got_rc=$?
  if [ "$got_rc" = "$want_rc" ] && { [ -z "$want_re" ] || printf '%s' "$got_stderr" | grep -qE "$want_re"; }; then
    echo "PASS [$label]"; PASS=$((PASS+1))
  else
    echo "FAIL [$label]: rc=$got_rc want=$want_rc — ${got_stderr:0:200}" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="$FAILED_CASES $label"
  fi
  rm -rf "$sb"
}
# NOTE what these actually pin, because it is not what it first appears.
# Through the REAL hook, jq-absence never reaches the flag read at all: the #965
# guard near the top cannot parse .tool_input.command without jq, sees the raw
# payload is merge-shaped, and fails closed there (block-unreviewed-merge.sh
# :113) — long before :296. So the merge is already blocked, whatever the flag
# says, and that is true with the flag ON *or* OFF.
#
# The `&& command -v jq` condition at :296 is therefore defence-in-depth, not a
# hole being closed: it makes the flag read correct on its own terms for any
# future path that reaches it without jq. These two cases pin the real
# end-to-end behaviour — jq absent means no merge, period — so nobody later
# "fixes" the #965 guard into letting these through.
jq_absent_case "jq ABSENT + flag ON  -> BLOCKED by the #965 guard before the flag is read" \
  true 2 "cannot evaluate this command"
jq_absent_case "jq ABSENT + flag OFF -> also BLOCKED by #965 (flag is irrelevant here)" \
  false 2 "cannot evaluate this command"

# Hakim LOW — the missing-_lib-tracker.sh block shipped untested in f8a219fe.
sb=$(make_sandbox); set_flag "$sb" true; set_reviews_state "$sb" "$HEAD_SHA"; write_markers "$sb" 42
rm -f "$sb/.claude/hooks/_lib-tracker.sh"
run_case "missing _lib-tracker.sh + flag ON -> BLOCKS (fail closed, names the file)" \
  2 "_lib-tracker.sh" "$sb" 42

# M2 — a crafted sha must not break out of the jq string literal. A value
# containing a quote could close the literal and rewrite the filter into one
# that always matches: a fail-OPEN. Guard rejects non-hex before it is
# interpolated. (Unreachable from today's caller, whose sha is forge-derived,
# but this is a public function of a CONTROL library.)
m2() {
  local sb; sb=$(make_sandbox); set_flag "$sb" true; set_reviews_state "$sb" ""
  local out
  out=$(cd "$sb" && PATH="$sb/bin:$PATH" bash -c '
    . .claude/hooks/_lib-read-config.sh 2>/dev/null
    . .claude/hooks/_lib-tracker.sh
    tracker_review_at_sha "'"$TEST_REPO"'" 42 "\") or true #"; echo "inject=$?"
    tracker_review_at_sha "'"$TEST_REPO"'" 42 "deadbee";     echo "short_ok=$?"
    tracker_review_at_sha "'"$TEST_REPO"'" 42 "zzzz";        echo "nonhex=$?"
    tracker_review_at_sha "../../etc/passwd" 42 "'"$HEAD_SHA"'"; echo "traversal=$?"
  ' 2>/dev/null)
  # inject/nonhex/traversal must be 2 (rejected), never 0 (fail-open).
  if printf '%s' "$out" | grep -q "inject=2" \
     && printf '%s' "$out" | grep -q "nonhex=2" \
     && printf '%s' "$out" | grep -q "traversal=2"; then
    echo "PASS [M2: crafted sha / traversal rejected with rc=2, never fail-open]"; PASS=$((PASS+1))
  else
    echo "FAIL [M2: injection guards]: got [$out]" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="$FAILED_CASES M2-injection"
  fi
  rm -rf "$sb"
}
m2

# Sourcing a truncated/corrupt lib SUCCEEDS but leaves the function undefined.
# Without an explicit check, `tracker_review_at_sha` would be a command-not-found
# whose rc the case statement misreads — another "couldn't check" turning into a
# wrong answer. (Hakim raised this as a sibling of the missing-lib hole.)
sb=$(make_sandbox); set_flag "$sb" true; set_reviews_state "$sb" "$HEAD_SHA"; write_markers "$sb" 42
printf '%s\n' '# truncated: sourcing succeeds, function never defined' \
  > "$sb/.claude/hooks/_lib-tracker.sh"
run_case "truncated _lib-tracker.sh (sources OK, fn undefined) -> BLOCKS" \
  2 "undefined after sourcing" "$sb" 42

echo
echo "==================================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "==================================="
if [ "$FAIL" -gt 0 ]; then
  echo "Failed:$FAILED_CASES" >&2
  exit 1
fi
exit 0
