#!/bin/bash
# A readable, sourceable library can still be empty or truncated. Each gate
# must check the functions it needs before treating a command as a no-op.
set -u

ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
HOOKS=${HOOKS_OVERRIDE:-$ROOT/.claude/hooks}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAIL=0

mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'EOF'
#!/bin/bash
exit 0
EOF
cat > "$TMP/bin/glab" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$TMP/bin/gh" "$TMP/bin/glab"
PAYLOAD=$(jq -nc --arg c 'gh pr merge 7 --repo demo/service --squash' '{tool_name:"Bash",tool_input:{command:$c}}')

check() {
  local gate="$1" lib="$2" mode="$3" missing="$4" sb rc
  sb="$TMP/case-$((PASS + FAIL + 1))"
  mkdir -p "$sb/.claude/hooks"
  cp "$HOOKS"/_lib-*.sh "$sb/.claude/hooks/"
  cp "$HOOKS/$gate" "$sb/.claude/hooks/$gate"
  (cd "$sb" && git init -q --template=) || exit 1
  case "$mode" in
    empty) : > "$sb/.claude/hooks/$lib" ;;
    truncated)
      printf 'is_merge_command() { return 0; }\n' > "$sb/.claude/hooks/$lib"
      ;;
    missing-function)
      printf '\nunset -f %s\n' "$missing" >> "$sb/.claude/hooks/$lib"
      ;;
  esac
  (cd "$sb" && printf '%s' "$PAYLOAD" | PATH="$TMP/bin:$PATH" APEXYARD_OPS_DISABLE_PIN=1 /bin/bash ".claude/hooks/$gate" >/dev/null 2>"$sb/stderr")
  rc=$?
  if [ "$rc" -eq 2 ] && grep -q "BLOCKED: merge gate missing required function $missing " "$sb/stderr"; then
    printf 'PASS [%s / %s / %s]\n' "$gate" "$lib" "$mode"
    PASS=$((PASS + 1))
  else
    printf 'FAIL [%s / %s / %s]: rc=%s stderr=%s\n' "$gate" "$lib" "$mode" "$rc" "$(tr '\n' ' ' < "$sb/stderr")" >&2
    FAIL=$((FAIL + 1))
  fi
}

for gate in block-unreviewed-merge.sh block-merge-on-red-ci.sh require-architecture-review.sh require-design-review-for-ui.sh; do
  check "$gate" _lib-extract-pr.sh empty is_merge_command
  check "$gate" _lib-extract-pr.sh truncated is_merge_command_raw
done
for gate in block-unreviewed-merge.sh require-architecture-review.sh require-design-review-for-ui.sh; do
  check "$gate" _lib-review-markers.sh empty review_marker_path
  check "$gate" _lib-review-markers.sh missing-function unqualified_marker_hint
done
for gate in require-architecture-review.sh require-design-review-for-ui.sh; do
  check "$gate" _lib-pr-repo.sh empty pr_cmd_cd_target
  check "$gate" _lib-pr-repo.sh missing-function git_origin_repo
done

printf 'RESULT: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
