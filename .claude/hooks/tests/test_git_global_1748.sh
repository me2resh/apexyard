#!/bin/bash
# #1748: every ambiguous global-option form must fail closed.
# Alias resolution is split out of #1756; see the #1748 issue.
set -u
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HOOKS="${GIT_GLOBAL_TEST_HOOKS:-$ROOT/.claude/hooks}"
test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
repo="$test_tmp/a b"
mkdir -p "$repo" "$test_tmp/bin"
git -C "$repo" init -q -b main
git -C "$repo" config user.name Test
git -C "$repo" config user.email test@example.invalid
key_name=api_key
printf '%s = "%s"\n' "$key_name" abcdefghijklmnopqr > "$repo/secret"
git -C "$repo" add secret
# A PATH with all normal tools except jq, including on hosts with several jqs.
for dir in ${PATH//:/ }; do
  for tool in "$dir"/*; do
    [ -f "$tool" ] && [ -x "$tool" ] || continue
    name=${tool##*/}
    [ "$name" = jq ] || ln -sf "$tool" "$test_tmp/bin/$name" 2>/dev/null
  done
done
# Isolate dispatcher routing from unrelated portfolio gates.
mkdir -p "$test_tmp/dispatch"
cp "$HOOKS"/_lib-*.sh "$HOOKS/dispatch-bash.sh" "$test_tmp/dispatch/"
for gate in $(sed -nE 's/^# APEXYARD_DISPATCH_GATE: Bash[^|]*\|[^|]*\|([^ ]+)\.sh$/\1/p' "$HOOKS/dispatch-bash.sh" | sort -u); do
  code=0
  case "$gate" in check-secrets|block-main-push) code=2 ;; esac
  printf '#!/bin/bash\ncat >/dev/null\nexit %s\n' "$code" > "$test_tmp/dispatch/$gate.sh"
  chmod +x "$test_tmp/dispatch/$gate.sh"
done
fail=0
probe() {
  local name="$target-$1" want="$2" hook="$3" cmd="$4" nojq="${5:-0}" payload rc
  [ "$target" != dispatch ] || hook=dispatch-bash
  payload=$(jq -nc --arg command "$cmd" --arg cwd "$repo" '{tool_input:{command:$command},cwd:$cwd}')
  if [ "$nojq" = 1 ]; then
    printf '%s' "$payload" | (cd "$repo" && PATH="$test_tmp/bin" bash "$HOOKS/$hook.sh") >"$test_tmp/out" 2>&1
  else
    printf '%s' "$payload" | (cd "$repo" && bash "$HOOKS/$hook.sh") >"$test_tmp/out" 2>&1
  fi
  rc=$?
  if [ "$rc" = "$want" ]; then echo "PASS $name"; else echo "FAIL $name expected=$want actual=$rc"; cat "$test_tmp/out"; fail=1; fi
}
original_hooks="$HOOKS"
for target in direct dispatch; do
HOOKS="$original_hooks"
[ "$target" != dispatch ] || HOOKS="$test_tmp/dispatch"
for verb in commit push; do
  hook=check-secrets
  [ "$verb" != push ] || hook=block-main-push
  probe "$verb-attr-word" 2 "$hook" "git --attr-source HEAD $verb"
  escaped=${repo// /\\ }
  probe "$verb-escaped-space" 2 "$hook" "git -C $escaped $verb"
  probe "$verb-quoted-git-dir" 2 "$hook" "git --git-dir=\"$repo/.git\" $verb"
  probe "$verb-quoted-work-tree" 2 "$hook" "git --work-tree=\"$repo\" $verb"
  # External git-<verb> commands and quoted text that mentions git stay allowed.
  probe "$verb-external-command" 0 "$hook" 'git unresolved1748'
  probe "$verb-git-lfs" 0 "$hook" 'git lfs ls-files'
  probe "$verb-quoted-git-text" 0 "$hook" 'cd /tmp && echo "git gates"'
  probe "$verb-no-jq" 2 "$hook" "git -C \"$repo\" $verb" 1
  probe "$verb-normal-C" 2 "$hook" "git -C \"$repo\" $verb"
  probe "$verb-normal-git-dir" 2 "$hook" "git --git-dir=.git $verb"
  probe "$verb-safe-status" 0 "$hook" 'git --attr-source=HEAD status'
  probe "$verb-safe-alias" 0 "$hook" 'git -c alias.st=status st'
  probe "$verb-plain-safe" 0 "$hook" 'echo safe'
done
done
exit "$fail"
