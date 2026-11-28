#!/usr/bin/env bash
# Static contract checks for GH-2149. These checks do not evaluate model behavior.
set -u
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../../.." && pwd)
python3 - "$ROOT" <<'PY'
from pathlib import Path
import re
import sys
root = Path(sys.argv[1])
p = root / '.claude/skills/approach/SKILL.md'
s = p.read_text() if p.exists() else ''
t = (root / '.github/PULL_REQUEST_TEMPLATE.md').read_text()
checks = {
    'Heavy-only refusal': 'Lean or Standard: use the PR-body Approach section. /approach runs only for Heavy changes.' in s,
    'writing rule first': bool(re.search(r'## Step 1:.*\n\nRead `.claude/rules/writing-standard.md`', s)),
    'writing checklist last': s.rstrip().endswith('Fix each failure before you report completion.'),
    'framework profile': 'controlled technical writing profile' in s,
    'no unsupported diagram or writing standard': bool(s) and not re.search(r'architecture-beta|STE100', s),
    'flowchart classes and subgraphs': all(x in s for x in ['flowchart', 'subgraph', 'classDef new', 'classDef changed']),
    'infrastructure diagram row': '| Infrastructure or CI |' in s,
    'dirty-tree refusal': 'Refused: this working tree holds uncommitted changes for another ticket.' in s,
    'merged-PR refusal': 'Refused: PR <ref> is already merged.' in s,
    'explicit repo in every gh example': bool(re.findall(r'^gh [^\n`]+', s, re.M)) and all('--repo' in x for x in re.findall(r'^gh [^\n`]+', s, re.M)),
    'output path': 'docs/technical-designs/<ticket>-<slug>-technical-design.md' in s,
    'Standard PR section': all(x in t for x in ['## Approach', '### Delta', '### Decisions', '### Verification', 'no project standard']),
    'all change types': all(x in s for x in ['| Database or schema |', '| New pattern |', '| New or retired vendor or dependency |', '| New integration |', '| New feature |', '| Auth, permissions or secrets |', '| Public API or contract |']),
    'vague ticket asks first': 'first question' in s and 'Which change types apply' in s,
    'diagram scope and lint': all(x in s for x in ['plus one hop', 'not verified', 'Sources:', '_lib-mermaid-lint.sh']),
    'required document sections': all('## ' + x in s for x in ['Context', 'Current state', 'Future state', 'Delta', 'Vision fit', 'Key decisions', 'NFRs and risks', 'Delivery slices', 'Verification', 'Open questions']),
    'conditional sections': 'Include Data and migration only' in s and 'Include Integrations only' in s,
    'grounding and absent owner': all(x in s for x in ['not checked', 'open tickets', 'absent owner', 'Open questions', '/decide', '/design-review']),
    'skill byte and description budgets': bool(s) and len(s.encode()) <= 16000 and len(re.search(r'^description: (.*)$', s, re.M).group(1)) <= 120,
}
for label, ok in checks.items():
    print(('PASS: ' if ok else 'FAIL: ') + label)
sys.exit(not all(checks.values()))
PY
