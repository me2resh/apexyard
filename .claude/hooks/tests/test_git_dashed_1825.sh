#!/bin/bash
# Protected dashed programs and opaque shell targets (#1825).
set -eu
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../../.." && pwd)"
export ROOT
python3 - <<'PY'
import json
import os
import pathlib
import subprocess
import tempfile

root = pathlib.Path(os.environ['ROOT'])
hooks = root / '.claude/hooks'
counts = [0, 0]
with tempfile.TemporaryDirectory(prefix='dashed-1825-') as scratch:
    base = pathlib.Path(scratch)
    home = base / 'home'
    home.mkdir()
    repo = base / 'repo'
    repo.mkdir()
    env = {k: v for k, v in os.environ.items() if not k.startswith('GIT_')}
    env.update(HOME=str(home), GIT_CONFIG_GLOBAL=str(home / 'config'),
               GIT_CONFIG_NOSYSTEM='1')
    def git(*args):
        return subprocess.check_output(['git', '-C', str(repo), *args], env=env, text=True).strip()
    git('init', '-q')
    git('config', 'user.name', 'Test')
    git('config', 'user.email', 'test@example.invalid')
    git('checkout', '-qb', 'feature/GH-1825-test')
    for verb in ('push', 'commit'):
        git('config', 'alias.probe-' + verb, verb)
    execpath = git('--exec-path')
    def check(label, command, want):
        payload = json.dumps({'tool_name': 'Bash', 'cwd': str(repo),
                              'tool_input': {'command': command}})
        for hook in ('dispatch-bash', 'block-main-push', 'validate-commit-format'):
            result = subprocess.run(['/bin/bash', str(hooks / (hook + '.sh'))],
                                    input=payload, env=env, cwd=repo, text=True,
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            ok = result.returncode == want
            counts[not ok] += 1
            print(('PASS' if ok else 'FAIL'), label, hook, flush=True)
            if not ok:
                print('expected', want, 'got', result.returncode, result.stdout, result.stderr)
    # Build the command text from placeholders. Never run these commands.
    program = 'git-{verb}'
    for verb in ('push', 'commit'):
        name = program.format(verb=verb)
        for label, template in (
            ('absolute', '{path}/{name}'),
            ('quoted', '"{path}/{name}"'),
            ('substitution', '"$(git --exec-path)/{name}"'),
            ('variable', 'p=$(git --exec-path); "$p/{name}"'),
            ('braced', 'p=$(git --exec-path); "${{p}}/{name}"'),
            ('backtick', '"`git --exec-path`/{name}"'),
            ('bare', '{name}'),
        ):
            check(label + '-' + verb, template.format(path=execpath, name=name), 2)
    for name in ('git-status', 'git-log', 'git-push-helper', 'widget-git-commit'):
        check('read-or-unrelated-' + name, '"' + execpath + '/' + name + '"', 0)
    check('unrelated-path', str(base / 'git-push-helper'), 0)
    check('any-leading-path-push', str(base / 'git-push'), 2)
    check('any-leading-path-commit', '"' + str(base) + '/git-commit"', 2)
    shapes = (
        ('separate-option', 'bash -o posix -c "{body}"'),
        ('quoted-shell', "'bash' -c \"{body}\""),
        ('quoted-path-shell', "'/bin/bash' -c \"{body}\""),
        ('eval', 'eval "{body}"'),
        ('quoted-eval', "'eval' \"{body}\""),
    )
    for label, template in shapes:
        for verb in ('push', 'commit'):
            # Unknown aliases in an opaque execution context must fail closed.
            alias = 'probe-' + verb
            body = 'git ' + alias
            check(label + '-' + verb, template.format(body=body), 2)
        check(label + '-read', template.format(body='git status'), 0)
print('TOTAL', counts[0], 'passed,', counts[1], 'failed')
raise SystemExit(bool(counts[1]))
PY
