"""Adapter conversion and repository evidence regression tests."""

import json
from pathlib import Path
import subprocess
import tempfile
import unittest

from common import cli


class AdapterTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name)
        def git(*args):
            return subprocess.check_output(['git', '-C', str(self.repo)] + list(args),
                                           stderr=subprocess.DEVNULL).decode().strip()
        git('init', '-q')
        git('config', 'user.name', 'Test')
        git('config', 'user.email', 'test@example.test')
        (self.repo / 'source.txt').write_text('source\n')
        git('add', 'source.txt')
        git('commit', '-qm', 'fixture')
        self.commit = git('rev-parse', 'HEAD')

    def run_adapter(self, name, text):
        path = self.repo / 'input'
        path.write_text(text)
        return cli(name, path, '--repo-dir', self.repo, '--commit', self.commit)

    def test_dfd(self):
        data = dict(project='Sample', actors=[dict(id='user', name='User', type='human')],
                    processes=[dict(id='api', name='API', evidence='./source.txt:1')],
                    stores=[], flows=[dict(source='user', target='api', payload_hint='Request')],
                    boundaries=[dict(id='backend', name='Backend', contains=['api'])],
                    classifications=[dict(element='api', label='PII', evidence='./source.txt:1')])
        result = self.run_adapter('from-dfd', json.dumps(data))
        self.assertEqual(result.returncode, 0, result.stderr)
        model = json.loads(result.stdout)
        self.assertEqual(model['nodes'][1]['tags'], ['pii'])
        self.assertEqual(model['nodes'][1]['group'], 'backend')
        self.assertEqual(model['edges'][0]['label'], 'Request')
        self.check_model(result.stdout)
        data['flows'][0]['target'] = 'missing'
        self.assert_failure('from-dfd', json.dumps(data), b'E_EDGE_UNKNOWN_NODE')
        data['flows'][0]['target'] = 'api'
        data['processes'][0]['evidence'] = '../outside:1'
        self.assert_failure('from-dfd', json.dumps(data), b'E_SOURCE_PATH')

    def test_tsv(self):
        header = 'kind\tname\tfile\tline\tfrom\tto\tlabel\n'
        rows = 'route\tPOST /reset-password\tsource.txt\t1\t\t\t\n'
        rows += 'screen\tReset-password\tsource.txt\t1\t\t\t\n'
        edge = 'edge\t\t\t\tScreens\tRoutes\tsubmits\n'
        result = self.run_adapter('from-tsv', header + rows + edge)
        self.assertEqual(result.returncode, 0, result.stderr)
        model = json.loads(result.stdout)
        self.assertEqual(model['nodes'][0]['id'], 'route_post_reset_password_0')
        self.assertEqual(len(model['groups']), 4)
        self.check_model(result.stdout)
        self.assert_failure('from-tsv', header + rows + edge.replace('Routes', 'missing'),
                            b'E_EDGE_UNKNOWN_NODE')
        self.assert_failure('from-tsv', header + rows.replace('source.txt', '../outside'),
                            b'E_SOURCE_PATH')

    def check_model(self, content):
        path = self.repo / 'output.json'
        path.write_bytes(content)
        result = cli('validate', path, '--repo-dir', self.repo)
        self.assertEqual(result.returncode, 0, result.stderr)

    def assert_failure(self, name, content, code):
        result = self.run_adapter(name, content)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b'')
        self.assertIn(code, result.stderr)
