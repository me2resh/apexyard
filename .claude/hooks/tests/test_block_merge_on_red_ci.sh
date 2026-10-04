#!/bin/bash
# Tests for block-merge-on-red-ci.sh — forge-aware CI-status gate (#790).
#
# #767 made block-unreviewed-merge.sh forge-aware (gh/glab); this hook was
# the one sibling merge gate still hardcoded to `gh pr checks`, so a GitLab
# project's `glab mr merge` sailed through with no CI-status check at all.
# This suite proves:
#
#   - the gh path is byte-identical to pre-#790 behaviour (green/red/no-CI/
#     variable-substituted/non-merge cases, mirroring the hook's own header
#     comment contract)
#   - the new glab path resolves the MR's head-pipeline status via a mocked
#     `glab mr view --output json` and maps it to the same allow/block shape
#   - the glab path FAILS CLOSED when the pipeline status can't be resolved
#     at all (glab missing / network-auth failure / unparseable response) —
#     an unresolvable status must never be treated as green
#
# Each case builds an isolated sandbox with the hook + _lib-extract-pr.sh,
# mocks `gh` and/or `glab` to return a deterministic status without hitting
# any real forge, pipes a synthetic PreToolUse JSON for the merge command,
# and asserts exit code (0 = pass-through, 2 = blocked) + a stderr regex.
#
# Exit 0 if all cases pass; 1 on first failure.

set -u

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HOOK_SRC="${HOOK_SRC:-$SRC_ROOT/.claude/hooks/block-merge-on-red-ci.sh}"
LIB_PR="${LIB_PR_OVERRIDE:-$SRC_ROOT/.claude/hooks/_lib-extract-pr.sh}"

for f in "$HOOK_SRC" "$LIB_PR"; do
  if [ ! -f "$f" ]; then
    echo "FAIL: required source missing: $f" >&2
    exit 1
  fi
done

PASS=0
FAIL=0
FAILED_CASES=""

TEST_REPO="me2resh/apexyard"
TEST_SHA="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"

# make_sandbox <gh_mode> <glab_mode>
#   gh_mode:   green | red | pending | none | none_exit0 | red_named_phrase |
#              full_msg_name_red | full_msg_name_green | multiline_wrap | ""
#              (mock `gh pr checks` behaviour; #1523 modes cover the
#              "no checks reported" false-allow)
#   glab_mode: success | pending | failure | none | unresolvable |
#              nonzero_exit | auth_error | http_error | truncated |
#              scalar | array | ""
#              (mock `glab mr view --output json` behaviour)
# Empty mode = mock exits 0 with no output (only relevant CLI is installed
# per test; the other is left as a stub that should never be called).
#
# The "success" / "pending" / "failure" / "none" bodies all include an
# `.iid` field, matching a real `glab mr view --output json` response —
# this is what `resolve_ci_status_glab`'s MR-object validity check keys
# off (#793 fail-open fix). The new failure-shape modes below deliberately
# omit `.iid` (or aren't a JSON object at all), the way a broken/hostile
# response would be.
# The third argument sets the Actions API response. `gh pr checks`
# prints the same "no checks reported" line for several different states,
# which is the defect #1519 reports, so this selects what the follow-up API
# calls see:
#
#   no_ci    zero active workflows — the genuine no-CI repo, allow
#   gated    workflows plus an action_required run for the head — a fork PR
#            waiting at "Approve and run workflows", must BLOCK
#   filtered workflows but no run for this head — path/branch filters, allow
#            but do not claim the repo has no CI
#   unknown  the workflows call fails — allow with an unverified-CI note
make_sandbox() {
  local gh_mode="$1" glab_mode="$2" nocheck_mode="${3:-unknown}"
  local sb
  sb=$(mktemp -d)
  mkdir -p "$sb/.claude/hooks" "$sb/bin"
  cp "$HOOK_SRC" "$sb/.claude/hooks/block-merge-on-red-ci.sh"
  cp "$LIB_PR"   "$sb/.claude/hooks/_lib-extract-pr.sh"
  chmod +x "$sb/.claude/hooks/block-merge-on-red-ci.sh"

  cat > "$sb/bin/gh" <<EOF
#!/bin/bash
if [ "\$1" = "api" ]; then echo "\$2" >> "$sb/api-calls"; fi
case "\$*" in
  *"pr checks"*)
    case "$gh_mode" in
      green) printf 'build\tpass\t1m\thttps://x\n'; exit 0 ;;
      red)   printf 'build\tfail\t1m\thttps://x\n'; exit 1 ;;
      pending) printf 'build\tpending\t1m\thttps://x\n'; exit 8 ;;
      none)  echo "no checks reported on the 'feature' branch"; exit 1 ;;
      # #1523: exact CLI message but exit 0 — must NOT take the no-checks allow arm
      none_exit0) echo "no checks reported on the 'feature' branch"; exit 0 ;;
      # #1523: failing check + passing check named like the substring phrase
      red_named_phrase)
        printf 'build\tfail\t1m\thttps://x\n'
        printf 'no checks reported\tpass\t1m\thttps://x\n'
        exit 1
        ;;
      # #1523: check NAME is the full CLI message; exit 1 (fail) → block
      full_msg_name_red)
        printf '%s\tfail\t1m\thttps://x\n' "no checks reported on the 'feature' branch"
        exit 1
        ;;
      # #1523: check NAME contains the full CLI message; exit 0 → normal green
      full_msg_name_green)
        printf '%s\tpass\t1m\thttps://x\n' "no checks reported on the 'feature' branch"
        exit 0
        ;;
      # Multi-line list that starts with the message prefix and ends with
      # "' branch" (the last check's description), with a failure between.
      multiline_wrap)
        printf "no checks reported on the 'x\tpass\t1m\thttps://x\t\n"
        printf 'CodeQL\tfail\t1m\thttps://x\t\n'
        printf "deploy\tpass\t1m\thttps://x\tpreview for ' branch\n"
        exit 1
        ;;
      *)     exit 0 ;;
    esac
    ;;
  *"actions/workflows"*)
    case "$nocheck_mode" in
      no_ci) echo '{"total_count":0,"workflows":[]}' ;;
      gated|filtered|runs_fail|runs_non_number)
        echo '{"total_count":1,"workflows":[{"state":"active"}]}' ;;
      workflows_missing_field) echo '{"total_count":0}' ;;
      *)              exit 1 ;;
    esac
    ;;
  *"actions/runs"*)
    # The exact head filter is part of the contract. An unfiltered query
    # fails here, so the failure-run cases cannot pass without that filter.
    case "\$2" in
      "repos/$TEST_REPO/actions/runs?head_sha=$TEST_SHA&per_page=100") ;;
      *) exit 1 ;;
    esac
    case "$nocheck_mode" in
      gated|action_required|workflow_fail_gated) echo '{"total_count":1,"workflow_runs":[{"workflow_id":1,"run_number":1,"created_at":"2026-10-01T00:00:00Z","id":101,"name":"Build PR","status":"completed","conclusion":"action_required"}]}' ;;
      queued) echo '{"total_count":1,"workflow_runs":[{"workflow_id":1,"run_number":1,"created_at":"2026-10-01T00:00:00Z","id":101,"name":"Build PR","status":"queued","conclusion":null}]}' ;;
      in_progress) echo '{"total_count":1,"workflow_runs":[{"workflow_id":1,"run_number":1,"created_at":"2026-10-01T00:00:00Z","id":101,"name":"Build PR","status":"in_progress","conclusion":null}]}' ;;
      startup_failure) echo '{"total_count":1,"workflow_runs":[{"workflow_id":1,"run_number":1,"created_at":"2026-10-01T00:00:00Z","id":101,"name":"Build PR","status":"completed","conclusion":"startup_failure"}]}' ;;
      failure) echo '{"total_count":1,"workflow_runs":[{"workflow_id":1,"run_number":1,"created_at":"2026-10-01T00:00:00Z","id":101,"name":"Build PR","status":"completed","conclusion":"failure"}]}' ;;
      null_name_failure) echo '{"total_count":1,"workflow_runs":[{"workflow_id":1,"run_number":1,"created_at":"2026-10-01T00:00:00Z","id":101,"name":null,"status":"completed","conclusion":"failure"}]}' ;;
      cancelled) echo '{"total_count":1,"workflow_runs":[{"workflow_id":1,"run_number":1,"created_at":"2026-10-01T00:00:00Z","id":101,"name":"Build PR","status":"completed","conclusion":"cancelled"}]}' ;;
      good_runs) echo '{"total_count":3,"workflow_runs":[{"workflow_id":1,"run_number":1,"created_at":"2026-10-01T00:00:00Z","id":101,"name":"Build","status":"completed","conclusion":"success"},{"workflow_id":2,"run_number":1,"created_at":"2026-10-01T00:00:00Z","id":102,"name":"Docs","status":"completed","conclusion":"neutral"},{"workflow_id":3,"run_number":1,"created_at":"2026-10-01T00:00:00Z","id":103,"name":"Optional","status":"completed","conclusion":"skipped"}]}' ;;
      old_failure_new_success) echo '{"total_count":2,"workflow_runs":[{"workflow_id":1,"run_number":1,"created_at":"2026-10-01T00:00:00Z","id":101,"name":"Build PR","status":"completed","conclusion":"failure"},{"workflow_id":1,"run_number":2,"created_at":"2026-10-02T00:00:00Z","id":102,"name":"Build PR","status":"completed","conclusion":"success"}]}' ;;
      old_success_new_failure) echo '{"total_count":2,"workflow_runs":[{"workflow_id":1,"run_number":1,"created_at":"2026-10-01T00:00:00Z","id":101,"name":"Build PR","status":"completed","conclusion":"success"},{"workflow_id":1,"run_number":2,"created_at":"2026-10-02T00:00:00Z","id":102,"name":"Build PR","status":"completed","conclusion":"failure"}]}' ;;
      old_cancelled_new_success) echo '{"total_count":2,"workflow_runs":[{"workflow_id":1,"run_number":1,"created_at":"2026-10-01T00:00:00Z","id":101,"name":"Build PR","status":"completed","conclusion":"cancelled"},{"workflow_id":1,"run_number":2,"created_at":"2026-10-02T00:00:00Z","id":102,"name":"Build PR","status":"completed","conclusion":"success"}]}' ;;
      tied_number_newer_created) echo '{"total_count":2,"workflow_runs":[{"workflow_id":1,"run_number":2,"created_at":"2026-10-01T00:00:00Z","id":102,"name":"Build PR","status":"completed","conclusion":"failure"},{"workflow_id":1,"run_number":2,"created_at":"2026-10-02T00:00:00Z","id":101,"name":"Build PR","status":"completed","conclusion":"success"}]}' ;;
      tied_number_created_higher_id) echo '{"total_count":2,"workflow_runs":[{"workflow_id":1,"run_number":2,"created_at":"2026-10-02T00:00:00Z","id":101,"name":"Build PR","status":"completed","conclusion":"failure"},{"workflow_id":1,"run_number":2,"created_at":"2026-10-02T00:00:00Z","id":102,"name":"Build PR","status":"completed","conclusion":"success"}]}' ;;
      different_workflows_one_failed) echo '{"total_count":2,"workflow_runs":[{"workflow_id":1,"run_number":2,"created_at":"2026-10-02T00:00:00Z","id":102,"name":"Build PR","status":"completed","conclusion":"success"},{"workflow_id":2,"run_number":1,"created_at":"2026-10-01T00:00:00Z","id":201,"name":"Docs","status":"completed","conclusion":"failure"}]}' ;;
      missing_workflow_id) echo '{"total_count":1,"workflow_runs":[{"run_number":1,"created_at":"2026-10-01T00:00:00Z","id":101,"name":"Build PR","status":"completed","conclusion":"success"}]}' ;;
      missing_run_number) echo '{"total_count":1,"workflow_runs":[{"workflow_id":1,"created_at":"2026-10-01T00:00:00Z","id":101,"name":"Build PR","status":"completed","conclusion":"success"}]}' ;;
      missing_conclusion) echo '{"total_count":1,"workflow_runs":[{"workflow_id":1,"run_number":1,"created_at":"2026-10-01T00:00:00Z","id":101,"name":"Build PR","status":"completed"}]}' ;;
      runs_fail) echo 'API rate limit' >&2; exit 1 ;;
      runs_non_number) echo '{"total_count":"unknown","workflow_runs":[]}' ;;
      runs_non_json) echo '<html>rate limit</html>' ;;
      runs_missing_field) echo '{"total_count":0}' ;;
      partial_page) echo '{"total_count":101,"workflow_runs":[{"workflow_id":1,"run_number":1,"created_at":"2026-10-01T00:00:00Z","id":101,"name":"Build","status":"completed","conclusion":"success"}]}' ;;
      *) echo '{"total_count":0,"workflow_runs":[]}' ;;
    esac
    ;;
  *"pr view"*)
    if [[ " \$* " == *" --json number "* ]]; then echo "77"; exit 0; fi
    case "$nocheck_mode" in
      bad_sha) echo "deadbeef" ;;
      *)       echo "$TEST_SHA" ;;
    esac
    ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$sb/bin/gh"

  cat > "$sb/bin/glab" <<EOF
#!/bin/bash
case "\$*" in
  *"mr view"*)
    case "$glab_mode" in
      success)      echo '{"iid":1,"head_pipeline":{"status":"success"}}' ;;
      pending)      echo '{"iid":1,"head_pipeline":{"status":"running"}}' ;;
      failure)      echo '{"iid":1,"head_pipeline":{"status":"failed"}}' ;;
      none)         echo '{"iid":1,"head_pipeline":null}' ;;
      unresolvable) exit 1 ;;
      # --- fail-open regression cases (#793) ---
      # glab exits non-zero but still prints something on stdout (a
      # content-only emptiness check would miss this; the exit code
      # must be honored).
      nonzero_exit) echo '{"iid":1,"head_pipeline":{"status":"success"}}'; exit 1 ;;
      # GitLab REST error envelopes — valid JSON, exit 0, but NOT an MR
      # object (no .iid). Previously mapped to "none" -> ALLOW.
      auth_error)   echo '{"message":"401 Unauthorized"}' ;;
      # An intermediary (proxy / captive portal / SSO gateway) returning
      # an HTML error page on stdout instead of JSON.
      http_error)   echo '<html><body>502 Bad Gateway</body></html>' ;;
      # Truncated/partial JSON body.
      truncated)    echo '{"head_pipeline":' ;;
      # A bare JSON scalar (not an object).
      scalar)       echo '"unexpected"' ;;
      # A JSON array (not an object).
      array)        echo '[1,2,3]' ;;
      *)            exit 0 ;;
    esac
    ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$sb/bin/glab"

  echo "$sb"
}

run_case() {
  local label="$1" want_rc="$2" want_stderr_regex="$3" sb="$4" cmd="$5"
  local reject_stderr_regex="${6:-}" want_no_api="${7:-0}" want_runs_calls="${8:-}"
  local input
  input=$(jq -nc --arg c "$cmd" '{tool_name:"Bash", tool_input:{command:$c}}')
  local got_stderr got_rc api_calls=0 runs_calls=0
  got_stderr=$(cd "$sb" && printf '%s' "$input" | APEXYARD_OPS_DISABLE_PIN=1 PATH="$sb/bin:$PATH" bash .claude/hooks/block-merge-on-red-ci.sh 2>&1 >/dev/null)
  got_rc=$?
  if [ -f "$sb/api-calls" ]; then
    api_calls=$(wc -l < "$sb/api-calls")
    runs_calls=$(grep -c 'actions/runs' "$sb/api-calls")
  fi
  rm -rf "$sb"

  if [ "$got_rc" != "$want_rc" ]; then
    echo "FAIL [$label]: want rc=$want_rc, got $got_rc (stderr: ${got_stderr:0:300})" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}${label} "; return
  fi
  if [ -n "$want_stderr_regex" ] && ! echo "$got_stderr" | grep -qE "$want_stderr_regex"; then
    echo "FAIL [$label]: stderr did not match /$want_stderr_regex/" >&2
    echo "    stderr: $got_stderr" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}${label} "; return
  fi
  if [ -n "$reject_stderr_regex" ] && echo "$got_stderr" | grep -qE "$reject_stderr_regex"; then
    echo "FAIL [$label]: stderr unexpectedly matched /$reject_stderr_regex/" >&2
    echo "    stderr: $got_stderr" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}${label} "; return
  fi
  if [ "$want_no_api" = "1" ] && [ "$api_calls" -ne 0 ]; then
    echo "FAIL [$label]: expected no gh api calls, got $api_calls" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}${label} "; return
  fi
  if [ -n "$want_runs_calls" ] && [ "$runs_calls" -ne "$want_runs_calls" ]; then
    echo "FAIL [$label]: expected $want_runs_calls runs query, got $runs_calls" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}${label} "; return
  fi
  echo "PASS [$label]"
  PASS=$((PASS+1))
}

# B1: the current branch PR has green checks, but argv targets PR 5 or a
# runtime value. Neither may inherit the branch PR's green result.
for argv_target in "'5'" "os.environ['PR']"; do
  sb=$(make_sandbox green "")
  run_case "argv merge target $argv_target does not use green branch PR" 2 \
    "cannot verify CI" "$sb" \
    "python3 -c \"import subprocess, os; subprocess.run(['gh','pr','merge',$argv_target])\""
done

# ======================================================================
# GH PATH — regression (must stay byte-identical to pre-#790 behaviour)
# ======================================================================

sb=$(make_sandbox green "")
run_case "gh: green CI -> allows" 0 "" "$sb" \
  "gh pr merge 300 --repo $TEST_REPO --squash"

sb=$(make_sandbox red "")
run_case "gh: red CI -> blocks" 2 "red CI" "$sb" \
  "gh pr merge 301 --repo $TEST_REPO --squash"

sb=$(make_sandbox none "")
run_case "gh: no checks configured -> allows (no-op note)" 0 "" "$sb" \
  "gh pr merge 302 --repo $TEST_REPO --squash"

# --- #1519: "no checks reported" covers several states, only one safe ------
# gh prints the identical line whether the repo has no CI or a fork PR's
# workflow is waiting at the approval gate. The gate used to allow both and
# tell the operator the repo had no CI, which was false for the second.

# THE REGRESSION: CI is configured and gated. Must block.
sb=$(make_sandbox none "" gated)
run_case "#1519: gated fork-PR workflow -> BLOCKS" 2 "workflow runs that have not passed" "$sb" \
  "gh pr merge 310 --repo $TEST_REPO --squash"
sb=$(make_sandbox none "" gated)
run_case "#1519: gated -> names the approval gate" 2 "Approve runs at action_required" "$sb" \
  "gh pr merge 310 --repo $TEST_REPO --squash"
sb=$(make_sandbox none "" gated)
run_case "#1519: gated -> does not claim the repo has no CI" 2 "Build PR.*action_required" "$sb" \
  "gh pr merge 310 --repo $TEST_REPO --squash" "no CI checks configured"

# A repo with genuinely no CI keeps the original allow, unchanged.
sb=$(make_sandbox none "" no_ci)
run_case "#1519: zero workflows -> still allows" 0 "has no CI checks configured" "$sb" \
  "gh pr merge 311 --repo $TEST_REPO --squash"

# Workflows exist but none ran for this head — path or branch filters make
# that legitimate, so it allows; the note must not claim there is no CI.
sb=$(make_sandbox none "" filtered)
run_case "#1519: workflows exist, none matched -> allows" 0 "no run matched this head" "$sb" \
  "gh pr merge 312 --repo $TEST_REPO --squash"

# The API calls failing must not invent a refusal: fall back to the old allow.
sb=$(make_sandbox none "" unknown)
run_case "#1519: API unresolvable -> allows with honest note" 0 "CI state could not be checked" "$sb" \
  "gh pr merge 313 --repo $TEST_REPO --squash" "no CI checks configured"

sb=$(make_sandbox none "" workflows_missing_field)
run_case "#1536 A3: missing workflow field -> honest note" 0 "CI state could not be checked.*Actions API unavailable" "$sb" \
  "gh pr merge 314 --repo $TEST_REPO --squash" "no CI checks configured"

sb=$(make_sandbox none "" workflow_fail_gated)
run_case "#1536: gated run still blocks if workflow inventory fails" 2 "Build PR.*action_required" "$sb" \
  "gh pr merge 315 --repo $TEST_REPO --squash"

# #1536: the head run state must be checked even when other PR checks pass.
# The runs stub answers only the exact head-filtered URL above. In particular,
# the first case fails if the hook omits head_sha or queries only no-checks.
for run_state in action_required queued in_progress startup_failure failure cancelled; do
  sb=$(make_sandbox green "" "$run_state")
  run_case "#1536: green checks + $run_state head run -> blocks" 2 "Build PR.*$run_state" "$sb" \
    "gh pr merge 1536 --repo $TEST_REPO --squash"
done

sb=$(make_sandbox green "" action_required)
run_case "#1536 N2: exact head-filtered runs URL is required" 2 "Build PR.*action_required" "$sb" \
  "gh pr merge 1537 --repo $TEST_REPO --squash" "" 0 1

sb=$(make_sandbox green "" good_runs)
run_case "#1536: success, neutral, skipped runs -> allows" 0 "" "$sb" \
  "gh pr merge 1536 --repo $TEST_REPO --squash"

sb=$(make_sandbox green "" null_name_failure)
run_case "#1536: failed run with null name -> blocks with workflow ID" 2 "workflow 1.*failure" "$sb" \
  "gh pr merge 1536 --repo $TEST_REPO --squash"

# A workflow can run again on the same head after a PR edit. Only its latest
# run decides the gate; a separate workflow still has its own latest run.
sb=$(make_sandbox green "" old_failure_new_success)
run_case "#1536: older failed + newer successful same workflow -> allows" 0 "" "$sb" \
  "gh pr merge 1536 --repo $TEST_REPO --squash" "Build PR.*failure"

sb=$(make_sandbox green "" old_success_new_failure)
run_case "#1536: older successful + newer failed same workflow -> blocks" 2 "Build PR.*failure" "$sb" \
  "gh pr merge 1536 --repo $TEST_REPO --squash"

sb=$(make_sandbox green "" old_cancelled_new_success)
run_case "#1536: older cancelled + newer successful same workflow -> allows" 0 "" "$sb" \
  "gh pr merge 1536 --repo $TEST_REPO --squash" "Build PR.*cancelled"

sb=$(make_sandbox green "" tied_number_newer_created)
run_case "#1536: equal run number uses newer created_at -> allows" 0 "" "$sb" \
  "gh pr merge 1536 --repo $TEST_REPO --squash" "Build PR.*failure"

sb=$(make_sandbox green "" tied_number_created_higher_id)
run_case "#1536: equal run number and created_at uses higher id -> allows" 0 "" "$sb" \
  "gh pr merge 1536 --repo $TEST_REPO --squash" "Build PR.*failure"

sb=$(make_sandbox green "" different_workflows_one_failed)
run_case "#1536: different workflow latest failure -> blocks" 2 "Docs.*failure" "$sb" \
  "gh pr merge 1536 --repo $TEST_REPO --squash"

for missing_field in missing_workflow_id missing_run_number missing_conclusion; do
  sb=$(make_sandbox green "" "$missing_field")
  run_case "#1536: $missing_field -> honest note" 0 "CI state could not be checked.*Actions API unavailable" "$sb" \
    "gh pr merge 1536 --repo $TEST_REPO --squash" "no CI checks configured"
done

sb=$(make_sandbox none "" no_ci)
run_case "#1536: no runs and no checks -> allows as no CI" 0 "has no CI checks configured" "$sb" \
  "gh pr merge 1536 --repo $TEST_REPO --squash"

sb=$(make_sandbox green "" runs_fail)
run_case "#1536: runs API failure -> allows with honest note" 0 "CI state could not be checked.*Actions API unavailable" "$sb" \
  "gh pr merge 1536 --repo $TEST_REPO --squash" "no CI checks configured"

# An Actions fault cannot override red or pending PR checks. These cases
# catch an unconditional exit 0 in the RUNS_ERROR branch.
sb=$(make_sandbox red "" runs_fail)
run_case "#1536: red checks + runs API failure -> blocks" 2 "red CI" "$sb" \
  "gh pr merge 1536 --repo $TEST_REPO --squash"

sb=$(make_sandbox pending "" runs_fail)
run_case "#1536: pending checks + runs API failure -> blocks" 2 "pending checks" "$sb" \
  "gh pr merge 1536 --repo $TEST_REPO --squash"

sb=$(make_sandbox pending "" good_runs)
run_case "#1536: pending checks + green head runs -> blocks" 2 "pending checks" "$sb" \
  "gh pr merge 1536 --repo $TEST_REPO --squash"

sb=$(make_sandbox none "" runs_fail)
run_case "#1536 N1: workflows succeed, runs fail -> honest note" 0 "CI state could not be checked.*Actions API unavailable" "$sb" \
  "gh pr merge 1536 --repo $TEST_REPO --squash" "no run matched this head|no CI checks configured"

sb=$(make_sandbox none "" runs_non_number)
run_case "#1536 N1: runs count non-number -> honest note" 0 "CI state could not be checked.*Actions API unavailable" "$sb" \
  "gh pr merge 1536 --repo $TEST_REPO --squash" "no run matched this head|no CI checks configured"

sb=$(make_sandbox green "" runs_non_json)
run_case "#1536 A3: non-JSON runs response -> honest note" 0 "CI state could not be checked.*Actions API unavailable" "$sb" \
  "gh pr merge 1536 --repo $TEST_REPO --squash" "no CI checks configured"

sb=$(make_sandbox green "" runs_missing_field)
run_case "#1536 A3: missing runs field -> honest note" 0 "CI state could not be checked.*Actions API unavailable" "$sb" \
  "gh pr merge 1536 --repo $TEST_REPO --squash" "no CI checks configured"

sb=$(make_sandbox green "" partial_page)
run_case "#1536: partial runs page cannot prove all passed -> blocks" 2 "101 head workflow runs.*returned only 1" "$sb" \
  "gh pr merge 1536 --repo $TEST_REPO --squash"

sb=$(make_sandbox green "" action_required)
run_case "#1536 N3: invalid repo -> blocks before API path" 2 "invalid.*owner/repo" "$sb" \
  "gh pr merge 1536 --repo bad/repo/extra --squash" "" 1

sb=$(make_sandbox green "" bad_sha)
run_case "#1536: invalid head SHA -> blocks" 2 "invalid.*head SHA" "$sb" \
  "gh pr merge 1536 --repo $TEST_REPO --squash" "" 1
# ----------------------------------------------------------------------
# #1523: "no checks reported" must match the whole CLI message + non-zero
# exit — a substring in a check NAME must not open the no-checks allow arm.
# ----------------------------------------------------------------------

sb=$(make_sandbox red_named_phrase "")
run_case "#1523: failing check + passing check named 'no checks reported' -> blocks" 2 "red CI" "$sb" \
  "gh pr merge 1531 --repo $TEST_REPO --squash"

sb=$(make_sandbox full_msg_name_red "")
run_case "#1523: check name is full CLI no-checks message, exit 1 -> blocks (normal eval)" 2 "red CI" "$sb" \
  "gh pr merge 1532 --repo $TEST_REPO --squash"

sb=$(make_sandbox full_msg_name_green "")
run_case "#1523: check name contains full CLI no-checks message, exit 0 -> allows (normal green)" 0 "" "$sb" \
  "gh pr merge 1533 --repo $TEST_REPO --squash"

sb=$(make_sandbox none "")
run_case "#1523: real no-checks message + non-zero exit -> allows (no-op)" 0 "" "$sb" \
  "gh pr merge 1534 --repo $TEST_REPO --squash"

sb=$(make_sandbox multiline_wrap "")
run_case "#1523: multi-line list wrapped in the no-checks text, with a failure -> blocks" 2 "red CI" "$sb" \
  "gh pr merge 1536 --repo $TEST_REPO --squash"

# Exact message + exit 0 must NOT take the no-checks arm (no NOTE).
sb=$(make_sandbox none_exit0 "")
label="#1523: real no-checks message text but exit 0 -> not treated as no-checks"
input=$(jq -nc --arg c "gh pr merge 1535 --repo $TEST_REPO --squash" '{tool_name:"Bash", tool_input:{command:$c}}')
got_stderr=$(cd "$sb" && APEXYARD_OPS_DISABLE_PIN=1 PATH="$sb/bin:$PATH" bash -c "echo '$input' | bash .claude/hooks/block-merge-on-red-ci.sh" 2>&1 >/dev/null)
got_rc=$?
rm -rf "$sb"
if [ "$got_rc" != "0" ]; then
  echo "FAIL [$label]: want rc=0, got $got_rc (stderr: ${got_stderr:0:300})" >&2
  FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}${label} "
elif echo "$got_stderr" | grep -q "no CI checks configured"; then
  echo "FAIL [$label]: treated as no-checks (NOTE present) despite exit 0" >&2
  echo "    stderr: $got_stderr" >&2
  FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}${label} "
else
  echo "PASS [$label]"
  PASS=$((PASS+1))
fi

sb=$(make_sandbox red "")
run_case "gh: variable-substituted merge -> blocks" 2 "variable-substituted" "$sb" \
  'gh pr merge $PR --repo me2resh/apexyard --squash'

sb=$(make_sandbox red "")
run_case "gh: non-merge command -> no-op" 0 "" "$sb" \
  "gh pr view 303 --repo $TEST_REPO"

sb=$(make_sandbox red "")
run_case "gh: gh-api merge shape, red CI -> blocks" 2 "red CI" "$sb" \
  "gh api repos/me2resh/apexyard/pulls/304/merge -X PUT"

# ======================================================================
# GLAB PATH — new (#790)
# ======================================================================

sb=$(make_sandbox "" success)
run_case "glab: pipeline success -> allows" 0 "" "$sb" \
  "glab mr merge 400 -R $TEST_REPO --squash"

sb=$(make_sandbox "" pending)
run_case "glab: pipeline pending -> blocks" 2 "red or unresolvable" "$sb" \
  "glab mr merge 401 -R $TEST_REPO --squash"

sb=$(make_sandbox "" failure)
run_case "glab: pipeline failed -> blocks" 2 "red or unresolvable" "$sb" \
  "glab mr merge 402 -R $TEST_REPO --squash"

sb=$(make_sandbox "" none)
run_case "glab: no pipeline configured -> allows (no-op note)" 0 "" "$sb" \
  "glab mr merge 403 -R $TEST_REPO --squash"

# Fail-closed: glab CLI failure / unparseable response -> BLOCK, never allow.
sb=$(make_sandbox "" unresolvable)
run_case "glab: unresolvable status -> blocks (fail closed)" 2 "unresolvable" "$sb" \
  "glab mr merge 404 -R $TEST_REPO --squash"

# ----------------------------------------------------------------------
# Fail-OPEN regression suite (#793 / Hakim HIGH finding): a non-empty
# glab response that ISN'T a valid MR object must still BLOCK, not fall
# through to the "none" allow-arm. The pre-fix implementation only
# checked stdout emptiness, so every case below used to resolve to
# "none" -> exit 0 (ALLOW) despite being an error/garbage response.
# ----------------------------------------------------------------------

sb=$(make_sandbox "" nonzero_exit)
run_case "glab: non-zero exit (even with stdout output) -> blocks (fail closed)" 2 "unresolvable" "$sb" \
  "glab mr merge 408 -R $TEST_REPO --squash"

sb=$(make_sandbox "" auth_error)
run_case "glab: JSON auth-error envelope (401) -> blocks (fail closed)" 2 "unresolvable" "$sb" \
  "glab mr merge 409 -R $TEST_REPO --squash"

sb=$(make_sandbox "" http_error)
run_case "glab: HTML error page on stdout -> blocks (fail closed)" 2 "unresolvable" "$sb" \
  "glab mr merge 410 -R $TEST_REPO --squash"

sb=$(make_sandbox "" truncated)
run_case "glab: truncated/garbage JSON -> blocks (fail closed)" 2 "unresolvable" "$sb" \
  "glab mr merge 411 -R $TEST_REPO --squash"

sb=$(make_sandbox "" scalar)
run_case "glab: bare JSON scalar response -> blocks (fail closed)" 2 "unresolvable" "$sb" \
  "glab mr merge 412 -R $TEST_REPO --squash"

sb=$(make_sandbox "" array)
run_case "glab: JSON array response -> blocks (fail closed)" 2 "unresolvable" "$sb" \
  "glab mr merge 413 -R $TEST_REPO --squash"

sb=$(make_sandbox "" pending)
run_case "glab: variable-substituted merge -> blocks" 2 "variable-substituted" "$sb" \
  'glab mr merge $MR -R me2resh/apexyard --squash'

sb=$(make_sandbox "" pending)
run_case "glab: non-merge command -> no-op" 0 "" "$sb" \
  "glab mr view 405 -R $TEST_REPO"

sb=$(make_sandbox "" success)
run_case "glab: raw-API merge shape, pipeline success -> allows" 0 "" "$sb" \
  "glab api projects/me6resh%2Fapexyard/merge_requests/406/merge -X PUT"

sb=$(make_sandbox "" failure)
run_case "glab: raw-API merge shape, pipeline failed -> blocks" 2 "red or unresolvable" "$sb" \
  "glab api projects/me6resh%2Fapexyard/merge_requests/407/merge -X PUT"

# ======================================================================
# tracker_pr_merge WRAPPER SHAPE (#759 gate-coverage regression) — the
# wrapper's own text never says "gh" or "glab" (that's the whole point of
# the abstraction), so this hook's forge dispatch cannot rely on
# `_forge_from_command` (text-based) for the wrapper the way it does for an
# explicit `gh pr merge` / `glab mr merge` command — it must consult the
# REGISTRY (`tracker_kind` / `_forge_kind_for`) instead. This needs its own
# sandbox because it's the one case that requires `_lib-tracker.sh` +
# a real `apexyard.projects.yaml` registry entry, which the other cases
# above don't need (they dispatch on command text alone).
# ======================================================================

TRACKER_LIB="$SRC_ROOT/.claude/hooks/_lib-tracker.sh"
CONFIG_LIB="$SRC_ROOT/.claude/hooks/_lib-read-config.sh"
PORTFOLIO_LIB="$SRC_ROOT/.claude/hooks/_lib-portfolio-paths.sh"
OPSROOT_LIB="$SRC_ROOT/.claude/hooks/_lib-ops-root.sh"

# make_sandbox_wrapper <glab_mode> — a registered glab-kind project so
# `tracker_kind "g/p"` (and therefore `_forge_kind_for`) resolves to glab from
# the REGISTRY, not the command text.
make_sandbox_wrapper() {
  local glab_mode="$1"
  local sb
  sb=$(mktemp -d)
  mkdir -p "$sb/.claude/hooks" "$sb/bin"
  cp "$HOOK_SRC"      "$sb/.claude/hooks/block-merge-on-red-ci.sh"
  cp "$LIB_PR"        "$sb/.claude/hooks/_lib-extract-pr.sh"
  cp "$TRACKER_LIB"   "$sb/.claude/hooks/_lib-tracker.sh"
  cp "$CONFIG_LIB"    "$sb/.claude/hooks/_lib-read-config.sh"
  cp "$PORTFOLIO_LIB" "$sb/.claude/hooks/_lib-portfolio-paths.sh"
  [ -f "$OPSROOT_LIB" ] && cp "$OPSROOT_LIB" "$sb/.claude/hooks/_lib-ops-root.sh"
  chmod +x "$sb/.claude/hooks/block-merge-on-red-ci.sh"
  touch "$sb/onboarding.yaml"
  cat > "$sb/.claude/project-config.defaults.json" <<'JSON'
{ "tracker": { "kind": "gh" } }
JSON
  cat > "$sb/apexyard.projects.yaml" <<'YAML'
version: 1
projects:
  - name: gl
    repo: g/p
    tracker:
      kind: glab
YAML
  cat > "$sb/bin/glab" <<EOF
#!/bin/bash
case "\$*" in
  *"mr view"*)
    case "$glab_mode" in
      success) echo '{"iid":1,"head_pipeline":{"status":"success"}}' ;;
      failure) echo '{"iid":1,"head_pipeline":{"status":"failed"}}' ;;
      *)       exit 1 ;;
    esac
    ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$sb/bin/glab"
  # gh must NOT be consulted for a glab-registered project's wrapper call —
  # make it fail loudly (nonzero + wrong-looking text) if it ever is.
  cat > "$sb/bin/gh" <<'EOF'
#!/bin/bash
echo "WRONG: gh should not be called for a glab-registered project" >&2
exit 1
EOF
  chmod +x "$sb/bin/gh"
  echo "$sb"
}

WRAPPER_CMD_TMPL='. "%s/.claude/hooks/_lib-tracker.sh"
MERGE_RESULT=$(tracker_pr_merge "g/p" "500" "squash" true)'

sb=$(make_sandbox_wrapper success)
run_case "wrapper: glab-registered project, pipeline success -> allows (forge dispatched via registry, not command text)" 0 "" "$sb" \
  "$(printf "$WRAPPER_CMD_TMPL" "$sb")"

sb=$(make_sandbox_wrapper failure)
run_case "wrapper: glab-registered project, pipeline failed -> blocks (forge dispatched via registry, not command text)" 2 "red or unresolvable" "$sb" \
  "$(printf "$WRAPPER_CMD_TMPL" "$sb")"

# ----------------------------------------------------------------------
# #1121: the registry read inside _forge_kind_for (_lib-tracker.sh's
# _tracker_project_value) needs `yq` OR `python3`+PyYAML to parse the
# per-project override; when NEITHER is available it silently falls through
# to the GLOBAL tracker.kind default ("gh") — wrong for a glab-registered
# project's wrapper call. The two cases above only caught this by accident
# of THIS environment happening to lack yq/PyYAML; make it deterministic by
# stubbing yq/python3 to behave exactly like "no override found here"
# regardless of what the host actually has installed, so this regression
# can't silently stop being exercised if the CI image ever gains yq.
# ----------------------------------------------------------------------

# make_sandbox_wrapper_no_yaml_tools <glab_mode> — same registry/glab stub as
# make_sandbox_wrapper, PLUS yq/python3 stubs that always fail to produce a
# per-project override (matching real yq-absent / PyYAML-absent behaviour),
# forcing block-merge-on-red-ci.sh's registry fallback (_registry_glab_fallback)
# to be the thing that resolves the forge correctly.
make_sandbox_wrapper_no_yaml_tools() {
  local glab_mode="$1"
  local sb
  sb=$(make_sandbox_wrapper "$glab_mode")
  cat > "$sb/bin/yq" <<'EOF'
#!/bin/bash
# Simulates yq being unusable for this lookup (matches "yq not installed"
# from the caller's perspective: no stdout, non-zero exit).
exit 1
EOF
  chmod +x "$sb/bin/yq"
  cat > "$sb/bin/python3" <<'EOF'
#!/bin/bash
# Simulates python3 without PyYAML installed. The real
# _tracker_project_value heredoc catches the ImportError and exits 0 with
# no stdout; this stub reproduces that exact observable behaviour.
exit 0
EOF
  chmod +x "$sb/bin/python3"
  echo "$sb"
}

sb=$(make_sandbox_wrapper_no_yaml_tools success)
run_case "#1121: wrapper, glab-registered project, NO yq/PyYAML -> still allows on green pipeline (registry fallback engages)" 0 "" "$sb" \
  "$(printf "$WRAPPER_CMD_TMPL" "$sb")"

sb=$(make_sandbox_wrapper_no_yaml_tools failure)
run_case "#1121: wrapper, glab-registered project, NO yq/PyYAML -> still blocks on red pipeline (registry fallback engages)" 2 "red or unresolvable" "$sb" \
  "$(printf "$WRAPPER_CMD_TMPL" "$sb")"

# make_sandbox_wrapper_gh_no_yaml_tools <gh_mode> — a GENUINELY gh-kind
# project (no tracker: override at all — relies on the global default),
# with yq/python3 stubbed the same unusable way. Proves the #1121 fallback
# never produces a FALSE positive: it must not flip a real gh-kind project
# to glab just because the registry lookup came back empty for other
# reasons. `glab` fails loudly if ever invoked, mirroring the existing
# "gh must NOT be consulted" pattern in reverse.
make_sandbox_wrapper_gh_no_yaml_tools() {
  local gh_mode="$1"
  local sb
  sb=$(mktemp -d)
  mkdir -p "$sb/.claude/hooks" "$sb/bin"
  cp "$HOOK_SRC"      "$sb/.claude/hooks/block-merge-on-red-ci.sh"
  cp "$LIB_PR"        "$sb/.claude/hooks/_lib-extract-pr.sh"
  cp "$TRACKER_LIB"   "$sb/.claude/hooks/_lib-tracker.sh"
  cp "$CONFIG_LIB"    "$sb/.claude/hooks/_lib-read-config.sh"
  cp "$PORTFOLIO_LIB" "$sb/.claude/hooks/_lib-portfolio-paths.sh"
  [ -f "$OPSROOT_LIB" ] && cp "$OPSROOT_LIB" "$sb/.claude/hooks/_lib-ops-root.sh"
  chmod +x "$sb/.claude/hooks/block-merge-on-red-ci.sh"
  touch "$sb/onboarding.yaml"
  cat > "$sb/.claude/project-config.defaults.json" <<'JSON'
{ "tracker": { "kind": "gh" } }
JSON
  cat > "$sb/apexyard.projects.yaml" <<'YAML'
version: 1
projects:
  - name: gh-proj
    repo: g/p2
    roles:
      - backend-engineer
      - platform-engineer
    tags:
      - customer-facing
YAML
  cat > "$sb/bin/gh" <<EOF
#!/bin/bash
case "\$*" in
  *"pr checks"*)
    case "$gh_mode" in
      green) printf 'build\tpass\t1m\thttps://x\n'; exit 0 ;;
      red)   printf 'build\tfail\t1m\thttps://x\n'; exit 1 ;;
      *)     exit 0 ;;
    esac
    ;;
  *"pr view"*) echo "$TEST_SHA" ;;
  *"repos/g/p2/actions/runs?head_sha=$TEST_SHA&per_page=100"*)
    echo '{"total_count":0,"workflow_runs":[]}' ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$sb/bin/gh"
  cat > "$sb/bin/glab" <<'EOF'
#!/bin/bash
echo "WRONG: glab should not be called for a gh-registered project" >&2
exit 1
EOF
  chmod +x "$sb/bin/glab"
  cat > "$sb/bin/yq" <<'EOF'
#!/bin/bash
exit 1
EOF
  chmod +x "$sb/bin/yq"
  cat > "$sb/bin/python3" <<'EOF'
#!/bin/bash
exit 0
EOF
  chmod +x "$sb/bin/python3"
  echo "$sb"
}

WRAPPER_CMD_TMPL2='. "%s/.claude/hooks/_lib-tracker.sh"
MERGE_RESULT=$(tracker_pr_merge "g/p2" "501" "squash" true)'

sb=$(make_sandbox_wrapper_gh_no_yaml_tools green)
run_case "#1121: wrapper, gh-kind project (no tracker override), NO yq/PyYAML -> allows on green CI (no false-positive glab)" 0 "" "$sb" \
  "$(printf "$WRAPPER_CMD_TMPL2" "$sb")"

sb=$(make_sandbox_wrapper_gh_no_yaml_tools red)
run_case "#1121: wrapper, gh-kind project (no tracker override), NO yq/PyYAML -> blocks on red CI (no false-positive glab)" 2 "red CI" "$sb" \
  "$(printf "$WRAPPER_CMD_TMPL2" "$sb")"

# ----------------------------------------------------------------------
# #1121 (position-dependence): _registry_glab_fallback's awk emitted the
# match BOTH mid-stream (`print "glab"; exit`) AND again in its END block
# (awk's `exit` runs END, and block_repo/block_kind were still set), so
# `found` became "glab\nglab" and the caller's exact `= "glab"` compare
# FAILED — a false miss whenever the glab target block was NOT the last
# registry entry. The single-project registry in make_sandbox_wrapper only
# ever exercised the "sole/last entry" shape, hiding the bug. These cases
# put a gh-kind block AFTER the glab target (g/p) so the mid-stream branch
# fires; on the buggy code the fallback misses -> forge stays gh -> the
# loud `gh` stub is (wrongly) consulted -> unresolvable -> BLOCK even on a
# green glab pipeline. On the fixed code the fallback resolves glab and the
# green pipeline ALLOWS / a red one BLOCKS, position-independently.
# ----------------------------------------------------------------------

# make_sandbox_wrapper_no_yaml_tools_glab_not_last <glab_mode> <position>
# Same yq/PyYAML-absent glab sandbox as make_sandbox_wrapper_no_yaml_tools,
# but the glab target (g/p) is NOT the last registry entry. position:
# "first"  = glab first of two (gh-kind block after it);
# "middle" = glab middle of three (gh-kind block before AND after it).
make_sandbox_wrapper_no_yaml_tools_glab_not_last() {
  local glab_mode="$1" position="$2"
  local sb
  sb=$(make_sandbox_wrapper_no_yaml_tools "$glab_mode")
  if [ "$position" = "middle" ]; then
    cat > "$sb/apexyard.projects.yaml" <<'YAML'
version: 1
projects:
  - name: gh-before
    repo: g/before
    tracker:
      kind: gh
  - name: gl
    repo: g/p
    tracker:
      kind: glab
  - name: gh-after
    repo: g/after
    tracker:
      kind: gh
YAML
  else
    cat > "$sb/apexyard.projects.yaml" <<'YAML'
version: 1
projects:
  - name: gl
    repo: g/p
    tracker:
      kind: glab
  - name: gh-after
    repo: g/after
    tracker:
      kind: gh
YAML
  fi
  echo "$sb"
}

sb=$(make_sandbox_wrapper_no_yaml_tools_glab_not_last success first)
run_case "#1121: wrapper, glab project FIRST of two, NO yq/PyYAML -> allows on green pipeline (fallback position-independent)" 0 "" "$sb" \
  "$(printf "$WRAPPER_CMD_TMPL" "$sb")"

sb=$(make_sandbox_wrapper_no_yaml_tools_glab_not_last failure first)
run_case "#1121: wrapper, glab project FIRST of two, NO yq/PyYAML -> blocks on red pipeline (fallback position-independent)" 2 "red or unresolvable" "$sb" \
  "$(printf "$WRAPPER_CMD_TMPL" "$sb")"

sb=$(make_sandbox_wrapper_no_yaml_tools_glab_not_last success middle)
run_case "#1121: wrapper, glab project MIDDLE of three, NO yq/PyYAML -> allows on green pipeline (fallback position-independent)" 0 "" "$sb" \
  "$(printf "$WRAPPER_CMD_TMPL" "$sb")"

# --- Fail-closed on jq-unavailable/unparseable input (#965) ------------
#
# Reuses make_sandbox's green gh mock, then shadows jq with a stub that
# always fails — same code path as jq being entirely missing from PATH.
make_sandbox_broken_jq() {
  local sb
  sb=$(make_sandbox green "")
  cat > "$sb/bin/jq" <<'EOF'
#!/bin/bash
# Simulates a broken/unavailable jq: always fails, no output. See #965.
exit 1
EOF
  chmod +x "$sb/bin/jq"
  echo "$sb"
}

sb=$(make_sandbox_broken_jq)
run_case "#965: jq broken, gh pr merge -> BLOCKS (fail closed, CI status unverifiable)" 2 \
  "cannot evaluate this command" "$sb" \
  "gh pr merge 302 --repo $TEST_REPO --squash"

sb=$(make_sandbox_broken_jq)
run_case "#965: jq broken, clearly non-merge command -> stays a no-op" 0 "" "$sb" \
  "npm test"

# --- Fail-closed on JSON-escaped separators in the raw-payload fallback
#     (#973, Hakim's residual finding on the #965/#969 fix) ------------
#
# Same reasoning as the sibling case in test_block_unreviewed_merge.sh: a
# merge command whose separators are JSON-escaped (a literal tab encodes
# as the two-character sequence `\t`) is not whitespace to
# is_merge_command's `\s+` class, so pre-#973 it evaded the raw-payload
# fallback scan entirely while jq was unavailable to decode it. `run_case`
# builds the payload with the real system jq (before the sandboxed
# broken-jq stub is on PATH), so a literal tab placed in the command here
# is correctly JSON-escaped in the resulting payload — exactly the shape
# the fallback has to recognise without jq's help.
sb=$(make_sandbox_broken_jq)
tab_cmd=$'gh\tpr\tmerge 306 --repo me2resh/apexyard --squash'
run_case "#973: jq broken, JSON-escaped-tab merge command -> BLOCKS (fail closed)" 2 \
  "cannot evaluate this command" "$sb" "$tab_cmd"

sb=$(make_sandbox_broken_jq)
tab_nonmerge_cmd=$'echo\tnot\ta\tmerge\tcommand\tat\tall'
run_case "#973: jq broken, JSON-escaped-tab NON-merge command -> stays a no-op" 0 "" "$sb" \
  "$tab_nonmerge_cmd"

# me2resh/apexyard#1405 second-round review, Hakim H2: a missing required
# library (_lib-extract-pr.sh) must BLOCK in DEFAULT bash, not just under
# POSIXLY_CORRECT — see block-unreviewed-merge.sh's own copy of this test
# for the full rationale.
for mode in default posix; do
  sb=$(make_sandbox green success)
  rm -f "$sb/.claude/hooks/_lib-extract-pr.sh"
  input=$(jq -nc --arg c "gh pr merge 400 --repo me2resh/apexyard --squash" '{tool_name:"Bash", tool_input:{command:$c}}')
  if [ "$mode" = "posix" ]; then
    got_stderr=$(cd "$sb" && APEXYARD_OPS_DISABLE_PIN=1 PATH="$sb/bin:$PATH" bash -c \
      "echo '$input' | POSIXLY_CORRECT=1 bash .claude/hooks/block-merge-on-red-ci.sh" 2>&1 >/dev/null)
  else
    got_stderr=$(cd "$sb" && APEXYARD_OPS_DISABLE_PIN=1 PATH="$sb/bin:$PATH" bash -c \
      "echo '$input' | bash .claude/hooks/block-merge-on-red-ci.sh" 2>&1 >/dev/null)
  fi
  got_rc=$?
  rm -rf "$sb"
  label="missing-_lib-extract-pr.sh-blocks-in-$mode-bash"
  if [ "$got_rc" = "2" ] && echo "$got_stderr" | grep -qi "BLOCKED"; then
    echo "PASS [$label]"; PASS=$((PASS+1))
  else
    echo "FAIL [$label]: want rc=2 + BLOCKED, got rc=$got_rc stderr=${got_stderr:0:300}" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}${label} "
  fi
done

echo ""
echo "=== test_block_merge_on_red_ci: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
  echo "Failed cases: $FAILED_CASES" >&2
  exit 1
fi
exit 0
