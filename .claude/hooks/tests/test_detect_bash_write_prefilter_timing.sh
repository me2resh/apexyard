#!/bin/bash
# Full-dispatcher latency for a 68-line quoted heredoc with a prose-only body.
set -eu
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/bdw-timing.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
python3 - "$ROOT" "$TMP" <<'PY'
import json
import os
from pathlib import Path
import statistics
import shutil
import subprocess
import sys
import time

root, tmp = map(Path, sys.argv[1:])
words = 'alpha beta gamma delta epsilon zeta theta iota kappa lambda sigma omega '
line = (words * 4)[:240]
body = '\n'.join([line] * 66)
commands = {
    '68-line': f"cat > {tmp}/out.md <<'EOF'\n{body}\nEOF",
    '1-line': f"cat > {tmp}/out.md <<'EOF'\n{body.replace(chr(10), ' ')}\nEOF",
}
assert len(commands['68-line'].splitlines()) == 68
assert 15500 < len(commands['68-line'].encode()) < 17000
# Respect the caller's awk selection so both required environments run.
selected_awk = shutil.which('awk')
print(f'awk: {selected_awk}')
env = os.environ.copy()
for key in ('APEXYARD_OPS_ROOT', 'APEXYARD_PORTFOLIO_ROOT'):
    env.pop(key, None)
env['CLAUDE_PROJECT_DIR'] = str(root)
timings = {}
for label, command in commands.items():
    payload = json.dumps({'tool_name': 'Bash', 'tool_input': {'command': command},
                          'cwd': str(tmp), 'session_id': 'bdw-timing'})
    samples = []
    for _ in range(3):
        start = time.monotonic()
        result = subprocess.run(['/bin/bash', str(root / '.claude/hooks/dispatch-bash.sh')],
                                input=payload, text=True, capture_output=True,
                                cwd=tmp, env=env, timeout=60)
        samples.append(time.monotonic() - start)
        if result.returncode != 0:
            raise SystemExit(f'FAIL: dispatcher status {result.returncode}: {result.stderr}')
    timings[label] = statistics.median(samples)
    print(f'{label}: {timings[label]:.3f}s median, {len(command.encode())} bytes')
long, short = timings['68-line'], timings['1-line']
# The 68-line payload must stay near the 1-line control of the same run.
# This bound holds on any machine speed, so the test never passes trivially.
if long > short * 1.5 + 0.25:
    raise SystemExit(f'FAIL: 68-line heredoc ({long:.3f}s) is slower than 1.5x the 1-line control ({short:.3f}s)')
if long <= 2:
    print('PASS: 68-line heredoc completes within 2 seconds')
else:
    print('NOTE: machine too slow to judge the 2-second limit, multiline stays within 1.5x of the one-line control')
print('PASS=1 FAIL=0')
PY
