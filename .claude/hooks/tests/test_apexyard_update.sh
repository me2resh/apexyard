#!/usr/bin/env bash
# Test change reports and the agent command without network access.
# The shared fixture defines sb.
# shellcheck disable=SC2154
source "$(dirname "${BASH_SOURCE[0]}")/_lib-apexyard-cli.sh"
check 'init succeeds' init_ops
mkdir -p "$sb/lib" "$sb/ops/subdir"
export APEXYARD_LIB_DIR="$sb/lib" APEXYARD_FRAMEWORK_REF=main
cat > "$sb/lib/_lib-ownership.sh" <<'SH'
ownership_class() { echo framework; }
ownership_is_security() { [ "$1" = z-security.sh ]; }
SH
echo ordinary > "$sb/fixture/a-file.txt"
echo security > "$sb/fixture/z-security.sh"
git -C "$sb/fixture" add -- a-file.txt z-security.sh
git -C "$sb/fixture" commit -m update >/dev/null
cd "$sb/ops/subdir" || exit 1
check 'check succeeds' /bin/bash "$CLI" update --check > "$sb/check.out" 2>&1
check owner grep -q 'a-file.txt \[framework\]' "$sb/check.out"
check 'security owner' grep -q 'z-security.sh \[framework\]' "$sb/check.out"
security_line=$(grep -n 'z-security.sh' "$sb/check.out" | cut -d: -f1)
other_line=$(grep -n 'a-file.txt' "$sb/check.out" | cut -d: -f1)
check 'security first' test "$security_line" -lt "$other_line"
check 'loud header' grep -q '!!! SECURITY-OWNED CHANGES !!!' "$sb/check.out"
check 'version unchanged' test "$(cat "$sb/ops/.claude/framework-version")" = v1.0.0
export APEXYARD_LIB_DIR="$sb/absent"
check 'missing library succeeds' /bin/bash "$CLI" update --check > "$sb/unknown.out" 2>&1
check 'missing library message' grep -q 'ownership manifest library not found' "$sb/unknown.out"
check 'unknown owner' grep -q 'a-file.txt \[unknown\]' "$sb/unknown.out"
export APEXYARD_AGENT_CMD="$sb/tools/agent" AGENT_LOG="$sb/agent.log"
cat > "$APEXYARD_AGENT_CMD" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$#" "$1" "$PWD" > "$AGENT_LOG"
SH
chmod +x "$APEXYARD_AGENT_CMD"
check handoff /bin/bash "$CLI" update > "$sb/handoff.out" 2>&1
check 'single argument' test "$(sed -n '1p' "$AGENT_LOG")" = 1
check 'skill argument' test "$(sed -n '2p' "$AGENT_LOG")" = /update
check 'agent root' test "$(sed -n '3p' "$AGENT_LOG")" = "$sb/ops"
export APEXYARD_AGENT_CMD="$sb/tools/absent"
check 'missing agent succeeds' /bin/bash "$CLI" update > "$sb/noagent.out" 2>&1
check 'manual instruction' grep -q 'Run /update in your agent tool.' "$sb/noagent.out"
printf 'invalid-version\n' > "$sb/ops/.claude/framework-version"
if /bin/bash "$CLI" update --check > "$sb/invalid.out" 2>&1; then rc=0; else rc=$?; fi
check 'invalid version fails' test "$rc" -ne 0
printf 'v1.0.0\n' > "$sb/ops/.claude/framework-version"
git -C "$sb/ops" remote remove upstream
if /bin/bash "$CLI" update --check > "$sb/noremote.out" 2>&1; then rc=0; else rc=$?; fi
check 'missing upstream exit' test "$rc" = 2
check 'missing upstream message' grep -q 'upstream remote not found' "$sb/noremote.out"
finish
