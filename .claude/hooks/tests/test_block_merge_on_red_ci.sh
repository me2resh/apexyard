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
HOOK_SRC="$SRC_ROOT/.claude/hooks/block-merge-on-red-ci.sh"
LIB_PR="$SRC_ROOT/.claude/hooks/_lib-extract-pr.sh"

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

# make_sandbox <gh_mode> <glab_mode>
#   gh_mode:   green | red | none | ""  (mock `gh pr checks` behaviour)
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
make_sandbox() {
  local gh_mode="$1" glab_mode="$2"
  local sb
  sb=$(mktemp -d)
  mkdir -p "$sb/.claude/hooks" "$sb/bin"
  cp "$HOOK_SRC" "$sb/.claude/hooks/block-merge-on-red-ci.sh"
  cp "$LIB_PR"   "$sb/.claude/hooks/_lib-extract-pr.sh"
  chmod +x "$sb/.claude/hooks/block-merge-on-red-ci.sh"

  cat > "$sb/bin/gh" <<EOF
#!/bin/bash
case "\$*" in
  *"pr checks"*)
    case "$gh_mode" in
      green) printf 'build\tpass\t1m\thttps://x\n'; exit 0 ;;
      red)   printf 'build\tfail\t1m\thttps://x\n'; exit 1 ;;
      none)  echo "no checks reported on the 'feature' branch"; exit 8 ;;
      *)     exit 0 ;;
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
  local input
  input=$(jq -nc --arg c "$cmd" '{tool_name:"Bash", tool_input:{command:$c}}')
  local got_stderr got_rc
  got_stderr=$(cd "$sb" && APEXYARD_OPS_DISABLE_PIN=1 PATH="$sb/bin:$PATH" bash -c "echo '$input' | bash .claude/hooks/block-merge-on-red-ci.sh" 2>&1 >/dev/null)
  got_rc=$?
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
  echo "PASS [$label]"
  PASS=$((PASS+1))
}

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

echo ""
echo "=== test_block_merge_on_red_ci: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
  echo "Failed cases: $FAILED_CASES" >&2
  exit 1
fi
exit 0
