"""Golden Mermaid, dialect escaping and drift checks."""

import json
from pathlib import Path
import tempfile
import unittest

from common import FIXTURES, LIB, cli, fixture
from mermaid import check, emit, escape
from model import model_hash, normalise


class MermaidTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.model = fixture()
        self.path = self.directory / 'sample.md'
        self.model_path = self.directory / 'sample.diagram.json'
        self.model_path.write_text(json.dumps(self.model))
        self.text = '<!-- diagram-model: sample.diagram.json sha256=' + model_hash(self.model)[:12] + ' -->\n```mermaid\n' + emit(normalise(self.model)) + '```\n'
        self.path.write_text(self.text)

    def test_goldens(self):
        for name in ('c4-context', 'c4-container', 'dfd', 'feature'):
            with self.subTest(name=name):
                self.assertEqual(emit(normalise(fixture(name))), (LIB/'tests'/'golden'/(name+'.mmd')).read_text())

    def test_cli_mermaid(self):
        result = cli('mermaid', FIXTURES/'dfd.diagram.json')
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout.decode(), emit(normalise(self.model)))
        bad = cli('mermaid', FIXTURES/'invalid-E_KIND.diagram.json')
        self.assertEqual(bad.returncode, 1)
        self.assertEqual(bad.stdout, b'')

    def test_escape_table(self):
        self.assertEqual(escape('"|[]\n'), '#quot;#124;#91;#93;#10;')
        self.assertEqual(escape('&<>\\#`{}'), '#38;#60;#62;#92;#35;#96;#123;#125;')
        self.assertEqual(escape('(x),'), '(x),')
        self.assertEqual(escape('API (v2), Q&A/path #1 [beta] "core"', 'c4'),
                         "API (v2), Q&A/path #1 [beta] 'core'")

    def test_quoted_punctuation(self):
        for name in ('dfd', 'feature'):
            text = emit(normalise(fixture(name)))
            self.assertIn(' -->|"', text)
            self.assertIn('(v2), core: Q#38;A/path #35;1 #91;beta#93; #quot;quoted#quot;', text)
        for name in ('c4-context', 'c4-container'):
            text = emit(normalise(fixture(name)))
            self.assertIn("(v2), core: Q&A/path #1 [beta] 'quoted'", text)
            self.assertNotIn('#40;', text)

    def test_labels_cannot_insert_syntax(self):
        model = fixture()
        model['nodes'][0]['label'] = '"] --> evil["<script>|'
        text = emit(normalise(model))
        self.assertIn('#quot;#93; --#62; evil#91;#quot;#60;script#62;#124;', text)
        self.assertNotIn('<script>', text)

    def test_empty_feature_layer(self):
        self.assertIn('Jobs_empty["(empty)"]', emit(normalise(fixture('feature'))))

    def test_self_loop_emitted(self):
        model = normalise(fixture('nested-cycle'))
        self.assertIn('api -->|"retry"| api', emit(model))

    def test_nested_groups(self):
        text = emit(normalise(fixture('nested-cycle')))
        self.assertIn('    subgraph parent', text)
        self.assertIn('        subgraph child', text)

    def test_order_is_stable(self):
        model = normalise(fixture('nested-cycle'))
        text = emit(model)
        for key in ('groups','nodes','edges'):
            model[key].reverse()
        self.assertEqual(emit(model), text)

    def test_check_match(self):
        self.assertEqual(check(self.path), [])
        self.assertEqual(cli('check', self.path).returncode, 0)

    def test_check_changed_block(self):
        self.path.write_text(self.text.replace('Customer', 'Edited'))
        self.assertIn('E_DRIFT', check(self.path)[0])
        self.assertEqual(cli('check', self.path).returncode, 1)

    def test_check_hash_mismatch(self):
        self.path.write_text(self.text.replace(model_hash(self.model)[:12], '0'*12))
        self.assertIn('E_DRIFT', check(self.path)[0])

    def test_check_model_change(self):
        self.model['nodes'][0]['label']='Changed'
        self.model_path.write_text(json.dumps(self.model))
        self.assertIn('E_DRIFT', check(self.path)[0])

    def test_check_html_hash(self):
        html = self.directory/'sample.html'
        for digest in (model_hash(self.model), '0'*64):
            html.write_text('<script type="application/json" id="ay-diagram-data">'+json.dumps({'model_sha256':digest})+'</script>')
            self.assertEqual(bool(check(self.path)), digest == '0'*64)

    def test_check_bad_html(self):
        for content in ('<html></html>', '<script type="application/json" id="ay-diagram-data">{bad}</script>', '<script type="application/json" id="ay-diagram-data">[]</script>'):
            (self.directory/'sample.html').write_text(content)
            self.assertIn('E_DRIFT', check(self.path)[0])

    def test_check_path_restriction(self):
        for name in ('../outside.diagram.json', '/tmp/outside.diagram.json', 'sub/model.diagram.json', 'sub\\model.diagram.json'):
            self.path.write_text(self.text.replace('sample.diagram.json',name))
            self.assertIn('E_DRIFT',check(self.path)[0])

    def test_check_symlink_escape(self):
        with tempfile.TemporaryDirectory() as outside:
            external = Path(outside)/'model.json'
            external.write_text(json.dumps(self.model))
            self.model_path.unlink()
            self.model_path.symlink_to(external)
            self.assertIn('E_DRIFT', check(self.path)[0])

    def test_check_missing_marker_or_fence(self):
        for text in ('# no diagram', self.text.replace('```mermaid', '```text')):
            self.path.write_text(text)
            self.assertIn('E_DRIFT',check(self.path)[0])

    def test_check_crlf(self):
        self.path.write_bytes(self.text.replace('\n','\r\n').encode())
        self.assertEqual(check(self.path), [])


if __name__ == '__main__':
    unittest.main()
