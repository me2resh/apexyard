#!/usr/bin/env bash
# Regression test for me2resh/apexyard#584.
#
# extract_push_ref() stripped shell redirections with `[[:space:]]*[0-9]*[>|].*`.
# The zero-width `[[:space:]]*` let a bare `>` inside an ASCII arrow `->` in a
# commit message match, truncating a compound `commit ... && git push <branch>`
# before the push segment → extract_push_ref returned empty → the caller fell
# back to local HEAD and falsely BLOCKED the push. The fix requires a whitespace
# token boundary before the operator.

set -u
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
. "$HOOK_DIR/_lib-extract-push-ref.sh"

pass=0; fail=0
eq() { # eq <label> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "  ok: $1"; pass=$((pass + 1));
  else echo "  FAIL: $1 — expected [$2] got [$3]"; fail=$((fail + 1)); fi
}
is() { # is <label> <expect 0|1> <cmd...>
  if is_tag_push "$3"; then got=0; else got=1; fi
  eq "$1" "$2" "$got"
}

# --- the #584 bug: arrow in the commit message must not eat the push segment ---
eq "arrow in commit msg keeps the push ref" "feature/GH-1-foo" \
  "$(extract_push_ref 'git add a && git commit -m "fix: remap blue->info, purple->violet" && git push origin feature/GH-1-foo')"

eq "multiple arrows still keep the ref" "feature/GH-2-bar" \
  "$(extract_push_ref 'git commit -m "a->b->c->d" && git push -u origin feature/GH-2-bar')"

# --- redirections must STILL be stripped (no regression) ---
eq "real redirection still stripped" "feature/GH-1-foo" \
  "$(extract_push_ref 'git push upstream HEAD:feature/GH-1-foo 2>&1 | tail -5')"

eq "pipe suffix still stripped" "feature/GH-3-baz" \
  "$(extract_push_ref 'git push origin feature/GH-3-baz | cat')"

# --- unchanged baselines ---
eq "plain push" "feature/GH-9-x" "$(extract_push_ref 'git push origin feature/GH-9-x')"
eq "refspec dst" "feature/GH-9-y" "$(extract_push_ref 'git push origin HEAD:feature/GH-9-y')"

# --- is_tag_push not fooled by an arrow either ---
is "arrow in commit msg is not a tag push" 1 'git commit -m "blue->info" && git push origin feature/GH-1-foo'
is "real tag push still detected" 0 'git push origin --tags'
is "refs/tags push still detected" 0 'git push origin refs/tags/v1.0.0'

echo ""
if [ "$fail" -eq 0 ]; then echo "All $pass test(s) passed."; exit 0; else echo "$fail test(s) failed."; exit 1; fi
