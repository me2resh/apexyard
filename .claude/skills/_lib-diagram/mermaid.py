"""Emit deterministic Mermaid and verify adjacent generated views."""

import json
import re
from html.parser import HTMLParser
from pathlib import Path

from model import BadInput, load, model_hash, validate


def escape(value, dialect='flowchart'):
    # C4 node and boundary text does not decode Mermaid entities.
    if dialect == 'c4':
        return value.replace(chr(34), chr(39)).replace('\r', ' ').replace('\n', ' ')
    # Quoted flowchart labels and C4 relationships/title decode entities.
    special = {'&', '"', '|', '[', ']', '<', '>', '\\', '{', '}', '#', '`'}
    return ''.join('#quot;' if c == chr(34) else '#' + str(ord(c)) + ';' if c in special or c in '\r\n' else c
                   for c in value)


def emit(model):
    diagram_type = model['diagram']['type']
    is_c4 = diagram_type.startswith('c4-')
    dialect = 'c4' if is_c4 else 'flowchart'
    esc = lambda text: escape(text, dialect)
    lines = [('C4Context' if diagram_type == 'c4-context' else 'C4Container')
             if is_c4 else 'flowchart ' + model['diagram']['direction']]
    if is_c4:
        lines.append('    title ' + escape(model['diagram']['title']))
    groups = sorted(model['groups'], key=lambda g: g['id'])
    nodes = sorted(model['nodes'], key=lambda n: n['id'])

    def node_line(node, indent):
        ident, label = node['id'], esc(node['label'])
        if is_c4:
            macro = {'person': 'Person', 'system': 'System', 'external_system': 'System_Ext',
                     'container': 'Container', 'store': 'ContainerDb'}[node['kind']]
            args = [ident, '"' + label + '"']
            if node['kind'] in ('container', 'store'):
                args.append('"' + esc(node.get('technology', '')) + '"')
            args.append('"' + esc(node.get('description', '')) + '"')
            lines.append(indent + macro + '(' + ', '.join(args) + ')')
        elif node['kind'] == 'store':
            lines.append(indent + ident + '[("' + label + '")]')
        elif node['kind'] == 'process':
            lines.append(indent + ident + '(("' + label + '"))')
        else:
            lines.append(indent + ident + '["' + label + '"]')

    def contents(parent, level):
        indent = '    ' * level
        for group in groups:
            if group.get('parent') != parent:
                continue
            if is_c4:
                lines.append(indent + 'System_Boundary(' + group['id'] + ', "' + esc(group['label']) + '") {')
            else:
                lines.append(indent + 'subgraph ' + group['id'] + '["' + esc(group['label']) + '"]')
            contents(group['id'], level + 1)
            if diagram_type == 'feature' and not any(n.get('group') == group['id'] for n in nodes) and not any(g.get('parent') == group['id'] for g in groups):
                lines.append(indent + '    ' + group['id'] + '_empty["(empty)"]')
            lines.append(indent + ('}' if is_c4 else 'end'))
        for node in nodes:
            if node.get('group') == parent:
                node_line(node, indent)

    contents(None, 1)
    for edge in sorted(model['edges'], key=lambda e: e['id']):
        label = escape(edge.get('label', ''))
        if is_c4:
            lines.append('    Rel(' + edge['from'] + ', ' + edge['to'] + ', "' + label + '", "' + escape(edge.get('technology', '')) + '")')
        else:
            arrow = ' -->|"' + label + '"| ' if label else ' --> '
            lines.append('    ' + edge['from'] + arrow + edge['to'])
    return '\n'.join(lines) + '\n'


class DataBlock(HTMLParser):
    def __init__(self):
        super().__init__()
        self.active = False
        self.blocks = []

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag == 'script' and attrs.get('type') == 'application/json' and attrs.get('id') == 'ay-diagram-data':
            self.active = True
            self.blocks.append('')

    def handle_data(self, data):
        if self.active:
            self.blocks[-1] += data

    def handle_endtag(self, tag):
        if tag == 'script':
            self.active = False


def check(markdown, repo_dir=None):
    path = Path(markdown)
    try:
        text = path.read_text(encoding='utf-8')
    except (OSError, UnicodeError) as exc:
        raise BadInput('Cannot read markdown. Check the path and encoding.') from exc
    marker = re.compile(r'<!-- diagram-model: (\S+) sha256=([0-9a-f]{12}) -->\r?\n```mermaid\r?\n(.*?)\r?\n```', re.S)
    matches = list(marker.finditer(text))
    if not matches:
        return ['E_DRIFT /: Supply an adjacent model marker and Mermaid fence.']
    errors = []
    for match in matches:
        name, short_hash, block = match.groups()
        # A basename only, including after symlink resolution.
        model_path = path.parent / name
        if '/' in name or '\\' in name or name in ('.', '..') or model_path.resolve().parent != path.parent.resolve():
            errors.append('E_DRIFT /: Keep the model in the markdown directory.')
            continue
        model, faults, _ = validate(load(model_path), repo_dir)
        if faults:
            errors.extend(faults)
            continue
        digest = model_hash(model)
        if short_hash != digest[:12] or block + '\n' != emit(model):
            errors.append('E_DRIFT /: Regenerate the marker and Mermaid block from the model.')
        html = model_path.with_name(model_path.name.removesuffix('.diagram.json') + '.html')
        if html.exists():
            parser = DataBlock()
            try:
                parser.feed(html.read_text(encoding='utf-8'))
                if len(parser.blocks) != 1 or json.loads(parser.blocks[0]).get('model_sha256') != digest:
                    errors.append('E_DRIFT /: Regenerate the HTML model hash.')
            except (OSError, UnicodeError, ValueError, AttributeError):
                errors.append('E_DRIFT /: Supply a valid HTML data block.')
    return errors
