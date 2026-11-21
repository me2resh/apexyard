"""Exercise reliability selection with complete unified diffs."""
import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[4]
LOADER = ROOT / '.claude/skills/code-review/reliability-triggers.sh'
os.environ.pop('CLAUDE_CODE_SESSION_ID', None)
os.environ.pop('APEXYARD_SESSION_ID', None)
os.environ['APEXYARD_OPS_DISABLE_PIN'] = '1'
os.environ['APEXYARD_DISABLE_RESOLUTION_CACHE'] = '1'


def diff(path, added='ordinary change', removed='ordinary value', context=''):
    return (f'diff --git a/{path} b/{path}\n--- a/{path}\n+++ b/{path}\n'
            f'@@ -1,2 +1,2 @@\n {context}\n-{removed}\n+{added}\n')


class ReliabilityTests(unittest.TestCase):
    def run_loader(self, patch, loader=LOADER, cwd=ROOT):
        result = subprocess.run(['bash', str(loader)], input=patch, text=True,
                                capture_output=True, cwd=cwd)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def test_seed_triggers(self):
        cases = [
            ('src/database.py', 'SCHEMA_VERSION = 2', 'Local schema version'),
            ('src/store.ts', 'const field = cachedRecord.newField', 'Cache compatibility'),
            ('.audit-ignore.json', '"GHSA-abcd-1234-5678"', 'Audit ignore entries'),
            ('.github/workflows/deploy.yml', 'runs-on: ubuntu-latest', 'Deployment isolation'),
            ('src/content.ts', 'const isPublished = true', 'Content flag outputs'),
        ]
        for path, line, title in cases:
            with self.subTest(title=title):
                output = self.run_loader(diff(path, line))
                self.assertIn('## ' + title + '\n', output)
                self.assertEqual(output.count('Trigger:'), 1)
                self.assertIn('Check:', output)
                self.assertIn('Source:', output)

    def test_unrelated_and_context_only(self):
        self.assertEqual(self.run_loader(diff('README.md')), '')
        self.assertEqual(self.run_loader(diff('src/store.py', context='cached = cache.get(key)')), '')
        self.assertEqual(self.run_loader(diff('src/ui.tsx', 'visible = enabled && !disabled')), '')
        self.assertEqual(self.run_loader(''), '')

    def test_removed_lines(self):
        self.assertIn('Local schema version', self.run_loader(
            diff('src/db.py', removed='PRAGMA user_version = 1')))

    def test_patch_headers_and_rename(self):
        patch = diff('src/db.py', removed='-- schema_version = 1')
        self.assertIn('Local schema version', self.run_loader(patch))
        rename = ('diff --git a/.github/workflows/deploy.yml b/.github/workflows/release.yml\n'
                  'similarity index 100%\nrename from .github/workflows/deploy.yml\n'
                  'rename to .github/workflows/release.yml\n')
        self.assertIn('Deployment isolation', self.run_loader(rename))

    def test_rename_with_spaces_and_quotes(self):
        names = [
            ('.github/workflows/old deploy.yml', '.github/workflows/new deploy.yml'),
            ('.github/workflows/it\'s deploy.yml', '.github/workflows/its deploy.yml'),
            ('.github/workflows/deploy.yml', '.github/workflows/it\'s.yml'),
        ]
        for old, new in names:
            with self.subTest(old=old, new=new):
                rename = (f'diff --git a/{old} b/{new}\nsimilarity index 100%\n'
                          f'rename from {old}\nrename to {new}\n')
                self.assertIn('Deployment isolation', self.run_loader(rename))
        quoted = ('diff --git "a/.github/workflows/it\'s deploy.yml" b/.github/workflows/its.yml\n'
                  'similarity index 100%\nrename from ".github/workflows/it\'s deploy.yml"\n'
                  'rename to .github/workflows/its.yml\n')
        self.assertIn('Deployment isolation', self.run_loader(quoted))
        binary = 'diff --git a/.github/workflows/my deploy.yml b/.github/workflows/my deploy.yml\nBinary files differ\n'
        self.assertIn('Deployment isolation', self.run_loader(binary))
        quoted_binary = ('diff --git "a/.github/workflows/caf\\303\\251 deploy.yml" '
                         '"b/.github/workflows/caf\\303\\251 deploy.yml"\nBinary files differ\n')
        self.assertIn('Deployment isolation', self.run_loader(quoted_binary))
        copy = ('diff --git a/x.txt b/.github/workflows/a deploy.yml\nsimilarity index 100%\n'
                'copy from x.txt\ncopy to .github/workflows/a deploy.yml\n')
        self.assertIn('Deployment isolation', self.run_loader(copy))

    def make_root(self, directory):
        root = pathlib.Path(directory)
        script = root / LOADER.relative_to(ROOT)
        script.parent.mkdir(parents=True)
        shutil.copy(LOADER, script)
        shutil.copy(LOADER.with_name('reliability_triggers.py'), script.with_name('reliability_triggers.py'))
        shutil.copytree(ROOT / '.claude/hooks', root / '.claude/hooks',
                        ignore=shutil.ignore_patterns('tests', '__pycache__'))
        shutil.copytree(ROOT / 'handbooks/architecture', root / 'handbooks/architecture')
        (root / 'onboarding.yaml').touch()
        (root / 'apexyard.projects.yaml').touch()
        subprocess.run(['git', 'init', '-q', str(root)], check=True)
        private = root / 'custom-handbooks/architecture/reliability-team.md'
        private.parent.mkdir(parents=True)
        return script, private

    def test_private_layer_from_other_directory(self):
        item = ('## Private check\nTrigger: path: src/custom/*\n'
                'Check: Verify compatibility.\nSource: Incident 42.\n')
        with tempfile.TemporaryDirectory() as directory, tempfile.TemporaryDirectory() as other:
            script, private = self.make_root(directory)
            private.write_text(item)
            for cwd in (other, pathlib.Path(directory) / 'handbooks', '/'):
                with self.subTest(cwd=str(cwd)):
                    self.assertIn('## Private check',
                                  self.run_loader(diff('src/custom/a.py'), script, cwd))

    def test_missing_private_layer_warns(self):
        with tempfile.TemporaryDirectory() as directory:
            script, private = self.make_root(directory)
            shutil.rmtree(private.parents[1])
            result = subprocess.run(['bash', str(script)], input=diff('README.md'), text=True,
                                    capture_output=True, cwd=directory)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('private handbook layer not found', result.stderr)

    def test_malformed_adopter_items_fail(self):
        good = 'Check: Verify compatibility.\nSource: Incident 42.\n'
        shapes = {
            'bold labels': '## Item one\n**Trigger:** path: src/custom/*\n' + good,
            'list bullets': '## Item one\n- Trigger: path: src/custom/*\n' + good,
            'two items under one heading': '## Group\n### Item one\nTrigger: path: src/custom/*\n' + good
                + '### Item two\nTrigger: path: src/*\n' + good,
            'repeated field': '## Item one\nTrigger: path: a/*\nTrigger: path: b/*\n' + good,
            'empty regex': '## Item one\nTrigger: regex: ``\n' + good,
            'empty path': '## Item one\nTrigger: path: \n' + good,
            'no items': '# Notes\nNothing here.\n',
        }
        for name, text in shapes.items():
            with self.subTest(shape=name), tempfile.TemporaryDirectory() as directory:
                script, private = self.make_root(directory)
                private.write_text(text)
                result = subprocess.run(['bash', str(script)], input=diff('src/custom/a.py'),
                                        text=True, capture_output=True, cwd=directory)
                if name == 'two items under one heading':
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(result.stdout.count('Trigger:'), 2)
                    continue
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('reliability-team.md', result.stderr)
                self.assertEqual(result.stdout, '')

    def test_diff_file_argument(self):
        with tempfile.NamedTemporaryFile(mode='w') as patch:
            patch.write(diff('src/db.py', 'schema_version = 2'))
            patch.flush()
            result = subprocess.run(['bash', str(LOADER), patch.name],
                                    capture_output=True, text=True, cwd=ROOT)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('Local schema version', result.stdout)

    def test_adopter_layers_and_invalid_regex(self):
        with tempfile.TemporaryDirectory() as directory:
            script, private = self.make_root(directory)
            root = pathlib.Path(directory)
            public = root / 'handbooks/architecture/reliability-adopter.md'
            item = ('## Adopter check\nTrigger: path: src/custom/*\n'
                    'Check: Verify compatibility.\nSource: Incident 42.\n')
            public.write_text(item)
            private.write_text('---\nowner: example\n---\nENFORCEMENT: blocking\n'
                               + item.replace('Adopter check', 'Private check'))
            output = self.run_loader(diff('src/custom/handler.py'), script, root)
            self.assertIn('## Adopter check', output)
            self.assertIn('## Private check', output)
            self.assertIn('Enforcement: blocking', output)
            self.assertEqual(output.count('Trigger:'), 2)
            combined = self.run_loader(diff('src/custom/handler.py', 'schema_version = 2'), script, root)
            self.assertIn('Local schema version', combined)
            self.assertIn('Adopter check', combined)
            public.write_text(item.replace('path: src/custom/*', 'regex: ['))
            result = subprocess.run(['bash', str(script)], input='', text=True,
                                    capture_output=True, cwd=root)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('invalid regex', result.stderr)
            self.assertEqual(result.stdout, '')


if __name__ == '__main__':
    unittest.main(verbosity=2)
