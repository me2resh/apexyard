#!/usr/bin/env bash
# Keep all repositories and command stubs inside one temporary directory.
set -euo pipefail
# A terminal on stdin starts the init wizard. Tests that want it pipe input.
exec </dev/null
CLI=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/bin/apexyard
sb=$(mktemp -d)
trap 'rm -rf "$sb"' EXIT
export HOME="$sb/home" XDG_CONFIG_HOME="$sb/config"
export APEXYARD_TELEMETRY=0
mkdir -p "$HOME" "$XDG_CONFIG_HOME"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.invalid
export GIT_TERMINAL_PROMPT=0
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
# A caller's own Cockpit settings must not reach a real pipx or install source.
unset APEXYARD_PIPX APEXYARD_COCKPIT APEXYARD_COCKPIT_SOURCE APEXYARD_COCKPIT_TAG
mkdir -p "$sb/fixture/.claude" "$sb/tools"
export APEXYARD_FRAMEWORK_URL="$sb/fixture" APEXYARD_FRAMEWORK_REF=v1.0.0
export APEXYARD_GH="$sb/tools/gh" FAKE_GH_LOG="$sb/gh.log" FAKE_REMOTE="$sb/remote.git"
cat > "$APEXYARD_GH" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$FAKE_GH_LOG"
if [ "$1" = api ]; then
  if [ "$2" = user/orgs ]; then printf 'acme\nbeta\n'; else echo example-org; fi
  exit 0
fi
if [ "$1" = repo ] && [ "$2" = view ]; then
  [ "${FAKE_GH_OFFLINE:-0}" != 1 ] || exit 1
  if [ -n "${FAKE_GH_CHECK_TARGET:-}" ]; then
    if [ -e "$FAKE_GH_CHECK_TARGET" ]; then
      echo 'view: target exists' >> "$FAKE_GH_LOG"
    else
      echo 'view: target absent' >> "$FAKE_GH_LOG"
    fi
  fi
  if [ -f "$FAKE_ROOT/gh-created" ] && grep -Fxq -- "$3" "$FAKE_ROOT/gh-created"; then exit 0; fi
  [ -n "${FAKE_GH_EXISTING:-}" ] && grep -Fxq -- "$3" "$FAKE_GH_EXISTING"
  exit $?
fi
[ "$1" = repo ] && [ "$2" = create ] || exit 2
[ "${FAKE_GH_FAIL_CREATE:-0}" != 1 ] || exit 1
if [ "${FAKE_GH_ORIGIN_FAIL:-0}" = 1 ]; then
  git remote add origin "https://github.com/$3.git"
  exit 1
fi
# Create the repo, then fail the push, as gh does without a loaded ssh key.
if [ "${FAKE_GH_FAIL_PUSH:-0}" = 1 ]; then printf '%s\n' "$3" >> "$FAKE_ROOT/gh-created"; exit 1; fi
git -C "$FAKE_ROOT" init --bare "$FAKE_REMOTE" >/dev/null
git -C "$PWD" remote add origin "$FAKE_REMOTE"
git -C "$PWD" push -u origin main
SH
chmod +x "$APEXYARD_GH"
# Never start a real agent from a test.
export APEXYARD_AGENT_CMD="$sb/tools/agent" FAKE_AGENT_LOG="$sb/agent.log"
# The stub expands these variables when it runs.
# shellcheck disable=SC2016
printf '#!/usr/bin/env bash\nprintf "%%s %%s\\n" "$PWD" "$*" >> "$FAKE_AGENT_LOG"\n' > "$APEXYARD_AGENT_CMD"
chmod +x "$APEXYARD_AGENT_CMD"
export FAKE_ROOT="$sb"
printf 'company:\n  name: "Your Company Name"\n' > "$sb/fixture/onboarding.example.yaml"
echo 'projects: []' > "$sb/fixture/apexyard.projects.yaml.example"
printf 'onboarding.yaml\napexyard.projects.yaml\n' > "$sb/fixture/.gitignore"
git -C "$sb/fixture" init -b main >/dev/null
git -C "$sb/fixture" add -- .gitignore onboarding.example.yaml apexyard.projects.yaml.example
git -C "$sb/fixture" commit -m fixture >/dev/null
git -C "$sb/fixture" tag v1.0.0
passed=0 failed=0
check() {
  local label=$1
  shift
  if "$@"; then passed=$((passed + 1)); else
    echo "FAIL: $label"
    failed=$((failed + 1))
  fi
}
finish() {
  printf '%s passed, %s failed\n' "$passed" "$failed"
  [ "$failed" -eq 0 ]
}
init_ops() {
  /bin/bash "$CLI" init --dir "$sb/ops" > "$sb/init.out" 2>&1
}
