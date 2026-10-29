"""Schema, normalisation and pinned Git evidence tests."""

import ast
import copy
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from common import LIB, FIXTURES, cli, fixture
from model import derive_web_url, model_hash, normalise, validate


class ModelTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name)
        self.git('init', '-q')
        self.git('config', 'user.name', 'Test')
        self.git('config', 'user.email', 'test@example.test')
        (self.repo / 'text.txt').write_bytes(b'one\ntwo\n')
        (self.repo / 'tab\tname.txt').write_bytes(b'one\ntwo')
        (self.repo / 'binary.dat').write_bytes(b'\x00\x01\n')
        (self.repo / 'nonutf8.dat').write_bytes(b'\xff\xfe')
        (self.repo / 'empty.txt').write_bytes(b'')
        (self.repo / 'link').symlink_to('text.txt')
        self.git('add', 'text.txt', 'tab\tname.txt', 'binary.dat', 'nonutf8.dat', 'empty.txt', 'link')
        self.git('commit', '-qm', 'test fixture')
        self.sha = self.git('rev-parse', 'HEAD').decode().strip()

    def git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.repo)] + list(args), stderr=subprocess.DEVNULL)

    def codes(self, model):
        return [e.split()[0] for e in validate(model, self.repo)[1]]

    def sourced(self, path='text.txt', line=2):
        model = fixture()
        model['repo']['commit'] = self.sha
        model['nodes'][0]['sources'] = [dict(path=path, line=line)]
        return model

    def test_valid_types(self):
        for name in ('dfd', 'c4-context', 'c4-container', 'feature', 'nested-cycle', 'stress-300'):
            with self.subTest(name=name):
                self.assertEqual(self.codes(fixture(name)), [])

    def test_each_error_fixture(self):
        for path in sorted(FIXTURES.glob('invalid-*.diagram.json')):
            with self.subTest(path=path.name):
                model = json.loads(path.read_text())
                if model['repo']['commit'] == 'a' * 40:
                    model['repo']['commit'] = self.sha
                expected = path.name.split('.')[0].split('-')[1]
                self.assertEqual(self.codes(model), [expected])

    def test_unknown_keys_at_every_level(self):
        for target in ('diagram', 'generated', 'repo', 'groups', 'nodes', 'edges', 'sources'):
            with self.subTest(target=target):
                model = self.sourced()
                value = model[target] if target in ('diagram', 'generated', 'repo') else model[target][0] if target != 'sources' else model['nodes'][0]['sources'][0]
                value['unknown'] = 'value'
                self.assertIn('E_SCHEMA', self.codes(model))

    def test_wrong_structural_types(self):
        for key, value in [('schema', None), ('diagram', []), ('repo', ''), ('nodes', {}), ('edges', [None]), ('groups', [1])]:
            with self.subTest(key=key):
                model = fixture()
                model[key] = value
                self.assertIn('E_SCHEMA', self.codes(model))
        model = fixture()
        model['diagram']['type'] = []
        self.assertIn('E_SCHEMA', self.codes(model))

    def test_required_fields(self):
        model = fixture()
        del model['repo']
        self.assertIn('E_SCHEMA', self.codes(model))

    def test_attrs_map(self):
        model = fixture()
        for item in (model['nodes'][0], model['edges'][0]):
            item['attrs'] = {'note': 'value'}
        self.assertEqual(self.codes(model), [])
        model['edges'][0]['attrs']['note'] = 4
        self.assertIn('E_SCHEMA', self.codes(model))

    def test_ids_and_reserved_suffix(self):
        for ident in ('end', 'END', 'subgraph', 'a_empty', 'bad-id', 'x'*65):
            model = fixture()
            model['nodes'][0]['id'] = ident
            self.assertIn('E_ID', self.codes(model))
        model = fixture()
        model['nodes'][0]['id'] = 'zone'
        self.assertIn('E_ID', self.codes(model))

    def test_edge_ids(self):
        model = fixture()
        model['edges'] = [{'from':'api', 'to':'db'}, {'from':'api', 'to':'db'}]
        normal = normalise(model)
        expected = 'e_' + hashlib.sha256(b'api\ndb\n').hexdigest()[:10]
        self.assertEqual([e['id'] for e in normal['edges']], [expected, expected+'_2'])
        model['edges'].append({'id':expected, 'from':'actor', 'to':'api'})
        self.assertIn('E_ID', self.codes(model))
        model['edges'] = [{'id':'same', 'from':'api','to':'db'}, {'id':'same','from':'api','to':'db'}]
        self.assertIn('E_ID', self.codes(model))

    def test_node_and_edge_id_namespaces(self):
        model = fixture()
        model['edges'][0]['id'] = 'api'
        self.assertEqual(self.codes(model), [])

    def test_hash_canonicalisation(self):
        model = self.sourced('./text.txt')
        other = json.loads(json.dumps(model, sort_keys=True, indent=4))
        other['generated'] = dict(by='other', date='2099-01-01')
        other['nodes'][0]['sources'][0]['path'] = 'text.txt'
        other = normalise(other)
        self.assertEqual(model_hash(model), model_hash(other))
        other['nodes'][0]['label'] = 'Changed'
        self.assertNotEqual(model_hash(model), model_hash(other))
        raw = normalise(model)
        del raw['generated']
        self.assertEqual(model_hash(model), hashlib.sha256(json.dumps(raw,sort_keys=True,separators=(',',':'),ensure_ascii=True).encode('ascii')).hexdigest())

    def test_normalise_does_not_mutate(self):
        model = self.sourced('./text.txt')
        before = copy.deepcopy(model)
        normalise(model)
        self.assertEqual(model, before)

    def test_groups(self):
        for groups in ([dict(id='a',kind='trust_zone',label='A',parent='missing')],
                       [dict(id='a',kind='trust_zone',label='A',parent='b'),dict(id='b',kind='trust_zone',label='B',parent='a')],
                       [dict(id='a',kind='trust_zone',label='A'),dict(id='b',kind='trust_zone',label='B',parent='a'),dict(id='c',kind='trust_zone',label='C',parent='b')]):
            model = fixture()
            model['groups'] = groups
            self.assertIn('E_GROUP', self.codes(model))

    def test_group_endpoints_feature_only(self):
        model = fixture()
        model['edges'][0]['to'] = 'zone'
        self.assertIn('E_EDGE_UNKNOWN_NODE', self.codes(model))
        self.assertEqual(self.codes(fixture('feature')), [])

    def test_controls_and_text_limits(self):
        for label in ('new\nline', 'tab\tlabel', 'null\x00'):
            model = fixture()
            model['nodes'][0]['label'] = label
            self.assertIn('E_SCHEMA', self.codes(model))
        model = fixture()
        model['nodes'][0]['description'] = 'a'*201
        self.assertIn('E_LIMIT', self.codes(model))

    def test_size_limits(self):
        model = fixture('stress-300')
        model['nodes'].append(dict(id='extra',kind='process',label='extra'))
        self.assertIn('E_LIMIT', self.codes(model))
        model = fixture()
        model['edges'] *= 501
        self.assertIn('E_LIMIT', self.codes(model))

    def test_source_paths(self):
        for path in ('/absolute', 'C:/absolute', '../outside', 'a/../b', 'a/./b', '././text.txt', 'a\\b', 'a\x00b', 'a\nb', 'a'*513, 'a//b', ''):
            with self.subTest(path=path):
                self.assertIn('E_SOURCE_PATH', self.codes(self.sourced(path)))
        self.assertEqual(self.codes(self.sourced('./text.txt')), [])

    def test_source_lines_and_binary(self):
        self.assertEqual(self.codes(self.sourced()), [])
        self.assertEqual(self.codes(self.sourced('tab\tname.txt')), ['E_SOURCE_PATH'])
        for path, line in [('text.txt',0), ('text.txt',3), ('binary.dat',1), ('nonutf8.dat',1), ('empty.txt',1)]:
            self.assertEqual(self.codes(self.sourced(path,line)), ['E_SOURCE_LINE'])
        model = self.sourced('binary.dat')
        del model['nodes'][0]['sources'][0]['line']
        self.assertEqual(self.codes(model), [])

    def test_sources_use_pinned_blob(self):
        (self.repo / 'text.txt').write_text('changed\n')
        self.assertEqual(self.codes(self.sourced(line=2)), [])
        (self.repo / 'untracked.txt').write_text('untracked\n')
        self.assertEqual(self.codes(self.sourced('untracked.txt',1)), ['E_SOURCE_OUTSIDE'])

    def test_nul_tree_and_blob_only(self):
        # A tab in an unrelated filename must not corrupt tree parsing.
        self.assertEqual(self.codes(self.sourced()), [])
        self.git('update-index','--add','--cacheinfo','160000,'+self.sha+',module')
        self.git('commit','-qm','gitlink fixture')
        model = self.sourced('module',1)
        model['repo']['commit'] = self.git('rev-parse','HEAD').decode().strip()
        self.assertEqual(self.codes(model), ['E_SOURCE_OUTSIDE'])

    def test_null_commit_and_missing_commit(self):
        model = self.sourced()
        model['repo']['commit'] = None
        self.assertEqual(self.codes(model), ['E_COMMIT'])
        model['repo']['commit'] = '0'*40
        self.assertEqual(self.codes(model), ['E_COMMIT'])
        self.assertIn('E_COMMIT', [e.split()[0] for e in validate(self.sourced())[1]])

    def test_tag_object_is_not_commit(self):
        self.git('tag', '-a', 'sample', '-m', 'annotated tag')
        model = self.sourced()
        model['repo']['commit'] = self.git('rev-parse', 'sample').decode().strip()
        self.assertEqual(self.codes(model), ['E_COMMIT'])

    def test_warning_dirty(self):
        (self.repo/'text.txt').write_text('dirty')
        _, errors, warnings = validate(self.sourced(), self.repo)
        self.assertEqual(errors, [])
        self.assertEqual(warnings[0].split()[0], 'W_DIRTY')

    def test_url_derivation_and_redaction(self):
        for remote in ('git@github.com:example-org/sample-app.git',
                       'ssh://git@github.com:2222/example-org/sample-app.git',
                       'https://user:token@github.com/example-org/sample-app.git'):
            url, warning = derive_web_url(remote)
            self.assertEqual(url, 'https://github.com/example-org/sample-app')
            self.assertIsNone(warning)
            self.assertNotIn('token', str((url, warning)))
        for remote in ('http://user:token@host/repo', 'https://user:token@host/repo?bad=1', 'garbage-token'):
            url, warning = derive_web_url(remote)
            self.assertIsNone(url)
            self.assertNotIn('token', warning)

    def test_cli_exit_codes(self):
        self.assertEqual(cli('validate', FIXTURES/'dfd.diagram.json').returncode, 0)
        result = cli('validate', FIXTURES/'invalid-E_URL-1.diagram.json')
        self.assertEqual(result.returncode, 1)
        self.assertNotIn(b'token', result.stderr)
        self.assertEqual(cli('validate', self.repo/'missing.json').returncode, 2)
        self.assertEqual(cli('unsupported').returncode, 2)
        bad = self.repo/'bad.json'
        bad.write_text('{')
        self.assertEqual(cli('validate', bad).returncode, 2)

    def test_ascii_and_python39(self):
        for path in sorted(LIB.rglob('*')):
            if path.is_file() and '__pycache__' not in path.parts:
                raw = path.read_bytes()
                self.assertTrue(raw.isascii(), str(path))
                if path.suffix == '.py':
                    ast.parse(raw.decode('ascii'), feature_version=(3,9))


if __name__ == '__main__':
    unittest.main()
