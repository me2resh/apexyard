import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True

source = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location('writer', source / '.claude/hooks/lib/rule-excludes.py')
writer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(writer)


def git(root, *args):
    return subprocess.run(['git', '-C', str(root), *args], check=True, capture_output=True)


with tempfile.TemporaryDirectory() as temporary:
    base = Path(temporary).resolve()
    home = base / 'home'
    home.mkdir()
    root = base / 'ops [x]*?{a}(b)!+@ spaced'
    root.mkdir()
    git(root, 'init', '-q')
    (root / '.apexyard-fork').touch()
    hooks = root / '.claude/hooks'
    hooks.mkdir(parents=True)
    for name in ['write-rule-excludes.sh', '_lib-ops-root.sh']:
        shutil.copy2(source / '.claude/hooks' / name, hooks / name)
    shutil.copytree(source / '.claude/hooks/lib', hooks / 'lib')
    (root / '.gitignore').write_text('.claude/settings.local.json\n')
    target = root / '.claude/settings.local.json'
    env = dict(os.environ, HOME=str(home), APEXYARD_OPS_DISABLE_PIN='1')
    env.pop('CLAUDE_CODE_SESSION_ID', None)

    def run(cwd=None, environment=None):
        result = subprocess.run(['bash', str(hooks / 'write-rule-excludes.sh')], cwd=cwd or root,
                                env=environment or env, capture_output=True, text=True)
        assert result.returncode == 0, result.stderr
        return result

    # 1, 2: Preserve every unrelated byte, including number/string spellings.
    original = b'{\n "permissions" : { "allow" : ["Bash(ls)"] }, "hooks": {},\n "env": {"N":1e2}, "apiKeyHelper": "helper", "other": "\\u0061"\n}\n'
    target.write_bytes(original)
    target.chmod(0o640)
    result = run()
    assert len(result.stdout.splitlines()) == 1 and not result.stderr
    updated = target.read_bytes()
    assert updated[:original.index(b'}\n', original.index(b'"other"'))] == original[:-2]
    assert target.stat().st_mode & 0o777 == 0o640
    assert {k: v for k, v in json.loads(updated).items() if k != 'claudeMdExcludes'} == json.loads(original)
    # 3, 12: Metacharacters escaped, realpath anchored, personal/project eligible.
    pattern = json.loads(updated)['claudeMdExcludes'][0]
    assert pattern == writer.escape_root(str(root)) + writer.SUFFIX
    assert writer.matches(pattern, str(root / '.claude/rules/test.md'))
    assert not writer.matches(pattern, str(root / 'workspace/app/.claude/rules/test.md'))
    assert not writer.matches(pattern, str(home / '.claude/rules/test.md'))
    # 4: Deny list rejects broad patterns, including hooks and personal memory.
    assert writer.safe_pattern(pattern, str(root), str(home))
    for denied in ['**', '**/CLAUDE.md', '**/AGENTS.md', '**/.claude/hooks/*', '**/.claude/settings.json']:
        assert not writer.safe_pattern(denied, str(root), str(home)), denied
    # Protected instructions reached through a symlink must also remain visible.
    (root / '.claude/rules').mkdir()
    (root / '.claude/rules/linked-memory.md').touch()
    (root / 'CLAUDE.md').symlink_to(root / '.claude/rules/linked-memory.md')
    saved = target.read_bytes()
    assert not writer.safe_pattern(pattern, str(root), str(home))
    assert len(run().stderr.splitlines()) == 1 and target.read_bytes() == saved
    (root / 'CLAUDE.md').unlink()
    # 5: Shared broad exclude removed.
    assert 'claudeMdExcludes' not in json.loads((source / '.claude/settings.json').read_bytes())
    # 6, 12: Second run preserves inode, mtime and bytes.
    before = target.stat()
    assert not run().stdout
    assert target.read_bytes() == updated
    assert target.stat().st_ino == before.st_ino and target.stat().st_mtime_ns == before.st_mtime_ns
    # 12: Symlink clone uses the real path.
    link = base / 'linked'
    link.symlink_to(root, target_is_directory=True)
    assert not run(link).stdout
    # 6: Rename replaces exactly the reserved writer signature, retaining user entries.
    existing = json.loads(updated)
    existing['claudeMdExcludes'].extend(['**/user-only.md', 'relative/.claude/rules/**'])
    target.write_text(json.dumps(existing))
    renamed = base / 'renamed'
    root.rename(renamed)
    root = renamed
    hooks = root / '.claude/hooks'
    target = root / '.claude/settings.local.json'
    assert run().stdout
    entries = json.loads(target.read_bytes())['claudeMdExcludes']
    assert entries == ['**/user-only.md', 'relative/.claude/rules/**', str(root) + writer.SUFFIX]
    # 7: Nested project and unrelated cwd with a valid pin both write ops settings.
    project = root / 'workspace/app'
    project.mkdir(parents=True)
    git(project, 'init', '-q')
    assert not run(project).stdout
    assert not (project / '.claude/settings.local.json').exists()
    pins = base / 'pins'
    pins.mkdir()
    (pins / 'ops-root-test').write_text(str(root) + '\n')
    pinned = dict(env, CLAUDE_CODE_SESSION_ID='test', APEXYARD_OPS_PIN_DIR=str(pins))
    pinned.pop('APEXYARD_OPS_DISABLE_PIN')
    assert not run(home, pinned).stdout
    # 9, 12: Invalid JSON and symlink targets fail open with one warning, no edits.
    for invalid in [b'{broken', b'[]', b'{"env":1,"env":2}', b'{"claudeMdExcludes":false}']:
        target.write_bytes(invalid)
        result = run()
        assert len(result.stderr.splitlines()) == 1 and not result.stdout
        assert target.read_bytes() == invalid
    target.unlink()
    external = base / 'external.json'
    external.write_text('{}')
    target.symlink_to(external)
    assert len(run().stderr.splitlines()) == 1
    assert external.read_text() == '{}'
    target.unlink()
    # 10: Wide user exclusions remain; one advisory identifies excluded rules.
    personal = home / '.claude/rules'
    personal.mkdir(parents=True)
    (personal / 'personal.md').touch()
    (home / '.claude/settings.json').write_text('{"claudeMdExcludes":["**/.claude/rules/**"]}')
    result = run()
    assert len(result.stdout.splitlines()) == 2 and 'advisory' in result.stdout
    assert 'claudeMdExcludes' in json.loads(target.read_bytes())
    assert 'advisory' in run().stdout
    # Linked worktree settings stay in that worktree, despite governance normalization.
    git(root, 'add', '.apexyard-fork', '.gitignore')
    git(root, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
        'commit', '-qm', 'test fixture')
    worktree = base / 'worktree'
    git(root, 'worktree', 'add', '-q', '-b', 'fixture', str(worktree))
    shutil.copytree(hooks, worktree / '.claude/hooks')
    worktree_target = worktree / '.claude/settings.local.json'
    result = subprocess.run(['bash', str(worktree / '.claude/hooks/write-rule-excludes.sh')],
                            cwd=worktree, env=env, capture_output=True, text=True)
    assert result.returncode == 0 and not result.stderr
    assert json.loads(worktree_target.read_bytes())['claudeMdExcludes'] == [str(worktree) + writer.SUFFIX]
    # A literal backslash cannot survive Claude Code's path normalization.
    try:
        writer.escape_root('/ops/back\\slash')
    except ValueError:
        pass
    else:
        raise AssertionError('backslash root must fail open')
    # 8: Setup and dispatcher share the writer; timing gap remains explicit.
    assert 'write-rule-excludes.sh' in (source / '.claude/skills/setup/SKILL.md').read_text()
    assert '  write-rule-excludes.sh' in (source / '.claude/hooks/dispatch-session-start.sh').read_text()
    assert 'first-session gap' in (source / 'docs/agdr/AgDR-0233-rule-excludes-per-clone.md').read_text()
    # 11: Non-ignored or tracked local settings refused.
    (root / '.gitignore').write_text('')
    saved = target.read_bytes()
    assert len(run().stderr.splitlines()) == 1 and target.read_bytes() == saved
    (root / '.gitignore').write_text('.claude/settings.local.json\n')
    git(root, 'add', '-f', '.claude/settings.local.json')
    assert len(run().stderr.splitlines()) == 1 and target.read_bytes() == saved
    print('PASS: requirements 1–12 (load-order limitation documented separately).')
