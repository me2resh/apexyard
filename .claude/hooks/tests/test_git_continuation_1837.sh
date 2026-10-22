#!/bin/bash
# #1837: the dispatcher routes a push or commit when a line continuation
# splits a word (the verb, a -C value, a redirection target or a dashed
# program name), and when a variable verb comes after a redirection.
# Each route class has an allow twin that still routes nothing.
# Fail-before uses the hooks tree at a pinned dev commit (build rule 10a).
set -eu
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../../.." && pwd)
HOOKS="$ROOT/.claude/hooks"
PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1" >&2; }

# Fixture git commands must not see a caller's repository variables.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
CWD="$TMP/cwd"
git init -q "$CWD"
git -C "$CWD" -c user.email=test@example.com -c user.name=Test -c core.hooksPath=/dev/null \
  -c commit.gpgsign=false commit -q --allow-empty -m init
git -C "$CWD" checkout -q -B feature/GH-1837-x

# Stub gates log their names. Every other file is the real hook tree.
scripts=$(sed -n 's/^# APEXYARD_DISPATCH_GATE: Bash|[^|]*|//p' "$HOOKS/dispatch-bash.sh" | sort -u)
stub_tree() {
  local src="$1" dest="$2" script
  mkdir -p "$dest"
  cp "$src"/*.sh "$dest/"
  for script in $scripts; do
    cat > "$dest/$script" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
printf '%s\n' "$(basename "$0")" >> "${DISPATCH_LOG:?}"
EOF
    chmod +x "$dest/$script"
  done
  chmod +x "$dest/dispatch-bash.sh"
}

payload_of() {
  python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]},"cwd":sys.argv[2]}))' \
    "$1" "$CWD"
}

# Prints "<rc> <push gates ran> <commit gates ran>" for one command.
route() {
  local tree="$1" cmd="$2" rc=0 p=0 c=0
  : > "$TMP/log"
  (cd "$CWD" && payload_of "$cmd" | DISPATCH_LOG="$TMP/log" /bin/bash "$tree/dispatch-bash.sh" >/dev/null 2>"$TMP/err") || rc=$?
  grep -qx block-main-push.sh "$TMP/log" && p=1
  grep -qx check-secrets.sh "$TMP/log" && c=1
  printf '%s %s %s' "$rc" "$p" "$c"
}

# Build every command from parts, so no live hook sees a literal command.
G=git
NL=$'\n'
BS='\'
REF=feature/GH-1837-x
# Each case: "<want push> <want commit>|<command>".
route_cases=(
  # A continuation splits the verb.
  "1 0|$G pu${BS}${NL}sh origin $REF"
  "0 1|$G com${BS}${NL}mit -m x"
  # A continuation splits a -C value.
  "1 0|$G -C /${BS}${NL}tmp push origin $REF"
  "0 1|$G -C .${BS}${NL}/ commit -m x"
  # A continuation splits a redirection target before the verb.
  "1 0|$G >a${BS}${NL}b push origin $REF"
  "0 1|$G 2>a${BS}${NL}b commit -m x"
  # A continuation splits the command word.
  "1 0|gi${BS}${NL}t push origin $REF"
  # A continuation splits the dashed program name (#1825 class).
  "1 1|$G-pu${BS}${NL}sh origin $REF"
  "1 1|/usr/libexec/git-core/$G-com${BS}${NL}mit -m x"
  "1 1|$G-${BS}${NL}push origin $REF"
  "1 1|gi${BS}${NL}t-commit -m x"
  # A line that ends in an escaped backslash is not a continuation. The
  # next line keeps its command position.
  "1 1|echo a${BS}${BS}${NL}$G-push origin $REF"
  # A variable verb after a redirection.
  "1 1|$G >out \$v origin $REF"
  "1 1|$G 2>/dev/null \$V -m x"
  "1 1|$G >\"a b\" \${V} origin $REF"
  "1 1|$G>out \$v origin $REF"
  "1 1|$G -C /tmp >out \$v origin $REF"
  "1 1|$G >out -C /tmp \$v origin $REF"
  "1 1|$G <<<x \$v origin $REF"
  "1 1|$G 2>&1 \$(printf x) origin $REF"
)
# Allow twins: each one routes nothing.
twin_cases=(
  "$G lo${BS}${NL}g --oneline"
  "$G -C /${BS}${NL}tmp status"
  "$G -C .${BS}${NL}/ log"
  "$G >a${BS}${NL}b log"
  "gi${BS}${NL}t status"
  "$G-lo${BS}${NL}g"
  "$G-${BS}${NL}log"
  "echo a${BS}${BS}${NL}$G-log"
  "echo '$G pu${BS}${NL}sh'"
  "# $G pu${BS}${NL}sh"
  "$G log ${BS}${NL}  --oneline ${BS}${NL}  -n 3"
  "$G >out log --oneline"
  "$G >out log \$v"
  "$G >\$out status"
  "$G >out \$v"
  "$G 2>&1 status"
)

stub_tree "$HOOKS" "$TMP/head"

# Fail-before: the dev commit before #1837 (the #1839 squash). A squash
# merge keeps it on dev. CONTINUATION_1837_BASE_REF overrides the pin.
FAIL_BEFORE_PIN=1200b6df0ed3d64272176b22222503cea818e077
BASE_REF="${CONTINUATION_1837_BASE_REF:-$FAIL_BEFORE_PIN}"
if git -C "$ROOT" rev-parse --verify --quiet "${BASE_REF}^{commit}" >/dev/null 2>&1; then
  mkdir -p "$TMP/base-src"
  git -C "$ROOT" archive "$BASE_REF" .claude/hooks | tar -x -C "$TMP/base-src"
  stub_tree "$TMP/base-src/.claude/hooks" "$TMP/base"
  fb_miss=0
  for entry in "${route_cases[@]}"; do
    cmd="${entry#*|}"
    got=$(route "$TMP/base" "$cmd")
    if [ "${got#* }" = "0 0" ]; then
      fb_miss=$((fb_miss + 1))
    else
      fail "fail-before still routes ($got): $(printf '%s' "$cmd" | tr '\n' '~')"
    fi
  done
  if [ "$fb_miss" -eq "${#route_cases[@]}" ]; then
    pass "fail-before: ${fb_miss} cases route nothing on base"
  fi
else
  echo "NOTE: skip fail-before: pinned base ${BASE_REF} is not in this clone"
fi

for entry in "${route_cases[@]}"; do
  want="${entry%%|*}"
  cmd="${entry#*|}"
  got=$(route "$TMP/head" "$cmd")
  label=$(printf '%s' "$cmd" | tr '\n' '~')
  if [ "$got" = "0 $want" ]; then
    pass "routes ($want): $label"
  else
    fail "routes: want 0 $want, got $got: $label"
    cat "$TMP/err" >&2 || true
  fi
done
for cmd in "${twin_cases[@]}"; do
  got=$(route "$TMP/head" "$cmd")
  label=$(printf '%s' "$cmd" | tr '\n' '~')
  if [ "$got" = "0 0 0" ]; then
    pass "allow twin routes nothing: $label"
  else
    fail "allow twin routes nothing: got $got: $label"
    cat "$TMP/err" >&2 || true
  fi
done

# Fail closed: the push and commit gates block a variable verb after a
# redirection. The allow twin passes the same gates.
gate_rc() {
  local gate="$1" cmd="$2" rc=0
  (cd "$CWD" && payload_of "$cmd" | /bin/bash "$HOOKS/$gate" >/dev/null 2>"$TMP/gerr") || rc=$?
  printf '%s' "$rc"
}
for cmd in "$G >out \$v origin $REF" "$G 2>/dev/null \$V -m x" "$G -C /tmp >out \$v origin $REF" \
  "$G>out \$v origin $REF"; do
  for gate in block-main-push.sh check-secrets.sh; do
    rc=$(gate_rc "$gate" "$cmd")
    if [ "$rc" = 2 ] && grep -q 'hides the git command word or verb' "$TMP/gerr"; then
      pass "$gate blocks a variable verb after a redirection: $cmd"
    else
      fail "$gate blocks a variable verb after a redirection (rc=$rc): $cmd: $(head -2 "$TMP/gerr")"
    fi
  done
done
for cmd in "$G >out log --oneline" "$G >out \$v"; do
  for gate in block-main-push.sh check-secrets.sh; do
    rc=$(gate_rc "$gate" "$cmd")
    if [ "$rc" = 0 ]; then
      pass "$gate allows: $cmd"
    else
      fail "$gate allows (rc=$rc): $cmd: $(head -2 "$TMP/gerr")"
    fi
  done
done
# The push gate blocks the dashed program name that a continuation splits.
for cmd in "$G-pu${BS}${NL}sh origin $REF" "$G-${BS}${NL}push origin $REF"; do
  rc=$(gate_rc block-main-push.sh "$cmd")
  label=$(printf '%s' "$cmd" | tr '\n' '~')
  if [ "$rc" = 2 ]; then
    pass "block-main-push.sh blocks a continued dashed name: $label"
  else
    fail "block-main-push.sh blocks a continued dashed name (rc=$rc): $label"
  fi
done

echo "TOTAL $PASS passed; $FAIL failed"
[ "$FAIL" -eq 0 ]
