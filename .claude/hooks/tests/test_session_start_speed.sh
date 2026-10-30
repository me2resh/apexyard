#!/bin/bash
# Bash 3.2 regression coverage for the advisory cache and startup budget.
set -euo pipefail
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" CLAUDE_CODE_SESSION_ID=gh1927-test
mkdir -p "$TMP/repo/.claude/hooks" "$TMP/repo/bin" "$HOME"
cp "$ROOT/.claude/hooks/dispatch-session-start.sh" "$TMP/repo/.claude/hooks/"
for name in $(sed -n 's/^# APEXYARD_SESSION_START_HOOK: //p' "$ROOT/.claude/hooks/dispatch-session-start.sh"); do
  printf '#!/bin/bash\nexit 0\n' > "$TMP/repo/.claude/hooks/$name"
  chmod +x "$TMP/repo/.claude/hooks/$name"
done
cp "$ROOT/.claude/hooks/check-upstream-drift.sh" "$ROOT/.claude/hooks/_lib-adapter-check-cache.sh" "$ROOT/.claude/hooks/_lib-gh-timeout.sh" "$TMP/repo/.claude/hooks/"
cat > "$TMP/repo/bin/sync-codex-adapter.sh" <<'STUB'
#!/bin/bash
printf 'called\n' >> calls
if [ -f drift ]; then
  echo 'DRIFT: .codex/hooks.json differs from generated output' >&2
  exit 1
fi
STUB
cd "$TMP/repo"
git init -q
mkdir -p .claude/skills .claude/agents .codex
printf '{}\n' > .claude/settings.json
run() { bash .claude/hooks/check-upstream-drift.sh > "$TMP/out" 2> "$TMP/err"; }
count() { [ "$(wc -l < calls | tr -d ' ')" = "$1" ]; }
run; count 1
run; count 1
echo changed > .claude/skills/new
run; count 2
printf '{}\n' > .codex/hooks.json
run; count 3
printf 'broken\n' > .claude/session/codex-adapter-check
run; count 4
rm .claude/session/codex-adapter-check
touch drift
run; count 5
grep -q '^DRIFT: .codex/hooks.json differs from generated output$' "$TMP/err"
cp "$TMP/err" "$TMP/expected"
run; count 5
cmp "$TMP/err" "$TMP/expected"
# Warm dispatcher: actual cache hook, isolated no-op housekeeping hooks.
SECONDS=0
bash .claude/hooks/dispatch-session-start.sh <<<'{"source":"startup"}' > "$TMP/out" 2> "$TMP/err"
[ "$SECONDS" -lt 5 ]
count 5
grep -q '^DRIFT: .codex/hooks.json differs from generated output$' "$TMP/err"
# The generator itself is an input. Transient errors must never become hits.
echo '# generator changed' >> bin/sync-codex-adapter.sh
run; count 6
rm drift
printf '#!/bin/bash\nprintf "called\\n" >> calls\nexit 2\n' > bin/sync-codex-adapter.sh
run; count 7
run; count 8
# Execute the snapshot's actual argv against a configured Git fixture.
SNAPSHOT_ROOT="$ROOT" python3 - <<'PYTEST'
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

with tempfile.TemporaryDirectory() as fixture:
    def git(*args):
        return subprocess.check_output(['git', '-C', fixture, *args], text=True)
    git('init', '-q')
    path = Path(fixture, 'docs/orbit/plans/p.json')
    path.parent.mkdir(parents=True)
    path.write_text('{"id":"p"}\n')
    git('add', 'docs/orbit/plans/p.json')
    git('-c', 'user.name=Test', '-c', 'user.email=test@example.com', 'commit', '-qm', 'fixture')
    git('update-ref', 'refs/remotes/origin/dev', 'HEAD')
    for key, value in [('grep.lineNumber', 'true'), ('grep.column', 'true'),
                       ('grep.fullName', 'false'), ('color.grep', 'always')]:
        git('config', key, value)
    source = Path(os.environ['SNAPSHOT_ROOT'], 'plugins/apexyard-status/hooks/register.tsx').read_text()
    argv = re.search(r"runProcess\(\$, (\['git', '-C', clone,.*?\])", source).group(1)
    argv = argv.replace('clone', json.dumps(fixture)).replace('`origin/${ref}`', '"origin/dev"')
    argv = json.loads(argv.replace("'", '"'))
    output = subprocess.check_output(argv, text=True)
    assert output == 'origin/dev:docs/orbit/plans/p.json:{"id":"p"}\n', output
PYTEST
# Refuse both existing and dangling cache symlinks without replacing them.
printf '#!/bin/bash\nprintf "called\\n" >> calls\n' > bin/sync-codex-adapter.sh
for target in "$TMP/cache-target" "$TMP/missing-target"; do
  rm -f .claude/session/codex-adapter-check
  if [ "$target" = "$TMP/cache-target" ]; then echo sentinel > "$target"; fi
  ln -s "$target" .claude/session/codex-adapter-check
  run
  [ -L .claude/session/codex-adapter-check ]
  [ -z "$(find .claude/session -name 'adapter-check.*' -print)" ]
done
[ "$(cat "$TMP/cache-target")" = sentinel ]
[ ! -e "$TMP/missing-target" ]
rm .claude/session/codex-adapter-check
printf '#!/bin/bash\nprintf "called\\n" >> calls\nexit 2\n' > bin/sync-codex-adapter.sh
# Bound a stalled fetch without timeout(1), using a local git stub.
git -c user.name=Test -c user.email=test@example.com commit --allow-empty -qm base
git branch -M main
git tag v1.0.0
git -c user.name=Test -c user.email=test@example.com commit --allow-empty -qm release
git tag v1.1.0
git update-ref refs/remotes/upstream/main HEAD
git reset --hard -q v1.0.0
REAL_GIT=$(command -v git)
export REAL_GIT
mkdir stubs
cat > stubs/git <<'STUB'
#!/bin/bash
case "$1" in
  remote) echo upstream ;;
  fetch) exec sleep 20 ;;
  *) exec "$REAL_GIT" "$@" ;;
esac
STUB
chmod +x stubs/git
SECONDS=0
PATH="$PWD/stubs:$PATH" run
[ "$SECONDS" -ge 3 ] && [ "$SECONDS" -lt 6 ]
grep -q '^ApexYard: v1.1.0 available. Run /update to sync.$' "$TMP/out"
[ ! -e .claude/session/last-upstream-fetch ]
# Parent output symlinks must not hide the generator's safety diagnostics.
printf '#!/bin/bash\nprintf "called\\n" >> calls\n' > bin/sync-codex-adapter.sh
run; count 12
run; count 12
mkdir -p "$TMP/agents-target/skills"
ln -s "$TMP/agents-target" .agents
run; count 13
run; count 14
echo 'PASS: cache invalidation, broken cache, error retry, drift replay, warm dispatcher budget, portable fetch timeout, symlink safety'
