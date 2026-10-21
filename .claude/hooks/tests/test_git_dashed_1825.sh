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
    # Round 1 classes: a name that quote removal, a glob, a brace or an
    # expansion forms. Each class has a block case and a data-text allow twin.
    splits = {'push': ('pu""sh', 'pu\\sh', "pu''sh", 'pu[s]h', 'pus?', 'pus*', 'pu{sh,}'),
              'commit': ('com""mit', 'com\\mit', 'com[m]it', 'comm?t', 'com{mit,}')}
    for verb, forms in splits.items():
        for i, form in enumerate(forms):
            check('split-%s-%d' % (verb, i), '{}/git-{}'.format(execpath, form), 2)
            check('split-quoted-%s-%d' % (verb, i), '"$(git --exec-path)"/git-' + form, 2)
        check('case-' + verb, '{}/GIT-{}'.format(execpath, verb.upper()), 2)
        check('prefix-expansion-' + verb, 'v=' + verb + '; "$(git --exec-path)/git-$v"', 2)
        check('braced-expansion-' + verb, 'v=' + verb + '; "${GIT_EXEC_PATH}/git-${v}"', 2)
        check('quoted-prefix-' + verb, '"{}/git-"{}'.format(execpath, verb), 2)
        check('exec-path-then-expansion-' + verb, '"$(git --exec-path)/$(echo git-' + verb + ')"', 2)
        check('exec-path-then-glob-' + verb, '"$(git --exec-path)"/*' + verb[-3:], 2)
        check('backtick-delimiter-' + verb, '`' + execpath + '/git-' + verb + '`', 2)
        check('wrapped-assign-' + verb, 'X=1 env -i ' + execpath + '/git-' + verb, 2)
        check('wrapped-redirect-' + verb, '>/dev/null ' + execpath + '/git-' + verb, 2)
        check('after-pipe-' + verb, 'echo hi | ' + execpath + '/git-' + verb, 2)
    # Allow twins: plain names that only share the prefix stay allowed.
    for name in ('git-status', 'git-log', 'git-lfs', 'git-push-helper', 'git-commit-tree'):
        check('twin-prefix-' + name, '"' + execpath + '/' + name + '"', 0)
    # B1: text that only names the program is data, not a command.
    for label, command in (
        ('man', 'man git-push'),
        ('search', "grep -rn 'git-commit' ."),
        ('echo', 'echo git-push'),
        ('echo-quoted', 'echo "run git-commit later"'),
        ('log-grep', 'git log --grep=git-push'),
        ('heredoc', "cat <<'EOT'\nRun git-push to publish.\nEOT"),
        ('commit-message', 'git commit -m "docs(#1825): explain the git-push program"'),
        ('path-arg', 'cat docs/git-push.md'),
        ('printf', "printf '%s\\n' git-commit"),
    ):
        check('data-' + label, command, 0)
    # No-jq path: the dispatcher cannot parse the payload. It blocks the
    # dashed name and the dashed prefix with a special character, and it
    # allows plain text with no dashed name.
    nojq = base / 'nojq'
    nojq.mkdir()
    for d in os.environ['PATH'].split(':'):
        if not os.path.isdir(d):
            continue
        for n in os.listdir(d):
            f = os.path.join(d, n)
            link = nojq / n
            if n != 'jq' and os.access(f, os.X_OK) and not os.path.lexists(link):
                os.symlink(f, link)
    def check_nojq(label, command, want):
        payload = json.dumps({'tool_name': 'Bash', 'cwd': str(repo),
                              'tool_input': {'command': command}})
        nenv = dict(env, PATH=str(nojq))
        result = subprocess.run(['/bin/bash', str(hooks / 'dispatch-bash.sh')],
                                input=payload, env=nenv, cwd=repo, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        ok = result.returncode == want
        counts[not ok] += 1
        print(('PASS' if ok else 'FAIL'), 'nojq-' + label, flush=True)
        if not ok:
            print('expected', want, 'got', result.returncode, result.stdout, result.stderr)
    check_nojq('plain-push', execpath + '/git-push', 2)
    check_nojq('plain-commit', 'git-commit -m x', 2)
    check_nojq('split', execpath + '/git-pu""sh', 2)
    check_nojq('glob', execpath + '/git-pus*', 2)
    check_nojq('expansion', '"$(git --exec-path)/git-$v"', 2)
    check_nojq('allow-status', 'ls -l', 0)
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
