#!/bin/bash
# _lib-mock-gh.sh — install a fake `gh` on PATH for hook test sandboxes.
#
# Why: validate-pr-create.sh calls `gh issue view <N> --repo <repo> --json number,state`
# to verify the PR title's referenced issue exists and is OPEN. If the test relies on a
# real upstream issue, every closed/renamed/deleted issue retroactively breaks the suite.
# The shim removes that live-tracker dependency: any `gh issue view <N> ... --json ...`
# call returns synthetic JSON with state=OPEN by default, regardless of N.
#
# Usage in a test file:
#
#     source "$(dirname "$0")/_lib-mock-gh.sh"
#     sb=$(make_sandbox)
#     mock_gh_install "$sb"
#     # ... build the input + run the hook from inside $sb ...
#
# By default state=OPEN for any number. To exercise the CLOSED branch, call
# `mock_gh_set_state <num> CLOSED` before running the case (it writes to a state
# file the shim reads). State file is per-sandbox.
#
# Set MOCK_GH_TRACE=1 to print intercepted calls to stderr for debugging.

# Install the fake `gh` into <sandbox>/bin/ and prepend that to PATH.
# Returns: nothing. Side effect: PATH is modified for the calling shell.
mock_gh_install() {
  local sb="$1"
  if [ -z "$sb" ] || [ ! -d "$sb" ]; then
    echo "mock_gh_install: bad sandbox dir: $sb" >&2
    return 1
  fi
  mkdir -p "$sb/bin"
  local state_file="$sb/.mock-gh-state"
  : > "$state_file"

  # Resolve the real gh once so the shim can pass-through unintercepted calls.
  local real_gh
  real_gh=$(command -v gh 2>/dev/null || true)

  cat > "$sb/bin/gh" <<EOF
#!/bin/bash
# Fake gh — intercepts \`gh issue view <N> ... --json ...\` and returns
# synthetic JSON. Pass-through for everything else (via real gh, if available).
STATE_FILE="$state_file"
REAL_GH="$real_gh"

if [ "\${MOCK_GH_TRACE:-0}" = "1" ]; then
  echo "[mock-gh] \$*" >&2
fi

# Match: gh issue view <N> [--repo R] --json <fields>
if [ "\$1" = "issue" ] && [ "\$2" = "view" ]; then
  num="\$3"
  state="OPEN"
  # Per-number override (one line per: "<num> <state>"). Last write wins.
  if [ -f "\$STATE_FILE" ]; then
    override=\$(grep -E "^\${num} " "\$STATE_FILE" | tail -1 | awk '{print \$2}')
    if [ -n "\$override" ]; then
      state="\$override"
    fi
  fi
  # Emit JSON shaped like \`gh issue view --json number,state\`. The validator
  # only reads .number and .state; extra keys are harmless.
  printf '{"number":%s,"state":"%s"}\n' "\$num" "\$state"
  exit 0
fi

# Pass-through for anything we don't intercept.
if [ -n "\$REAL_GH" ]; then
  exec "\$REAL_GH" "\$@"
fi
echo "[mock-gh] no real gh found and call not intercepted: \$*" >&2
exit 127
EOF
  chmod +x "$sb/bin/gh"
  PATH="$sb/bin:$PATH"
  export PATH
}

# Override the synthetic state for a specific issue number in a sandbox.
# Call AFTER mock_gh_install. Writes to <sandbox>/.mock-gh-state.
#
#   mock_gh_set_state <sandbox> <num> <state>
#
# Example: mock_gh_set_state "$sb" 999 CLOSED
mock_gh_set_state() {
  local sb="$1" num="$2" state="$3"
  if [ -z "$sb" ] || [ -z "$num" ] || [ -z "$state" ]; then
    echo "mock_gh_set_state: usage: mock_gh_set_state <sandbox> <num> <state>" >&2
    return 1
  fi
  echo "$num $state" >> "$sb/.mock-gh-state"
}
