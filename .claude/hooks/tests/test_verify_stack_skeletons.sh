#!/usr/bin/env bash
# Check the four per-stack verify skeletons and their adoption and review wiring.
set -euo pipefail

# Isolate from live session pins and caches.
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"

ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
python3 - "$ROOT" <<'PY'
import pathlib
import sys

root = pathlib.Path(sys.argv[1])

stacks = ('web', 'mobile', 'desktop', 'service')
for stack in stacks:
    skeleton = root / f'templates/skills/verify/{stack}.md'
    assert skeleton.is_file(), f'Missing {stack} skeleton'
    body = skeleton.read_text()
    for heading in ('## Start the app', '## Drive the main flows', '## Print evidence'):
        assert heading in body, f'{stack}.md is missing {heading}'
    assert 'controlled technical writing profile' in body, f'{stack}.md is missing the writing profile line'
print('PASS: four stack skeletons exist with start, drive, and evidence steps')

template = (root / 'templates/skills/verify/SKILL.md').read_text()
for stack in stacks:
    assert f'templates/skills/verify/{stack}.md' in template, f'Template does not reference {stack}.md'
print('PASS: the shared template references all four stack skeletons')

for name in ('handover', 'scaffold'):
    skill = (root / f'.claude/skills/{name}/SKILL.md').read_text()
    start = skill.index('Offer a project verify skill')
    offer = skill[start:]
    next_section = offer.find('\n## ', 1)
    if next_section >= 0:
        offer = offer[:next_section]
    for stack in stacks:
        assert f'{stack}.md' in offer, f'{name} does not reference {stack}.md'
    print(f'PASS: {name} references the four stack skeletons')

for agent in ('backend-engineer', 'frontend-engineer', 'platform-engineer'):
    body = (root / f'.claude/agents/{agent}.md').read_text()
    assert '## Verify before a PR' in body, f'{agent} is missing the verify-before-a-PR section'
    assert '.claude/rules/agent-role-selection.md' in body, f'{agent} does not point at the verify rule'
    assert 'Verify could not run' in body, f'{agent} does not state the could-not-run case'
print('PASS: backend, frontend, and platform engineer briefs carry the verify rule')

builder = (root / '.claude/rules/agent-role-selection.md').read_text()
assert 'Before opening a PR, run' in builder
assert 'Paste the evidence into the PR body' in builder

code_review_skill = (root / '.claude/skills/code-review/SKILL.md').read_text()
assert "Read the PR's verify evidence first." in code_review_skill
assert 'Report missing evidence.' in code_review_skill

rex = (root / '.claude/agents/code-reviewer.md').read_text()
assert "Read the PR's verify evidence first." in rex
assert 'Report missing evidence' in rex
print('PASS: Rex and the code-review skill read verify evidence first')
PY
