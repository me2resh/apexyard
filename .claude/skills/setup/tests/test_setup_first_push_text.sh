#!/bin/bash
# Pin /setup Step 2b first-push text from AgDR-0252.
# The skill is markdown. This test does not run the prompts.
# It checks the operator-command contract the agent must follow.
#
# Exit 0 on all-pass, 1 on any fail.

set -u

ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
SKILL="$ROOT/.claude/skills/setup/SKILL.md"
RULES="$ROOT/.claude/rules/git-conventions.md"
AGDR="$ROOT/docs/agdr/AgDR-0252-portfolio-first-push.md"

for f in "$SKILL" "$RULES" "$AGDR"; do
  if [ ! -f "$f" ]; then
    echo "FAIL: missing $f" >&2
    exit 1
  fi
done

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }

PASS=0
FAIL=0
FAILED_CASES=""

mark_pass() { green "  ok   $1"; PASS=$((PASS + 1)); }
mark_fail() {
  red "  FAIL $1: $2" >&2
  FAIL=$((FAIL + 1))
  FAILED_CASES="$FAILED_CASES\n  - $1"
}

need() {
  if printf '%s\n' "$2" | grep -qF -- "$1"; then
    mark_pass "$3"
  else
    mark_fail "$3" "missing text"
  fi
}

need_file() {
  if grep -qF -- "$1" "$2"; then
    mark_pass "$3"
  else
    mark_fail "$3" "missing text"
  fi
}

absent() {
  if printf '%s\n' "$2" | grep -qF -- "$1"; then
    mark_fail "$3" "found forbidden text"
  else
    mark_pass "$3"
  fi
}

STEP=$(awk '/^### Step 2b:/{p=1} /^### Step 2c:/{p=0} p' "$SKILL")
if [ -z "$STEP" ]; then
  echo "FAIL: Step 2b section not found" >&2
  exit 1
fi

FENCES=$(printf '%s\n' "$STEP" | awk '
  /^[[:space:]]*```bash[[:space:]]*$/ { on = 1; next }
  /^[[:space:]]*```[[:space:]]*$/ { on = 0; next }
  on { print }
')
TEXT=$(printf '%s\n' "$STEP" | awk '
  /^[[:space:]]*```text[[:space:]]*$/ { on = 1; next }
  /^[[:space:]]*```[[:space:]]*$/ { on = 0; next }
  on { print }
')
ASK=$(printf '%s\n' "$STEP" | awk '
  /^[[:space:]]*\*\*Ask the operator\.\*\*/ { on = 1 }
  /^[[:space:]]*\*\*Verify on "Done"\.\*\*/ { on = 0 }
  on { print }
')

echo "== Step 2b pins the operator first push"

need 'Before item 4, run `git rev-parse --show-toplevel`' "$STEP" "fork root is recorded before item 4"
need 'git -C "<fork-root>/../<name>" rev-parse --show-toplevel' "$STEP" "absolute path comes from rev-parse"
need 'C:/dir' "$STEP" "printed path uses the C:/dir form"
need 'PowerShell' "$STEP" "plain form names PowerShell"

fork_line=$(printf '%s\n' "$STEP" | grep -n 'Before item 4, run `git rev-parse --show-toplevel`' | head -1 | cut -d: -f1)
clone_line=$(printf '%s\n' "$STEP" | grep -n 'gh repo clone' | head -1 | cut -d: -f1)
if [ -n "$fork_line" ] && [ -n "$clone_line" ] && [ "$fork_line" -lt "$clone_line" ]; then
  mark_pass "fork-root sentence precedes the clone command"
else
  mark_fail "fork-root order" "fork line=$fork_line clone line=$clone_line"
fi

need 'git -C "<abs-path>" add -- apexyard.projects.yaml projects/.gitkeep workspace/.gitkeep' "$FENCES" "stage command names the first seed files"
need 'onboarding.yaml custom-skills/README.md custom-handbooks/README.md agent-routing.yaml .gitignore' "$FENCES" "stage command names the remaining seed files"
absent 'git add -A' "$FENCES" "bash fences do not run git add -A"
absent 'git add .' "$FENCES" "bash fences do not run git add ."
absent 'git add --all' "$FENCES" "bash fences do not run git add --all"
need 'Never run `git add -A`' "$STEP" "skill forbids git add -A"

need '! git -C "<abs-path>" commit -m "chore: initialise portfolio" && git -C "<abs-path>" push -u origin HEAD' "$TEXT" "Claude Code form uses ! and &&"
need 'In any other harness, run these two commands in a terminal. Run the second command only when the first one succeeds.' "$STEP" "other-harness note is present"
need 'git -C "<abs-path>" commit -m "chore: initialise portfolio"' "$TEXT" "terminal form has the commit line"
need 'git -C "<abs-path>" push -u origin HEAD' "$TEXT" "terminal form has the push line"
absent 'git commit' "$FENCES" "bash fences do not run git commit"
absent 'git push' "$FENCES" "bash fences do not run git push"
need 'push -u origin HEAD' "$STEP" "push uses origin HEAD"
need 'symbolic-ref --short HEAD' "$FENCES" "branch comes from symbolic-ref"
absent 'initial commit + push' "$STEP" "old initial-commit bullet is gone"

need 'Done' "$ASK" "AskUserQuestion includes Done"
need 'Commit or push failed (paste the error)' "$ASK" "AskUserQuestion includes the failure option"
need 'Stop here' "$ASK" "AskUserQuestion includes Stop here"
need 'numbered list' "$ASK" "prose fallback is a numbered list"
done_line=$(printf '%s\n' "$ASK" | grep -n '"Done"' | head -1 | cut -d: -f1)
fail_line=$(printf '%s\n' "$ASK" | grep -n 'Commit or push failed (paste the error)' | head -1 | cut -d: -f1)
stop_line=$(printf '%s\n' "$ASK" | grep -n '"Stop here"' | head -1 | cut -d: -f1)
if [ -n "$done_line" ] && [ -n "$fail_line" ] && [ -n "$stop_line" ] \
  && [ "$done_line" -lt "$fail_line" ] && [ "$fail_line" -lt "$stop_line" ]; then
  mark_pass "AskUserQuestion options stay in order"
else
  mark_fail "option order" "done=$done_line fail=$fail_line stop=$stop_line"
fi

need 'awk -v r="refs/heads/$BR" '\''$2 == r { print $1 }'\' "$FENCES" "verify compares the ref name exactly"
need 'gh api "repos/<owner>/<name>/branches/$BR"' "$FENCES" "verify reads the forge branch SHA"
need 'Do not pass `--heads`' "$STEP" "skill forbids ls-remote --heads"
need 'Do not pass `--branches`' "$STEP" "skill forbids ls-remote --branches"
absent '--heads' "$FENCES" "verify command has no --heads"
absent '--branches' "$FENCES" "verify command has no --branches"
need 'Never suggest `--no-verify`' "$STEP" "skill never suggests --no-verify"
absent '--no-verify' "$FENCES" "printed commands are not in bash fences with --no-verify"
absent '--force' "$FENCES" "bash fences add no force option"
absent '--no-verify' "$TEXT" "text fences have no --no-verify"
absent '--force' "$TEXT" "text fences have no --force"
need ' || FORGE=""' "$FENCES" "a missing branch leaves FORGE empty"
need_file ' || FORGE=""' "$AGDR" "AgDR rule 8 leaves FORGE empty on a missing branch"
need 'FORGE_ERR=$(mktemp)' "$FENCES" "verify captures gh api stderr in a temp file"
need '2>"$FORGE_ERR"' "$FENCES" "verify redirects gh api stderr to FORGE_ERR"
need 'When `FORGE` is empty, show the contents of `$FORGE_ERR`' "$STEP" "empty FORGE shows the gh api stderr"
need 'rm -f "$FORGE_ERR"' "$STEP" "empty FORGE removes the FORGE_ERR temp file"
need 'HTTP 404, or "Branch not found"' "$STEP" "failure table has the branch-absent forge row"
need 'HTTP 401 or 403, or "auth" in the error' "$STEP" "failure table has the authentication forge row"
need 'network or other error' "$STEP" "failure table has the network-or-other forge row"
need_file 'FORGE_ERR=$(mktemp)' "$AGDR" "AgDR rule 8 captures gh api stderr"
need_file 'rm -f "$FORGE_ERR"' "$AGDR" "AgDR rule 8 removes the FORGE_ERR temp file"
need_file 'Note (2026-10-19, #1782)' "$AGDR" "AgDR rule 8 records the #1782 note"
need_file 'Note (2026-10-19, #1792)' "$AGDR" "AgDR rule 8 records the #1792 note"
need 'Record `<owner>` and `<name>` when the operator confirms the name.' "$STEP" "name confirmation records owner and name"
need 'The reuse path skips item 3 and still uses this pair.' "$STEP" "reuse path keeps the recorded pair"
need '`<owner>/<name>` is the recorded pair.' "$STEP" "verify uses the recorded pair"
record_line=$(printf '%s\n' "$STEP" | grep -n 'Record `<owner>` and `<name>` when the operator confirms the name.' | head -1 | cut -d: -f1)
item3_line=$(printf '%s\n' "$STEP" | grep -n 'Create the private repo' | head -1 | cut -d: -f1)
forge_line=$(printf '%s\n' "$STEP" | grep -nF 'FORGE=$(gh api' | head -1 | cut -d: -f1)
if [ -n "$record_line" ] && [ -n "$item3_line" ] && [ -n "$forge_line" ] \
  && [ "$record_line" -lt "$item3_line" ] && [ "$item3_line" -lt "$forge_line" ]; then
  mark_pass "reuse path records owner and name before verify"
else
  mark_fail "record order" "record=$record_line item3=$item3_line forge=$forge_line"
fi

need 'Reuse `<owner>/<name>`' "$STEP" "resume asks the operator to confirm reuse"
need 'gh api repos/<owner>/<name>/contents/apexyard.projects.yaml' "$STEP" "resume stops a non-empty repo without the registry file"
need 'is not a portfolio repo' "$STEP" "resume reports a non-portfolio repo"
need 'ls-tree -r --name-only HEAD' "$STEP" "resume checks the eight seed paths with ls-tree"
need 'Do not offer a force push' "$STEP" "resume does not offer a force push"
need 'Do not change any hook' "$STEP" "skill states that no hook changes"

echo "== No Direct Main names the one operator action"
RULE=$(awk '/^## No Direct Main$/{p=1} /^## No Hardcoded Secrets$/{p=0} p' "$RULES")
need 'One operator action is the only exception.' "$RULE" "amendment states the one exception"
need 'The operator makes the initial commit and push of the new, empty portfolio repository that `/setup` Step 2b creates.' "$RULE" "amendment names the operator action"
need 'An agent never makes that commit or that push, and the gates still block it.' "$RULE" "amendment keeps the gates"
need 'No commits directly to `main`/`master`.' "$RULE" "rest of the paragraph stays"
absent 'Zero exceptions.' "$RULE" "zero-exceptions sentence is replaced"

echo "== AgDR-0252 is the accepted record"
need_file 'id: AgDR-0252' "$AGDR" "frontmatter id is AgDR-0252"
need_file 'status: accepted' "$AGDR" "status is accepted"
need_file '# AgDR-0252: Initial commit and push of a new split-portfolio repository' "$AGDR" "title carries the number"
need_file '## Decisions recorded' "$AGDR" "decisions recorded section stays"
if grep -qF '## Review response' "$AGDR"; then
  mark_fail "review-response section is removed" "found forbidden text"
else
  mark_pass "review-response section is removed"
fi
need_file '## Context' "$AGDR" "Context section stays"
need_file '## Options Considered' "$AGDR" "Options Considered section stays"
need_file '## Decision' "$AGDR" "Decision section stays"
need_file '## Consequences' "$AGDR" "Consequences section stays"
need_file '## Artifacts' "$AGDR" "Artifacts section stays"

echo
echo "===== test_setup_first_push_text.sh ====="
echo "Passed: $PASS"
echo "Failed: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf 'Failed cases:%b\n' "$FAILED_CASES"
  exit 1
fi
exit 0
