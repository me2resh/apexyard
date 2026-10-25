#!/usr/bin/env bash
# Keep all repositories and command stubs inside one temporary directory.
set -euo pipefail
CLI=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/bin/apexyard
sb=$(mktemp -d)
trap 'rm -rf "$sb"' EXIT
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.invalid
export GIT_TERMINAL_PROMPT=0
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
mkdir -p "$sb/fixture/.claude" "$sb/tools"
export APEXYARD_FRAMEWORK_URL="$sb/fixture" APEXYARD_FRAMEWORK_REF=v1.0.0
export APEXYARD_GH="$sb/tools/gh" FAKE_GH_LOG="$sb/gh.log" FAKE_REMOTE="$sb/remote.git"
cat > "$APEXYARD_GH" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$FAKE_GH_LOG"
if [ "$1" = api ]; then echo example-org; exit 0; fi
[ "$1" = repo ] && [ "$2" = create ] || exit 2
git -C "$FAKE_ROOT" init --bare "$FAKE_REMOTE" >/dev/null
git -C "$PWD" remote add origin "$FAKE_REMOTE"
git -C "$PWD" push -u origin main
SH
chmod +x "$APEXYARD_GH"
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
