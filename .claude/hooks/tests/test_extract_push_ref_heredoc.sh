#!/usr/bin/env bash
# Regression test for me2resh/apexyard#1066.
#
# `extract_push_ref` (and `is_tag_push`) scanned the WHOLE raw command text
# for the first "git push" / "--tags" match, including text sitting inside a
# heredoc BODY. This repo's own commit messages routinely *discuss* git
# behaviour in prose, so a heredoc that happens to mention "git push" before
# the real push invocation matched the prose instead of the actual command —
# the exact deterministic repro from the ticket:
#
#   cat > /tmp/m.txt <<EOF
#   The previous commit claimed terminal `git push` still runs the checks...
#   EOF
#   git commit -F /tmp/m.txt
#   git push upstream fix/GH-1031-untrack-project-config-json
#
# extracted "still" instead of "fix/GH-1031-untrack-project-config-json".
#
# The fix adds `strip_heredoc_bodies()`, called first thing inside both
# `is_tag_push` and `extract_push_ref`, which drops heredoc BODY text (and
# the heredoc's own start/terminator lines) before any pattern matching.

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

# --- The ticket's exact deterministic repro -------------------------------
TICKET_REPRO=$(cat <<'CMD'
cat > /tmp/m.txt <<EOF
The previous commit claimed terminal `git push` still runs the checks because
bin/run-pre-push-checks.sh hardcodes them.
EOF
git commit -F /tmp/m.txt
git push upstream fix/GH-1031-untrack-project-config-json
CMD
)
eq "#1066: heredoc prose mentioning 'git push' does not win over the real push" \
  "fix/GH-1031-untrack-project-config-json" "$(extract_push_ref "$TICKET_REPRO")"

# --- Unquoted heredoc, quoted heredoc, and tab-indented heredoc all strip -
UNQUOTED=$(cat <<'CMD'
cat > /tmp/a.txt <<EOF
mentions git push nowhere useful
EOF
git push origin feature/GH-2-foo
CMD
)
eq "unquoted <<EOF heredoc body stripped" "feature/GH-2-foo" "$(extract_push_ref "$UNQUOTED")"

SINGLEQUOTED=$(cat <<'CMD'
cat > /tmp/b.txt <<'EOF'
prose that says git push origin wrong-branch
EOF
git push origin feature/GH-3-bar
CMD
)
eq "single-quoted <<'EOF' heredoc body stripped" "feature/GH-3-bar" "$(extract_push_ref "$SINGLEQUOTED")"

DOUBLEQUOTED=$(cat <<'CMD'
cat > /tmp/c.txt <<"EOF"
prose that says git push origin wrong-branch
EOF
git push origin feature/GH-4-baz
CMD
)
eq "double-quoted <<\"EOF\" heredoc body stripped" "feature/GH-4-baz" "$(extract_push_ref "$DOUBLEQUOTED")"

DASHTAB=$(cat <<'CMD'
cat > /tmp/d.txt <<-EOF
	prose that says git push origin wrong-branch, tab-indented
	EOF
git push origin feature/GH-5-qux
CMD
)
eq "<<-EOF (tab-stripped terminator) heredoc body stripped" "feature/GH-5-qux" "$(extract_push_ref "$DASHTAB")"

# --- is_tag_push must not be fooled by heredoc prose mentioning --tags ----
TAGPROSE=$(cat <<'CMD'
cat > /tmp/e.txt <<EOF
the release notes say git push --tags is how we cut a release
EOF
git push origin feature/GH-6-quux
CMD
)
is "heredoc prose mentioning '--tags' does not trigger is_tag_push" 1 "$TAGPROSE"

REALTAG=$(cat <<'CMD'
cat > /tmp/f.txt <<EOF
irrelevant prose
EOF
git push origin --tags
CMD
)
is "a real --tags push after an unrelated heredoc is still detected" 0 "$REALTAG"

# --- A here-string (<<<) must never be mistaken for a heredoc start -------
HERESTRING="git push origin feature/GH-7-corge # note: uses <<< later in prose, not a heredoc"
eq "here-string marker (<<<) does not trigger heredoc stripping" \
  "feature/GH-7-corge" "$(extract_push_ref "$HERESTRING")"

# --- Multiple heredocs in one command: only the mentioned one matters ----
MULTI=$(cat <<'CMD'
cat > /tmp/g.txt <<EOF
first heredoc mentions git push nonsense
EOF
cat > /tmp/h.txt <<EOF
second heredoc also mentions git push more nonsense
EOF
git push origin feature/GH-8-grault
CMD
)
eq "multiple heredocs before the real push are all stripped" \
  "feature/GH-8-grault" "$(extract_push_ref "$MULTI")"

# --- Baseline regressions (#547/#584) must be unaffected ------------------
eq "#584 regression: arrow in commit msg keeps the push ref" "feature/GH-1-foo" \
  "$(extract_push_ref 'git add a && git commit -m "fix: remap blue->info, purple->violet" && git push origin feature/GH-1-foo')"
eq "#547 regression: refspec dst still resolved" "feature/GH-9-y" \
  "$(extract_push_ref 'git push origin HEAD:feature/GH-9-y')"
eq "plain push (no heredoc at all) still works" "feature/GH-9-x" \
  "$(extract_push_ref 'git push origin feature/GH-9-x')"

echo ""
if [ "$fail" -eq 0 ]; then echo "All $pass test(s) passed."; exit 0; else echo "$fail test(s) failed."; exit 1; fi
