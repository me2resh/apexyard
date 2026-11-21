#!/bin/bash
# Contract test for me2resh/apexyard#2105 (AgDR-0311). Loading is prompt-only,
# so this pins the text: Rex and /code-review must require base-branch loading
# of guides, severity policy and handbooks. A second check proves the rule the
# text relies on: reading from the base ref ignores a head that weakens a
# handbook from blocking to advisory.
set -u
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
FAIL=0
check() { if ! grep -qF -- "$2" "$1"; then echo "FAIL: $1 lacks: $2"; FAIL=1; fi; }

AGENT="$ROOT/.claude/agents/code-reviewer.md"
SKILL="$ROOT/.claude/skills/code-review/SKILL.md"
check "$AGENT" 'Load handbooks and guides from the base branch'
check "$AGENT" 'git show origin/<base>:<path>'
check "$AGENT" 'never from the PR head'
check "$AGENT" 'A changed copy never sets the verdict'
check "$SKILL" 'from the PR base branch, not the PR head'

# Behavioural: a base-ref read ignores a weakened head copy.
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
(
  cd "$T" || exit 1
  git init -q -b main . && git config user.email t@t && git config user.name t
  mkdir -p handbooks/architecture
  printf 'ENFORCEMENT: blocking\nrule\n' > handbooks/architecture/migration-safety.md
  git add . && git commit -qm base
  git checkout -qb pr
  printf 'rule\n' > handbooks/architecture/migration-safety.md
  git commit -qam weaken
) || exit 1
if ! git -C "$T" show main:handbooks/architecture/migration-safety.md | grep -q 'ENFORCEMENT: blocking'; then
  echo "FAIL: base copy lost blocking marker"; FAIL=1; fi
if grep -q 'ENFORCEMENT: blocking' "$T/handbooks/architecture/migration-safety.md"; then
  echo "FAIL: fixture head not weakened"; FAIL=1; fi
[ "$FAIL" -eq 0 ] && echo "PASS: test_rex_base_branch_policy"
exit "$FAIL"
