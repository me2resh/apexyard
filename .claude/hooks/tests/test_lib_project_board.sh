#!/bin/bash
# Tests for .claude/hooks/_lib-project-board.sh (me2resh/apexyard#725)
#
# Covers:
#   1. opt-in off (enable_auto_moves=false/absent) → silent no-op, gh never called
#   2. config parse + status-key→option mapping → happy path, gh project item-edit called
#   3. graceful degrade: missing project (project list returns empty)
#   4. graceful degrade: missing status field on the board
#   5. graceful degrade: item not found on the board
#   6. graceful degrade: gh project item-edit fails
#   7. graceful degrade: owner not configured → warn, exit 0
#   8. unknown status_key → warn, exit 0
#
# Isolation: each case runs in a subshell with its own sandbox dir and a
# custom `gh` shim installed on PATH. The _CONFIG_CACHE global is reset per
# subshell. Tests MUST NOT make real GitHub API calls.
#
# Exit 0 if all cases pass; exit 1 on failure.

set -u

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not installed; _lib-project-board.sh requires jq" >&2
  exit 0
fi

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
LIB="$SRC_ROOT/.claude/hooks/_lib-project-board.sh"

if [ ! -f "$LIB" ]; then
  echo "FAIL: lib not found at $LIB" >&2
  exit 1
fi

PASS=0
FAIL=0
FAILED_CASES=""

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

pass_case() { echo "  PASS [$1]"; PASS=$((PASS + 1)); }
fail_case() { echo "  FAIL [$1]: $2" >&2; FAIL=$((FAIL + 1)); FAILED_CASES="${FAILED_CASES}${1} "; }

# make_sandbox: create a temp dir, write the fork anchor (.apexyard-fork) and
# a defaults.json with enable_auto_moves enabled by default (callers override).
# Prints the sandbox path.
make_sandbox() {
  local sb
  sb=$(mktemp -d)
  : > "$sb/.apexyard-fork"
  mkdir -p "$sb/.claude"

  # Write the defaults config with board automation enabled and a real board.
  cat > "$sb/.claude/project-config.defaults.json" <<'JSON'
{
  "github_projects": {
    "owner": "test-org",
    "board_number": 7,
    "enable_auto_moves": true,
    "status_field_name": "Status",
    "status_map": {
      "in_progress": "In progress",
      "review": "In review",
      "measurement": "Measurement"
    }
  }
}
JSON
  echo "$sb"
}

# install_mock_gh: install a fake `gh` in <sandbox>/bin and prepend to PATH.
# The mock reads state from files under <sandbox>/.mock-board/:
#   project_found   — "1" → project list returns a match; absent/0 → empty
#   field_found     — "1" → field list returns a match; absent/0 → empty
#   item_found      — "1" → item list returns a match; absent/0 → empty
#   item_edit_fail  — "1" → item-edit exits 1; absent/0 → exits 0
#   calls           — a file to which each intercepted call appends one line
install_mock_gh() {
  local sb="$1"
  local mock_state="$sb/.mock-board"
  mkdir -p "$mock_state"
  mkdir -p "$sb/bin"

  cat > "$sb/bin/gh" <<GHEOF
#!/bin/bash
STATE_DIR="$mock_state"

log() {
  echo "\$*" >> "\$STATE_DIR/calls"
}

# Reconstruct the subcommand (first two non-flag args).
subcmd="\$1 \$2"

case "\$subcmd" in

  "project list")
    log "project list \$*"
    found=\$(cat "\$STATE_DIR/project_found" 2>/dev/null || echo "")
    if [ "\$found" = "1" ]; then
      printf '{"projects":[{"id":"PVT_abc123","number":7,"title":"My Board"}]}\n'
    else
      printf '{"projects":[]}\n'
    fi
    exit 0
    ;;

  "project field-list")
    log "project field-list \$*"
    found=\$(cat "\$STATE_DIR/field_found" 2>/dev/null || echo "")
    if [ "\$found" = "1" ]; then
      printf '{"fields":[{"id":"PVTF_f1","name":"Status","type":"single_select","options":[{"id":"OPT_ip","name":"In progress"},{"id":"OPT_rv","name":"In review"},{"id":"OPT_ms","name":"Measurement"}]}]}\n'
    else
      printf '{"fields":[]}\n'
    fi
    exit 0
    ;;

  "project item-list")
    log "project item-list \$*"
    found=\$(cat "\$STATE_DIR/item_found" 2>/dev/null || echo "")
    if [ "\$found" = "1" ]; then
      printf '{"items":[{"id":"PVTI_i1","content":{"number":42,"type":"Issue"}}]}\n'
    else
      printf '{"items":[]}\n'
    fi
    exit 0
    ;;

  "project item-edit")
    log "project item-edit \$*"
    fail=\$(cat "\$STATE_DIR/item_edit_fail" 2>/dev/null || echo "")
    if [ "\$fail" = "1" ]; then
      echo "gh: error: item-edit failed (mock)" >&2
      exit 1
    fi
    exit 0
    ;;

  *)
    echo "[mock-gh] unhandled: \$*" >&2
    exit 127
    ;;
esac
GHEOF
  chmod +x "$sb/bin/gh"
  # Prepend the mock bin to PATH (subshell-safe because each test case runs
  # inside its own subshell).
  PATH="$sb/bin:$PATH"
  export PATH
}

# mock_set: write a flag file into the mock state dir.
#   mock_set <sandbox> <flag> <value>
mock_set() {
  local sb="$1" flag="$2" value="$3"
  echo "$value" > "$sb/.mock-board/$flag"
}

# call_count: count lines in the calls log that match a pattern.
call_count() {
  local sb="$1" pattern="$2"
  grep -c "$pattern" "$sb/.mock-board/calls" 2>/dev/null || echo 0
}

# ---------------------------------------------------------------------------
# Case 1: opt-in off → silent no-op, gh never called
# ---------------------------------------------------------------------------
case1() {
  local label="opt-in off → no-op, gh not called"
  result=$(
    sb=$(make_sandbox)
    install_mock_gh "$sb"
    # Override with enable_auto_moves=false
    cat > "$sb/.claude/project-config.json" <<'JSON'
{"github_projects": {"enable_auto_moves": false}}
JSON
    cd "$sb" || exit 1
    export APEXYARD_OPS_DISABLE_PIN=1
    unset _CONFIG_CACHE _CONFIG_ROOT_CACHE 2>/dev/null || true
    # shellcheck source=/dev/null
    . "$LIB"
    board_move_card 42 "in_progress"
    rc=$?
    gh_calls=$(call_count "$sb" "project")
    echo "rc=$rc gh_calls=$gh_calls"
  )
  if echo "$result" | grep -q "rc=0" && echo "$result" | grep -q "gh_calls=0"; then
    pass_case "$label"
  else
    fail_case "$label" "expected rc=0 and 0 gh calls; got: $result"
  fi
}

# ---------------------------------------------------------------------------
# Case 2: happy path — project/field/item found, item-edit succeeds
# ---------------------------------------------------------------------------
case2() {
  local label="happy path → item-edit called for 'in_progress'"
  result=$(
    sb=$(make_sandbox)
    install_mock_gh "$sb"
    mock_set "$sb" project_found 1
    mock_set "$sb" field_found   1
    mock_set "$sb" item_found    1
    cd "$sb" || exit 1
    export APEXYARD_OPS_DISABLE_PIN=1
    unset _CONFIG_CACHE _CONFIG_ROOT_CACHE 2>/dev/null || true
    # shellcheck source=/dev/null
    . "$LIB"
    stderr_output=$(board_move_card 42 "in_progress" 2>&1)
    rc=$?
    edit_calls=$(call_count "$sb" "item-edit")
    echo "rc=$rc edit_calls=$edit_calls stderr=[$stderr_output]"
  )
  if echo "$result" | grep -q "rc=0" && echo "$result" | grep -qE "edit_calls=[1-9]" && \
     ! echo "$result" | grep -q "WARN"; then
    pass_case "$label"
  else
    fail_case "$label" "expected rc=0, >=1 item-edit call, no WARN; got: $result"
  fi
}

# Case 2b: verify that 'review' maps to the correct option
case2b() {
  local label="happy path → item-edit called for 'review'"
  result=$(
    sb=$(make_sandbox)
    install_mock_gh "$sb"
    mock_set "$sb" project_found 1
    mock_set "$sb" field_found   1
    mock_set "$sb" item_found    1
    cd "$sb" || exit 1
    export APEXYARD_OPS_DISABLE_PIN=1
    unset _CONFIG_CACHE _CONFIG_ROOT_CACHE 2>/dev/null || true
    # shellcheck source=/dev/null
    . "$LIB"
    board_move_card 42 "review" 2>/dev/null
    rc=$?
    edit_calls=$(call_count "$sb" "item-edit")
    echo "rc=$rc edit_calls=$edit_calls"
  )
  if echo "$result" | grep -q "rc=0" && echo "$result" | grep -qE "edit_calls=[1-9]"; then
    pass_case "$label"
  else
    fail_case "$label" "expected rc=0 and >=1 item-edit; got: $result"
  fi
}

# Case 2c: verify 'measurement' maps
case2c() {
  local label="happy path → item-edit called for 'measurement'"
  result=$(
    sb=$(make_sandbox)
    install_mock_gh "$sb"
    mock_set "$sb" project_found 1
    mock_set "$sb" field_found   1
    mock_set "$sb" item_found    1
    cd "$sb" || exit 1
    export APEXYARD_OPS_DISABLE_PIN=1
    unset _CONFIG_CACHE _CONFIG_ROOT_CACHE 2>/dev/null || true
    # shellcheck source=/dev/null
    . "$LIB"
    board_move_card 42 "measurement" 2>/dev/null
    rc=$?
    edit_calls=$(call_count "$sb" "item-edit")
    echo "rc=$rc edit_calls=$edit_calls"
  )
  if echo "$result" | grep -q "rc=0" && echo "$result" | grep -qE "edit_calls=[1-9]"; then
    pass_case "$label"
  else
    fail_case "$label" "expected rc=0 and >=1 item-edit; got: $result"
  fi
}

# ---------------------------------------------------------------------------
# Case 3: graceful degrade — project not found
# ---------------------------------------------------------------------------
case3() {
  local label="graceful degrade: project not found → warn, exit 0"
  result=$(
    sb=$(make_sandbox)
    install_mock_gh "$sb"
    # project_found NOT set → mock returns empty list
    cd "$sb" || exit 1
    export APEXYARD_OPS_DISABLE_PIN=1
    unset _CONFIG_CACHE _CONFIG_ROOT_CACHE 2>/dev/null || true
    # shellcheck source=/dev/null
    . "$LIB"
    stderr_out=$(board_move_card 42 "in_progress" 2>&1)
    rc=$?
    echo "rc=$rc stderr=[$stderr_out]"
  )
  if echo "$result" | grep -q "rc=0" && echo "$result" | grep -q "WARN"; then
    pass_case "$label"
  else
    fail_case "$label" "expected rc=0 + WARN; got: $result"
  fi
}

# ---------------------------------------------------------------------------
# Case 4: graceful degrade — status field not found on board
# ---------------------------------------------------------------------------
case4() {
  local label="graceful degrade: field not found → warn, exit 0"
  result=$(
    sb=$(make_sandbox)
    install_mock_gh "$sb"
    mock_set "$sb" project_found 1
    # field_found NOT set → mock returns empty field list
    cd "$sb" || exit 1
    export APEXYARD_OPS_DISABLE_PIN=1
    unset _CONFIG_CACHE _CONFIG_ROOT_CACHE 2>/dev/null || true
    # shellcheck source=/dev/null
    . "$LIB"
    stderr_out=$(board_move_card 42 "in_progress" 2>&1)
    rc=$?
    echo "rc=$rc stderr=[$stderr_out]"
  )
  if echo "$result" | grep -q "rc=0" && echo "$result" | grep -q "WARN"; then
    pass_case "$label"
  else
    fail_case "$label" "expected rc=0 + WARN; got: $result"
  fi
}

# ---------------------------------------------------------------------------
# Case 5: graceful degrade — item not on board
# ---------------------------------------------------------------------------
case5() {
  local label="graceful degrade: item not on board → warn, exit 0"
  result=$(
    sb=$(make_sandbox)
    install_mock_gh "$sb"
    mock_set "$sb" project_found 1
    mock_set "$sb" field_found   1
    # item_found NOT set → mock returns empty items list
    cd "$sb" || exit 1
    export APEXYARD_OPS_DISABLE_PIN=1
    unset _CONFIG_CACHE _CONFIG_ROOT_CACHE 2>/dev/null || true
    # shellcheck source=/dev/null
    . "$LIB"
    stderr_out=$(board_move_card 42 "in_progress" 2>&1)
    rc=$?
    echo "rc=$rc stderr=[$stderr_out]"
  )
  if echo "$result" | grep -q "rc=0" && echo "$result" | grep -q "WARN"; then
    pass_case "$label"
  else
    fail_case "$label" "expected rc=0 + WARN; got: $result"
  fi
}

# ---------------------------------------------------------------------------
# Case 6: graceful degrade — gh project item-edit fails
# ---------------------------------------------------------------------------
case6() {
  local label="graceful degrade: item-edit fails → warn, exit 0"
  result=$(
    sb=$(make_sandbox)
    install_mock_gh "$sb"
    mock_set "$sb" project_found  1
    mock_set "$sb" field_found    1
    mock_set "$sb" item_found     1
    mock_set "$sb" item_edit_fail 1
    cd "$sb" || exit 1
    export APEXYARD_OPS_DISABLE_PIN=1
    unset _CONFIG_CACHE _CONFIG_ROOT_CACHE 2>/dev/null || true
    # shellcheck source=/dev/null
    . "$LIB"
    stderr_out=$(board_move_card 42 "in_progress" 2>&1)
    rc=$?
    echo "rc=$rc stderr=[$stderr_out]"
  )
  if echo "$result" | grep -q "rc=0" && echo "$result" | grep -q "WARN"; then
    pass_case "$label"
  else
    fail_case "$label" "expected rc=0 + WARN; got: $result"
  fi
}

# ---------------------------------------------------------------------------
# Case 7: graceful degrade — owner not configured
# ---------------------------------------------------------------------------
case7() {
  local label="graceful degrade: owner not configured → warn, exit 0"
  result=$(
    sb=$(make_sandbox)
    install_mock_gh "$sb"
    # Override config to clear owner but keep enable_auto_moves=true
    cat > "$sb/.claude/project-config.json" <<'JSON'
{"github_projects": {"owner": "", "board_number": 7, "enable_auto_moves": true}}
JSON
    cd "$sb" || exit 1
    export APEXYARD_OPS_DISABLE_PIN=1
    unset _CONFIG_CACHE _CONFIG_ROOT_CACHE 2>/dev/null || true
    # shellcheck source=/dev/null
    . "$LIB"
    stderr_out=$(board_move_card 42 "in_progress" 2>&1)
    rc=$?
    echo "rc=$rc stderr=[$stderr_out]"
  )
  if echo "$result" | grep -q "rc=0" && echo "$result" | grep -q "WARN"; then
    pass_case "$label"
  else
    fail_case "$label" "expected rc=0 + WARN; got: $result"
  fi
}

# ---------------------------------------------------------------------------
# Case 8: graceful degrade — unknown status key
# ---------------------------------------------------------------------------
case8() {
  local label="graceful degrade: unknown status key → warn, exit 0"
  result=$(
    sb=$(make_sandbox)
    install_mock_gh "$sb"
    mock_set "$sb" project_found 1
    cd "$sb" || exit 1
    export APEXYARD_OPS_DISABLE_PIN=1
    unset _CONFIG_CACHE _CONFIG_ROOT_CACHE 2>/dev/null || true
    # shellcheck source=/dev/null
    . "$LIB"
    stderr_out=$(board_move_card 42 "nonexistent_key" 2>&1)
    rc=$?
    edit_calls=$(call_count "$sb" "item-edit")
    echo "rc=$rc edit_calls=$edit_calls stderr=[$stderr_out]"
  )
  if echo "$result" | grep -q "rc=0" && echo "$result" | grep -q "WARN" && \
     echo "$result" | grep -q "edit_calls=0"; then
    pass_case "$label"
  else
    fail_case "$label" "expected rc=0 + WARN + no item-edit calls; got: $result"
  fi
}

# ---------------------------------------------------------------------------
# Run all cases
# ---------------------------------------------------------------------------
case1
case2
case2b
case2c
case3
case4
case5
case6
case7
case8

echo ""
echo "==================================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "==================================="

if [ "$FAIL" -gt 0 ]; then
  echo "Failed cases: $FAILED_CASES" >&2
  exit 1
fi
exit 0
