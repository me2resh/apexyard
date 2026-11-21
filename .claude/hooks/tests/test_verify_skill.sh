#!/usr/bin/env bash
# Check the verify template and its prompt-driven adoption contracts.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
python3 - "$ROOT" <<'PY'
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
template_path = root / 'templates/skills/verify/SKILL.md'
assert template_path.is_file(), 'Missing verify template'
template = template_path.read_text()
for stack in ('Web', 'Mobile', 'Desktop', 'Service'):
    assert f'### {stack}' in template, f'Missing {stack} instructions'
for field in ('name: verify', '## Evidence for the PR', 'Commands run:',
              'Flows exercised:', 'Artifacts:', 'Unverified criteria',
              'Verify could not run', 'Unresolved setup fields block verification.'):
    assert field in template, f'Missing template contract: {field}'
print('PASS: template covers four stacks, runtime evidence, and blockers')

for name in ('handover', 'scaffold'):
    skill = (root / f'.claude/skills/{name}/SKILL.md').read_text()
    start = skill.index('Offer a project verify skill')
    offer = skill[start:]
    next_section = offer.find('\n## ', 1)
    if next_section >= 0:
        offer = offer[:next_section]
    for field in ('templates/skills/verify/SKILL.md', '.claude/skills/verify/SKILL.md',
                  'AskUserQuestion', 'Skip', 'existing `.claude/skills/verify/`',
                  'Do not claim the skeleton works until verify runs successfully.'):
        assert field in offer, f'{name} lacks adoption contract: {field}'
    if name == 'handover':
        assert '/start-ticket' in offer, 'Handover must retain ticket governance'
        assert 'does not extend handover' in offer, 'Handover must retain bootstrap limits'
    print(f'PASS: {name} offers a scoped copy and preserves existing skills')

builder = (root / '.claude/rules/agent-role-selection.md').read_text()
assert 'Before opening a PR, run' in builder
assert 'Paste the evidence into the PR body' in builder
assert 'Verify could not run' in builder
rex = (root / '.claude/agents/code-reviewer.md').read_text()
assert "Read the PR's verify evidence first." in rex
assert 'Report missing evidence' in rex
reference = (root / '.claude/skills/verify/SKILL.md').read_text()
assert '.claude/hooks/tests/test_verify_skill.sh' in reference
assert '.claude/skills/handover/tests/test_topology_pick.sh' in reference
print('PASS: builder, reviewer, and framework reference contracts')
PY
