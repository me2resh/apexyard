import json
import os
from pathlib import Path
import shutil
import runpy
from unittest.mock import patch
import subprocess
import sys
import tempfile

source = Path(__file__).resolve().parents[3]

with tempfile.TemporaryDirectory() as temporary:
    base = Path(temporary).resolve()
    root = base / 'ops'
    home = base / 'home'
    portfolio = base / 'portfolio spaced'
    for directory in (root, home, portfolio):
        directory.mkdir()
    (portfolio / 'apexyard.projects.yaml').write_text('projects: []\n')
    subprocess.run(['git', 'init', '-q', str(root)], check=True)
    (root / '.apexyard-fork').touch()
    (root / '.gitignore').write_text('.claude/settings.local.json\n.claude/session/\n')
    hooks = root / '.claude/hooks'
    hooks.mkdir(parents=True)
    for name in ('write-rule-excludes.sh', '_lib-ops-root.sh', '_lib-portfolio-paths.sh', '_lib-read-config.sh'):
        shutil.copy2(source / '.claude/hooks' / name, hooks / name)
    shutil.copytree(source / '.claude/hooks/lib', hooks / 'lib')
    (root / '.claude/project-config.defaults.json').write_text('{}')
    config = root / '.claude/project-config.json'
    target = root / '.claude/settings.local.json'
    env = dict(os.environ, HOME=str(home), APEXYARD_OPS_DISABLE_PIN='1',
               APEXYARD_DISABLE_RESOLUTION_CACHE='1')
    env.pop('CLAUDE_CODE_SESSION_ID', None)
    env.pop('APEXYARD_DISABLE_PORTFOLIO_PERMISSIONS', None)

    def run(disabled=False):
        environment = dict(env)
        if disabled:
            environment['APEXYARD_DISABLE_PORTFOLIO_PERMISSIONS'] = '1'
        result = subprocess.run(['bash', str(hooks / 'write-rule-excludes.sh')],
                                cwd=root, env=environment, capture_output=True, text=True)
        assert result.returncode == 0, result.stderr
        return result

    def configure(path):
        config.write_text(json.dumps({'portfolio': {'registry': str(path) + '/apexyard.projects.yaml'}}))

    # Single-fork adds no permissions, including when the file is absent.
    config.write_text('{}')
    assert not run().stderr
    assert 'permissions' not in json.loads(target.read_bytes())
    baseline = target.read_bytes()
    assert not run().stdout and target.read_bytes() == baseline
    # Preserve unrelated lexical bytes and every existing entry.
    original = baseline[:-2] + b', "permissions" : {"allow":["Read"], "additionalDirectories" : ["/user/one", "../two"], "other":1e2}, "env":{"X":"\\u0061"}}\n'
    target.write_bytes(original)
    configure(portfolio)
    assert not run(True).stdout and target.read_bytes() == original
    result = run()
    assert not result.stderr and 'effective next session' in result.stdout
    updated = target.read_bytes()
    assert updated == original.replace(b'["/user/one", "../two"]',
                                      json.dumps(['/user/one', '../two', str(portfolio)]).encode())
    before = target.stat()
    assert not run().stdout and target.read_bytes() == updated
    assert target.stat().st_ino == before.st_ino and target.stat().st_mtime_ns == before.st_mtime_ns
    # Missing permissions and missing additionalDirectories are both added.
    for initial in (baseline, baseline[:-2] + b',"permissions":{"allow":["Read"]}}\n'):
        target.write_bytes(initial)
        assert not run().stderr
        assert json.loads(target.read_bytes())['permissions']['additionalDirectories'] == [str(portfolio)]
    # Invalid roots warn once and leave settings byte-identical.
    file_root = base / 'file'
    file_root.touch()
    linked = base / 'linked'
    linked.symlink_to(portfolio, target_is_directory=True)
    for invalid in (base / 'missing', file_root, linked, home, Path('/'), base):
        configure(invalid)
        saved = target.read_bytes()
        result = run()
        assert len(result.stderr.splitlines()) == 1, (invalid, result.stderr)
        assert not result.stdout and target.read_bytes() == saved, invalid
    # Each unsafe home location has a valid registry, isolating path checks.
    personal = home / '.claude'
    descendant = personal / 'nested'
    home_parent = base / 'home-parent'
    alternate_home = home_parent / 'user'
    for directory in (personal, descendant, alternate_home):
        directory.mkdir(parents=True, exist_ok=True)
    for invalid in (personal, descendant, home_parent):
        (invalid / 'apexyard.projects.yaml').write_text('projects: []\n')
        configure(invalid)
        environment = dict(env, HOME=str(alternate_home) if invalid == home_parent else str(home))
        saved = target.read_bytes()
        result = subprocess.run(['bash', str(hooks / 'write-rule-excludes.sh')],
                                cwd=root, env=environment, capture_output=True, text=True)
        assert result.returncode == 0 and len(result.stderr.splitlines()) == 1
        assert target.read_bytes() == saved
    # Empty HOME must refuse instead of resolving the current directory.
    configure(portfolio)
    result = subprocess.run(['python3', str(hooks / 'lib/rule-excludes.py'),
                             '--portfolio-permissions', str(root), '', str(portfolio)],
                            capture_output=True, text=True)
    assert result.returncode != 0 and 'missing home directory' in result.stderr
    assert target.read_bytes() == saved
    # A real directory needs a regular registry with a top-level projects key.
    registry = portfolio / 'apexyard.projects.yaml'
    for content in (None, 'other: []\n', 'nested:\n  projects: []\n'):
        registry.unlink()
        if content is not None:
            registry.write_text(content)
        saved = target.read_bytes()
        assert len(run().stderr.splitlines()) == 1 and target.read_bytes() == saved
        if content is None:
            registry.touch()
    registry.unlink()
    registry.symlink_to(personal / 'apexyard.projects.yaml')
    assert len(run().stderr.splitlines()) == 1 and target.read_bytes() == saved
    registry.unlink()
    registry.mkdir()
    assert len(run().stderr.splitlines()) == 1 and target.read_bytes() == saved
    registry.rmdir()
    registry.write_text('projects: []\n')
    # A symlink in an ancestor is also rejected.
    nested = portfolio / 'nested'
    nested.mkdir()
    configure(linked / 'nested')
    assert len(run().stderr.splitlines()) == 1
    # Unsafe settings are refused by the shared read helper.
    configure(portfolio)
    for invalid in (b'{"permissions":false}', b'{"permissions":{"additionalDirectories":false}}',
                    b'{"permissions":{"allow":[],"allow":[]}}'):
        invalid = baseline[:-2] + b',' + invalid[1:]
        target.write_bytes(invalid)
        result = run()
        assert result.stderr and target.read_bytes() == invalid
    # Refuse malformed splice output before replacing settings.
    writer = runpy.run_path(str(hooks / 'lib/rule-excludes.py'))
    target.write_bytes(baseline)
    with patch.dict(writer['portfolio_permissions'].__globals__,
                    splice_member=lambda *args: '{',
                    replace_safe=lambda *args: (_ for _ in ()).throw(AssertionError('write attempted'))):
        try:
            writer['portfolio_permissions'](str(root), str(home), str(portfolio))
        except json.JSONDecodeError:
            pass
        else:
            raise AssertionError('invalid edited JSON accepted')
    assert target.read_bytes() == baseline
    # Relative config paths resolve from the main checkout in both worktrees.
    configure('../portfolio spaced')
    target.write_bytes(baseline)
    assert not run().stderr
    expected = json.loads(target.read_bytes())['permissions']['additionalDirectories']
    assert expected == [str(portfolio)]
    subprocess.run(['git', '-C', str(root), 'add', '.apexyard-fork', '.gitignore',
                    '.claude/hooks', '.claude/project-config.defaults.json',
                    '.claude/project-config.json'], check=True)
    subprocess.run(['git', '-C', str(root), '-c', 'user.name=Test', '-c',
                    'user.email=test@example.invalid', '-c', 'core.hooksPath=/dev/null',
                    'commit', '-qm', 'fixture'], check=True)
    linked_root = base / 'worktrees' / 'linked-ops'
    subprocess.run(['git', '-C', str(root), 'worktree', 'add', '-q', '-b',
                    'linked-test', str(linked_root)], check=True)
    linked_target = linked_root / '.claude/settings.local.json'
    result = subprocess.run(['bash', str(linked_root / '.claude/hooks/write-rule-excludes.sh')],
                            cwd=linked_root, env=env, capture_output=True, text=True)
    assert result.returncode == 0 and not result.stderr, result.stderr
    assert json.loads(linked_target.read_bytes())['permissions']['additionalDirectories'] == expected
    # Both lifecycle callers use this same writer, after split configuration in setup.
    setup = (source / '.claude/skills/setup/SKILL.md').read_text()
    assert setup.count('bash .claude/hooks/write-rule-excludes.sh') >= 2
    assert '  write-rule-excludes.sh' in (source / '.claude/hooks/dispatch-session-start.sh').read_text()
    print('PASS: portfolio add, preservation, idempotency, single-fork, opt-out, invalid paths, and lifecycle wiring')
