#!/usr/bin/env bash
# Exercise the trusted script against real git ranges and forged inputs.
set -euo pipefail
# shellcheck source=./_test-session-isolation.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
python3 - "$ROOT" <<'PY'
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest

SCRIPT = Path(sys.argv[1]) / 'bin/review-tier.sh'


class TierTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.repo = self.root / 'repo'
        self.repo.mkdir()
        self.git('init', '-q')
        self.git('config', 'user.email', 'test@example.invalid')
        self.git('config', 'user.name', 'Test')
        self.write('bin/review-tier.sh', SCRIPT.read_text())
        self.write('docs/guide.md', 'before\n')
        self.write('docs/other.md', 'before\n')
        self.write('.claude/agents/rex.md', 'Read docs/prompt.md and docs/named/.\n')
        self.write('.claude/hooks/gate.sh', '# gate\n')
        self.commit()
        self.base = self.git('rev-parse', 'HEAD').strip()
        # Export from the base. The working-tree script is never executed.
        self.trusted = self.root / 'trusted.sh'
        self.trusted.write_text(self.git('show', self.base + ':bin/review-tier.sh'))

    def git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.repo), *args], text=True,
                                       stderr=subprocess.DEVNULL)

    def write(self, name, body):
        p = self.repo / name
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(body)

    def commit(self):
        # Fixture-only repository. Enumerate its files for staging.
        names = [str(p.relative_to(self.repo)) for p in self.repo.rglob('*')
                 if p.is_file() and '.git' not in p.relative_to(self.repo).parts]
        self.git('add', '--', *names)
        self.git('add', '-u')
        self.git('commit', '-qm', 'fixture')
        return self.git('rev-parse', 'HEAD').strip()

    def tier(self, head=None, env=None, base=None, cwd=None):
        head = head or self.git('rev-parse', 'HEAD').strip()
        out = subprocess.check_output(['bash', str(self.trusted), str(self.repo),
                                       base or self.base, head], text=True, env=env,
                                      cwd=cwd)
        return json.loads(out)

    def test_plain_markdown_allowed(self):
        self.write('docs/guide.md', 'after\n')
        self.commit()
        out = self.tier()
        self.assertEqual(out['depth'], 'Reduced-scope-allowed')
        self.assertEqual(out['base_sha'], self.base)
        self.assertEqual(out['reviewed_sha'], self.git('rev-parse', 'HEAD').strip())

    def test_image_allowed(self):
        self.write('docs/image.png', 'image fixture\n')
        self.commit()
        self.assertEqual(self.tier()['depth'], 'Reduced-scope-allowed')

    def test_forbidden_extensions(self):
        for name in ('data.json', 'data.yaml', 'data.yml', 'run.sh', 'app.py', 'deps.lock', 'a.svg'):
            with self.subTest(name=name):
                self.write('docs/' + name, 'text\n')
                self.commit()
                self.assertEqual(self.tier()['depth'], 'Full')

    def test_prompt_references(self):
        for name in ('docs/prompt.md', 'docs/named/example.md', 'docs/agdr/decision.md'):
            with self.subTest(name=name):
                self.write(name, 'text\n')
                self.commit()
                self.assertEqual(self.tier()['depth'], 'Full')

    def test_script_edited_in_pr(self):
        self.write('bin/review-tier.sh', 'echo forged\n')
        self.commit()
        self.assertEqual(self.tier()['depth'], 'Full')

    def test_hook_renamed_to_docs(self):
        self.git('mv', '.claude/hooks/gate.sh', 'docs/gate.md')
        self.commit()
        out = self.tier()
        self.assertEqual(out['depth'], 'Full')
        self.assertIn('.claude/hooks/gate.sh', out['paths'])
        self.assertIn('docs/gate.md', out['paths'])

    def test_copy_lists_source(self):
        shutil.copyfile(self.repo / '.claude/hooks/gate.sh', self.repo / 'docs/gate.md')
        self.commit()
        out = self.tier()
        self.assertEqual(out['depth'], 'Full')
        self.assertIn('.claude/hooks/gate.sh', out['paths'])
        self.assertIn('docs/gate.md', out['paths'])

    def test_push_after_tier_time(self):
        self.write('docs/guide.md', 'after\n')
        old = self.commit()
        self.assertEqual(self.tier(old)['depth'], 'Reduced-scope-allowed')
        self.write('docs/new.json', '{}\n')
        self.commit()
        self.assertEqual(self.tier(old)['depth'], 'Full')

    def test_full_range_not_last_commit(self):
        self.write('docs/unsafe.json', '{}\n')
        self.commit()
        self.write('docs/guide.md', 'after\n')
        self.commit()
        self.assertEqual(self.tier()['depth'], 'Full')

    def shim(self, action):
        bindir = self.root / 'shim'
        if bindir.exists():
            shutil.rmtree(bindir)
        bindir.mkdir()
        real = shutil.which('git')
        shim = bindir / 'git'
        shim.write_text('#!/usr/bin/env python3\nimport os,subprocess,sys\n'
                        'args=sys.argv[1:]\n'
                        f'out=subprocess.check_output([{real!r}]+args)\n'
                        'if "--name-status" in args:\n'
                        f' {action}\n'
                        'sys.stdout.buffer.write(out)\n')
        shim.chmod(0o755)
        return dict(os.environ, PATH=str(bindir) + os.pathsep + os.environ['PATH'])

    def test_truncated_list(self):
        self.write('docs/guide.md', 'after\n')
        self.commit()
        self.assertEqual(self.tier(env=self.shim('out=out[:-1]'))['depth'], 'Full')

    def test_truncated_at_record_boundary(self):
        self.write('docs/guide.md', 'after\n')
        self.write('docs/other.md', 'after\n')
        self.commit()
        env = self.shim('out=b"\\0".join(out.split(b"\\0")[:2])+b"\\0"')
        self.assertEqual(self.tier(env=env)['depth'], 'Full')

    def test_head_changes_during_check(self):
        self.write('docs/guide.md', 'after\n')
        self.commit()
        real = shutil.which('git')
        action = f'subprocess.check_call([{real!r}, "-C", {str(self.repo)!r}, "update-ref", "HEAD", {self.base!r}])'
        self.assertEqual(self.tier(env=self.shim(action))['depth'], 'Full')

    def test_document_rename_lists_both_paths(self):
        self.git('mv', 'docs/guide.md', 'docs/renamed.md')
        self.commit()
        out = self.tier()
        self.assertEqual(out['depth'], 'Reduced-scope-allowed')
        self.assertEqual(out['paths'], ['docs/guide.md', 'docs/renamed.md'])

    def test_git_error(self):
        self.write('docs/guide.md', 'after\n')
        self.commit()
        self.assertEqual(self.tier(env=self.shim('sys.exit(7)'))['depth'], 'Full')

    def test_invalid_base(self):
        self.assertEqual(self.tier(base='0' * 40)['depth'], 'Full')

    def test_empty_diff(self):
        self.assertEqual(self.tier()['depth'], 'Full')

    def test_symlink(self):
        (self.repo / 'docs/link.md').symlink_to('../bin/review-tier.sh')
        self.commit()
        self.assertEqual(self.tier()['depth'], 'Full')

    def test_planted_stdlib_shadow_from_repo_cwd(self):
        # A PR-planted json.py / re.py must not run when cwd is the PR tree.
        self.write('docs/guide.md', 'after\n')
        self.write('json.py',
                   'def dumps(d, **k):\n'
                   '    return \'{"depth":"Reduced-scope-allowed","reason":"FORGED by json.py"}\'\n'
                   'open(__file__ + ".ran", "w").write("ran\\n")\n')
        self.write('re.py',
                   'def fullmatch(*a, **k):\n'
                   '    raise AssertionError("planted re used")\n'
                   'open(__file__ + ".ran", "w").write("ran\\n")\n')
        self.commit()
        out = self.tier(cwd=str(self.repo))
        self.assertEqual(out['depth'], 'Full')
        self.assertNotEqual(out.get('reason'), 'FORGED by json.py')
        self.assertFalse((self.repo / 'json.py.ran').exists())
        self.assertFalse((self.repo / 're.py.ran').exists())

    def test_pythonpath_stdlib_shadow(self):
        self.write('docs/guide.md', 'after\n')
        self.commit()
        pp = self.root / 'pp'
        pp.mkdir()
        (pp / 'json.py').write_text(
            'def dumps(d, **k):\n'
            '    return \'{"depth":"Reduced-scope-allowed","reason":"PYTHONPATH"}\'\n'
            'open(__file__ + ".ran", "w").write("ran\\n")\n')
        env = dict(os.environ, PYTHONPATH=str(pp))
        out = self.tier(env=env, cwd=str(self.repo))
        self.assertEqual(out['depth'], 'Reduced-scope-allowed')
        self.assertNotEqual(out.get('reason'), 'PYTHONPATH')
        self.assertFalse((pp / 'json.py.ran').exists())

    def test_planted_subprocess_shadow(self):
        # PYTHONPATH keeps the plant reachable when -I is removed but cwd is neutral.
        self.write('docs/guide.md', 'after\n')
        self.write('subprocess.py',
                   'open(__file__ + ".ran", "w").write("ran\\n")\n'
                   'raise AssertionError("planted subprocess used")\n')
        self.commit()
        env = dict(os.environ, PYTHONPATH=str(self.repo))
        out = self.tier(env=env, cwd=str(self.repo))
        self.assertEqual(out['depth'], 'Full')
        self.assertFalse((self.repo / 'subprocess.py.ran').exists())

    def test_planted_sitecustomize(self):
        self.write('docs/guide.md', 'after\n')
        self.write('sitecustomize.py',
                   'open(__file__ + ".ran", "w").write("ran\\n")\n')
        self.commit()
        env = dict(os.environ, PYTHONPATH=str(self.repo))
        out = self.tier(env=env, cwd=str(self.repo))
        self.assertEqual(out['depth'], 'Full')
        self.assertFalse((self.repo / 'sitecustomize.py.ran').exists())

    def test_planted_pth_under_pythonuserbase(self):
        self.write('docs/guide.md', 'after\n')
        userbase = self.repo / 'userbase'
        userbase.mkdir()
        # Layout differs by Python (lib/pythonX.Y vs lib/python). Ask this
        # interpreter which path PYTHONUSERBASE maps to.
        site = Path(subprocess.check_output(
            [sys.executable, '-c', 'import site; print(site.getusersitepackages())'],
            text=True, env=dict(os.environ, PYTHONUSERBASE=str(userbase))).strip())
        site.mkdir(parents=True)
        marker = self.root / 'pth.ran'
        (site / 'evil.pth').write_text(
            f'import pathlib; pathlib.Path({str(marker)!r}).write_text("ran\\n")\n')
        self.commit()
        env = dict(os.environ, PYTHONUSERBASE=str(userbase))
        out = self.tier(env=env, cwd=str(self.repo))
        self.assertEqual(out['depth'], 'Full')
        self.assertFalse(marker.exists())

    def test_int_term_trap_exits_nonzero(self):
        # Signal the whole session so bash and its children see INT/TERM together.
        # A bash-only signal stays deferred until the foreground child exits.
        self.write('docs/guide.md', 'after\n')
        self.commit()
        head = self.git('rev-parse', 'HEAD').strip()
        for sig in (signal.SIGINT, signal.SIGTERM):
            with self.subTest(sig=sig):
                env = self.shim('import time; time.sleep(30)')
                proc = subprocess.Popen(
                    ['bash', str(self.trusted), str(self.repo), self.base, head],
                    env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                    start_new_session=True)
                deadline = time.time() + 5
                while time.time() < deadline:
                    if proc.poll() is None:
                        break
                    time.sleep(0.05)
                else:
                    self.fail('tier exited before the git shim sleep')
                time.sleep(0.3)
                self.assertIsNone(proc.poll(), 'tier should still be waiting on git')
                os.killpg(proc.pid, sig)
                self.assertNotEqual(proc.wait(timeout=5), 0)


unittest.main(argv=['review-tier'], verbosity=2)
PY
