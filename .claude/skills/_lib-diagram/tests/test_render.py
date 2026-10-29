"""HTML security, deterministic output, CLI and accessible token checks."""

import ast
import base64
import hashlib
from html.parser import HTMLParser
import json
from pathlib import Path
import re
import tempfile
import unittest

from common import FIXTURES, LIB, cli, fixture
from layout import layout
from model import model_hash, normalise
from render import render, TEMPLATE

NAMES = ('c4-context', 'c4-container', 'dfd', 'feature', 'nested-cycle',
         'xss', 'placeholders', 'stress-300')


class Page(HTMLParser):
    def __init__(self, source):
        super().__init__(convert_charrefs=True)
        self.tags = []
        self.feed(source)
        self.close()

    def handle_starttag(self, tag, attrs):
        self.tags.append((tag, dict(attrs)))


def block(source, tag):
    return re.search(r'<' + tag + r'>(.*?)</' + tag + '>', source, re.S).group(1)


def data_block(source):
    return re.search(r'<script type="application/json" id="ay-diagram-data">(.*?)</script>', source, re.S).group(1)


def luminance(color):
    values = [int(color[i:i + 2], 16) / 255 for i in (1, 3, 5)]
    linear = [v / 12.92 if v <= .04045 else ((v + .055) / 1.055) ** 2.4 for v in values]
    return sum(a * b for a, b in zip(linear, (.2126, .7152, .0722)))


def contrast(a, b):
    light, dark = sorted((luminance(a), luminance(b)), reverse=True)
    return (light + .05) / (dark + .05)


class RenderTests(unittest.TestCase):
    def test_smoke_and_goldens(self):
        for name in NAMES:
            with self.subTest(name=name):
                model = normalise(fixture(name))
                source = render(model)
                self.assertTrue(source.isascii())
                self.assertEqual(source, (LIB / 'tests' / 'golden' / (name + '.html')).read_text('ascii'))
                page = Page(source)
                scripts = [attrs for tag, attrs in page.tags if tag == 'script']
                self.assertEqual(scripts, [{'type': 'application/json', 'id': 'ay-diagram-data'}, {}])
                self.assertEqual(sum(tag == 'style' for tag, _ in page.tags), 1)
                for tag, attrs in page.tags:
                    self.assertNotIn('style', attrs)
                    self.assertFalse(any(key.lower().startswith('on') for key in attrs))
                    if tag in ('script', 'link', 'img', 'iframe', 'object'):
                        self.assertFalse({'src', 'href', 'data'} & attrs.keys())
                head = next(i for i, (tag, _) in enumerate(page.tags) if tag == 'head')
                tag, attrs = page.tags[head + 1]
                self.assertEqual(tag, 'meta')
                self.assertEqual(attrs['http-equiv'], 'Content-Security-Policy')
                csp = attrs['content']
                expected = "default-src 'none'; base-uri 'none'; form-action 'none'"
                for kind in ('script', 'style'):
                    digest = base64.b64encode(hashlib.sha256(block(source, kind).encode('ascii')).digest()).decode('ascii')
                    expected += "; " + kind + "-src 'sha256-" + digest + "'"
                self.assertEqual(csp, expected)
                self.assertLess(source.index('<meta charset="utf-8">') + len('<meta charset="utf-8">'), 1024)
                raw = data_block(source).encode('ascii')
                for char in (b'<', b'>', b'&'):
                    self.assertEqual(raw.find(char), -1)
                payload = json.loads(raw)
                self.assertEqual(payload.pop('positions'), layout(model))
                self.assertEqual(payload.pop('model_sha256'), model_hash(model))
                self.assertEqual(payload, model)
                self.assertEqual(block(source, 'title'), 'Diagram')
                # Only the data block can contain repository URLs or model text.
                template_part = source.replace(data_block(source), '')
                self.assertNotIn('://', template_part.replace('http://www.w3.org/2000/svg', ''))
                for forbidden in ('@import', 'fetch(', 'XMLHttpRequest', 'import(', 'innerHTML', 'RegExp('):
                    self.assertNotIn(forbidden, template_part)
                self.assertIsNone(re.search(r'url\(\s*[\'"]?[a-z]+:', template_part, re.I))
                print('HTML bytes: ' + name + ' ' + str(len(source.encode('ascii'))))

    def test_xss_and_single_pass(self):
        for name in ('xss', 'placeholders'):
            model = normalise(fixture(name))
            source = render(model)
            raw = data_block(source).encode('ascii')
            self.assertNotIn(b'</script', raw)
            self.assertEqual(json.loads(raw)['diagram']['title'], model['diagram']['title'])
            self.assertEqual(json.loads(raw)['nodes'], model['nodes'])
            self.assertEqual(source.count('http-equiv="Content-Security-Policy"'), 1)
            self.assertEqual(source.count('id="ay-diagram-data"'), 1)
        raw = data_block(render(normalise(fixture('xss')))).encode('ascii')
        for escape in (b'\\u003c', b'\\u003e', b'\\u0026'):
            self.assertIn(escape, raw)

    def test_template_count_guard(self):
        template = TEMPLATE.read_text('ascii')
        for name in ('CSP', 'DATA'):
            slot = '{{' + name + '}}'
            for replacement in ('', slot + slot):
                with self.assertRaises(ValueError):
                    render(normalise(fixture()), template.replace(slot, replacement))
        for tag in ('script', 'style'):
            with self.assertRaises(ValueError):
                render(normalise(fixture()), template.replace('<' + tag + '>', '<div>'))

    def test_contrast(self):
        css = block(TEMPLATE.read_text('ascii'), 'style')
        rules = re.findall(r'([^{}]+)\{([^{}]+)\}', css)
        tokens = lambda body: dict(re.findall(r'(--ay-[\w-]+):\s*(#[0-9a-fA-F]+)', body))
        light = tokens(next(body for selector, body in rules if selector.strip() == ':root'))
        dark = dict(light, **tokens(next(body for selector, body in rules if selector.strip() == ':root[data-theme="dark"]')))
        media = dict(light, **tokens(next(body for selector, body in rules if ':root:not' in selector)))
        self.assertEqual(dark, media)
        self.assertEqual(light['--ay-accent'], '#2F6DF6')
        for theme, values in (('light', light), ('dark', dark)):
            for foreground in ('text', 'muted', 'link', 'teal', 'green', 'violet'):
                for background in ('bg', 'surface', 'tint'):
                    ratio = contrast(values['--ay-' + foreground], values['--ay-' + background])
                    self.assertGreaterEqual(ratio, 4.5, (theme, foreground, background, ratio))
            self.assertGreaterEqual(contrast(values['--ay-on-accent'], values['--ay-accent']), 4.5)

    def test_cli_exit_codes(self):
        good = cli('html', FIXTURES / 'dfd.diagram.json')
        self.assertEqual(good.returncode, 0, good.stderr)
        self.assertEqual(good.stdout.decode('ascii'), render(normalise(fixture())))
        bad = cli('html', FIXTURES / 'invalid-E_URL-1.diagram.json')
        self.assertEqual(bad.returncode, 1)
        self.assertEqual(bad.stdout, b'')
        self.assertNotIn(b'token', bad.stderr)
        self.assertEqual(cli('html', FIXTURES / 'missing.json').returncode, 2)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'bad.json'
            path.write_text('{')
            result = cli('html', path)
            self.assertEqual(result.returncode, 2)
            self.assertEqual(result.stdout, b'')
        self.assertEqual(cli('html').returncode, 2)

    def test_generated_html_drift_check(self):
        from mermaid import emit
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            model = normalise(fixture())
            (folder / 'dfd.diagram.json').write_text(json.dumps(model))
            (folder / 'dfd.html').write_text(render(model))
            markdown = '<!-- diagram-model: dfd.diagram.json sha256=' + model_hash(model)[:12] + ' -->\n'
            markdown += '```mermaid\n' + emit(model) + '```\n'
            (folder / 'dfd.md').write_text(markdown)
            result = cli('check', folder / 'dfd.md')
            self.assertEqual(result.returncode, 0, result.stderr)
            (folder / 'dfd.html').write_text(render(model).replace(model_hash(model), '0' * 64))
            self.assertEqual(cli('check', folder / 'dfd.md').returncode, 1)

    def test_source_constraints(self):
        for path in LIB.rglob('*'):
            if path.is_file() and path.suffix in ('.py', '.html', '.sh', '.js'):
                raw = path.read_bytes()
                self.assertTrue(raw.isascii(), str(path))
                if path.suffix == '.py':
                    ast.parse(raw.decode('ascii'), feature_version=(3, 9))


if __name__ == '__main__':
    unittest.main()
