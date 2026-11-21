"""Load, normalise and validate the provisional diagram v1 model."""

import copy
import hashlib
import json
import re
import subprocess
import unicodedata
from urllib.parse import urlsplit

ID = re.compile(r'[A-Za-z][A-Za-z0-9_]{0,63}\Z')
URL = re.compile(r'https://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~-]+)+\Z')
KINDS = {
    'c4-context': (('person', 'system', 'external_system'), ()),
    'c4-container': (('person', 'container', 'store', 'external_system'), ('system_boundary',)),
    'dfd': (('actor', 'external_service', 'process', 'store'), ('trust_zone',)),
    'feature': (('screen', 'route', 'model', 'job'), ('layer',)),
}
RESERVED = ('end', 'subgraph', 'flowchart', 'graph', 'direction',
                      'classDef', 'class', 'style', 'click', 'linkStyle',
                      'C4Context', 'C4Container', 'title')


class BadInput(ValueError):
    """Unreadable input, distinct from an invalid model."""


def load(path):
    try:
        with open(path, encoding='utf-8') as stream:
            return json.load(stream)
    except (OSError, ValueError, UnicodeError) as exc:
        raise BadInput('Cannot read model JSON. Check the file and encoding.') from exc


def normalise(model):
    result = copy.deepcopy(model)
    counts = {}
    for edge in result.get('edges', []):
        if 'id' not in edge:
            raw = '\n'.join((edge['from'], edge['to'], edge.get('label', '')))
            base = 'e_' + hashlib.sha256(raw.encode('utf-8')).hexdigest()[:10]
            counts[base] = counts.get(base, 0) + 1
            edge['id'] = base + ('_' + str(counts[base]) if counts[base] > 1 else '')
    for item in result.get('nodes', []) + result.get('edges', []):
        for source in item.get('sources', []):
            if source['path'].startswith('./'):
                source['path'] = source['path'][2:]
    return result


def model_hash(model):
    canonical = normalise(model)
    canonical.pop('generated', None)
    data = json.dumps(canonical, sort_keys=True, separators=(',', ':'), ensure_ascii=True)
    return hashlib.sha256(data.encode('ascii')).hexdigest()


def derive_web_url(remote):
    """Return (URL, warning). Never include the remote in diagnostics."""
    try:
        if remote.startswith('git@') and ':' in remote:
            host, path = remote[4:].split(':', 1)
            value = 'https://' + host + '/' + path
        else:
            parts = urlsplit(remote)
            if parts.scheme == 'ssh' and parts.username == 'git':
                value = 'https://' + (parts.hostname or '') + parts.path
            elif parts.scheme == 'https':
                value = 'https://' + parts.netloc.rsplit('@', 1)[-1] + parts.path
                if parts.query or parts.fragment:
                    return None, 'W_URL /repo/web_url: Cannot derive URL. Supply a safe HTTPS URL.'
            else:
                value = ''
        value = value.rstrip('/')
        if value.endswith('.git'):
            value = value[:-4]
        if URL.fullmatch(value):
            return value, None
    except ValueError:
        pass
    return None, 'W_URL /repo/web_url: Cannot derive URL. Supply a safe HTTPS URL.'


def printable(value):
    return all(not unicodedata.category(char).startswith('C') and char.isprintable()
               for char in value)


def schema_error(errors, path, hint):
    errors.append('E_SCHEMA ' + (path or '/') + ': ' + hint)


def object_fields(value, path, required, optional, errors):
    if not isinstance(value, dict):
        schema_error(errors, path, 'Use an object.')
        return False
    for key in sorted(value):
        if key not in required and key not in optional:
            pointer = key.replace('~', '~0').replace('/', '~1')
            schema_error(errors, path + '/' + pointer, 'Remove unknown key.')
    for key in required:
        if key not in value:
            schema_error(errors, path + '/' + key, 'Supply required field.')
    return all(key in value for key in required)


def string_field(value, path, errors):
    if not isinstance(value, str):
        schema_error(errors, path, 'Use a string.')


def source_fields(value, path, errors):
    if not isinstance(value, list):
        schema_error(errors, path, 'Use an array.')
        return
    for index, source in enumerate(value):
        pointer = path + '/' + str(index)
        if object_fields(source, pointer, ('path',), ('line',), errors):
            string_field(source['path'], pointer + '/path', errors)
            if 'line' in source and type(source['line']) is not int:
                schema_error(errors, pointer + '/line', 'Use an integer.')


def item_fields(item, path, errors):
    for key, value in item.items():
        loc = path + '/' + key
        if key in ('parent', 'group') and value is None:
            continue
        if key == 'attrs':
            if not isinstance(value, dict) or not all(isinstance(v, str) for v in value.values()):
                schema_error(errors, loc, 'Use a map of strings.')
        elif key == 'tags':
            if not isinstance(value, list) or not all(isinstance(v, str) and re.fullmatch('[a-z]+', v) for v in value):
                schema_error(errors, loc, 'Use an array of lowercase words.')
        elif key == 'sources':
            source_fields(value, loc, errors)
        else:
            string_field(value, loc, errors)


def collection_fields(model, plural, errors):
    items = model[plural]
    if not isinstance(items, list):
        schema_error(errors, '/' + plural, 'Use an array.')
        return
    required = {'groups': ('id', 'kind', 'label'), 'nodes': ('id', 'kind', 'label'),
                'edges': ('from', 'to')}[plural]
    optional = {'groups': ('parent', 'description'),
                'nodes': ('technology', 'description', 'group', 'tags', 'sources', 'attrs'),
                'edges': ('id', 'label', 'technology', 'tags', 'sources', 'attrs')}[plural]
    for index, item in enumerate(items):
        path = '/' + plural + '/' + str(index)
        if object_fields(item, path, required, optional, errors):
            item_fields(item, path, errors)


def structure(model):
    errors = []
    required = ('schema', 'diagram', 'generated', 'repo', 'groups', 'nodes', 'edges')
    if not object_fields(model, '', required, (), errors):
        return errors
    if model['schema'] != 'apexyard.diagram/v1':
        schema_error(errors, '/schema', 'Use apexyard.diagram/v1.')
    for key, fields in (('diagram', ('type', 'title', 'project', 'direction')),
                        ('generated', ('by', 'date')), ('repo', ('name', 'web_url', 'commit'))):
        if object_fields(model[key], '/' + key, fields, (), errors):
            for field in fields:
                value = model[key][field]
                if key == 'repo' and field in ('web_url', 'commit') and value is None:
                    continue
                string_field(value, '/' + key + '/' + field, errors)
    if isinstance(model['diagram'], dict):
        kind = model['diagram'].get('type')
        if not isinstance(kind, str) or kind not in KINDS:
            schema_error(errors, '/diagram/type', 'Use a supported diagram type.')
        if model['diagram'].get('direction') not in ('LR', 'TB'):
            schema_error(errors, '/diagram/direction', 'Use LR or TB.')
    for plural in ('groups', 'nodes', 'edges'):
        collection_fields(model, plural, errors)
    return errors


def git(repo_dir, *args, **kwargs):
    return subprocess.run(['git', '-C', str(repo_dir)] + list(args),
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True, **kwargs).stdout


def tree_blobs(tree):
    blobs = {}
    for record in tree.split(b'\0'):
        if record:
            meta, path = record.split(b'\t', 1)
            mode, kind, sha = meta.split()
            if kind == b'blob':
                blobs[path.decode('utf-8', 'surrogateescape')] = sha.decode('ascii')
    return blobs


def blob_lines(repo_dir, shas):
    counts = {}
    data = git(repo_dir, 'cat-file', '--batch', input=('\n'.join(shas) + '\n').encode('ascii'))
    offset = 0
    for sha in shas:
        end = data.index(b'\n', offset)
        header = data[offset:end].split()
        if header == [sha.encode('ascii'), b'missing']:
            counts[sha] = 'missing'
            offset = end + 1
            continue
        size = int(header[2])
        blob = data[end + 1:end + 1 + size]
        offset = end + size + 2
        try:
            blob.decode('utf-8')
            is_text = b'\0' not in blob
        except UnicodeError:
            is_text = False
        counts[sha] = len(blob.splitlines()) if is_text else None
    return counts


def check_sources(model, repo_dir, sources, errors, warnings):
    commit = model['repo']['commit']
    if commit is None:
        if sources:
            errors.append('E_COMMIT /repo/commit: Supply a pinned commit for sources.')
        return
    if not re.fullmatch('[0-9a-fA-F]{40}', commit) or repo_dir is None:
        errors.append('E_COMMIT /repo/commit: Supply a 40-hex commit and --repo-dir.')
        return
    try:
        if git(repo_dir, 'cat-file', '-t', commit).strip() != b'commit':
            errors.append('E_COMMIT /repo/commit: Pin a commit object, rather than a tag or tree.')
            return
        tree = git(repo_dir, 'ls-tree', '-r', '-z', '--full-tree', commit)
        if git(repo_dir, 'status', '--porcelain'):
            warnings.append('W_DIRTY /repo/commit: Clone has uncommitted changes. Sources use the pinned commit.')
    except (OSError, subprocess.CalledProcessError):
        errors.append('E_COMMIT /repo/commit: Use a commit present in the clone.')
        return
    blobs = tree_blobs(tree)
    cited = {}
    for source, pointer in sources:
        sha = blobs.get(source['path'])
        if sha is None:
            errors.append('E_SOURCE_OUTSIDE ' + pointer + '/path: Cite a blob in the pinned tree.')
        elif 'line' in source and source['line'] >= 1:
            cited[sha] = None
    if not cited:
        return
    try:
        cited = blob_lines(repo_dir, sorted(cited))
    except (OSError, subprocess.CalledProcessError):
        errors.append('E_COMMIT /repo/commit: Cannot read pinned blobs. Check the clone.')
        return
    for source, pointer in sources:
        sha = blobs.get(source['path'])
        if 'line' in source and sha in cited:
            lines = cited[sha]
            if lines == 'missing':
                errors.append('E_SOURCE_OUTSIDE ' + pointer + '/path: Cite a blob available in the clone.')
            elif lines is None or source['line'] > lines:
                errors.append('E_SOURCE_LINE ' + pointer + '/line: Cite a line within a UTF-8 text blob.')


def fault(errors, code, path, hint):
    errors.append(code + ' ' + path + ': ' + hint)


def check_text(value, path, errors):
    if len(value) > 200:
        fault(errors, 'E_LIMIT', path, 'Limit text to 200 characters.')
    if not printable(value):
        fault(errors, 'E_SCHEMA', path, 'Remove control characters.')


def check_ids_and_kinds(model, errors):
    shared = set()
    for plural in ('groups', 'nodes', 'edges'):
        seen = set() if plural == 'edges' else shared
        for index, item in enumerate(model[plural]):
            path = '/' + plural + '/' + str(index)
            ident = item['id']
            if not ID.fullmatch(ident) or ident.lower() in RESERVED_LOWER or ident.endswith('_empty') or ident in seen:
                fault(errors, 'E_ID', path + '/id', 'Use a unique, non-keyword Mermaid id without the _empty suffix.')
            seen.add(ident)
            for field in ('label', 'description', 'technology'):
                check_text(item.get(field, ''), path + '/' + field, errors)
            allowed = KINDS[model['diagram']['type']][0 if plural == 'nodes' else 1]
            if plural != 'edges' and item['kind'] not in allowed:
                fault(errors, 'E_KIND', path + '/kind', 'Use a kind allowed for this diagram type.')


def check_groups_and_edges(model, errors):
    groups = {g['id']: g for g in model['groups']}
    nodes = {n['id']: n for n in model['nodes']}
    for index, group in enumerate(model['groups']):
        chain = []
        current = group['id']
        while current is not None:
            if current in chain or current not in groups or len(chain) == 2:
                fault(errors, 'E_GROUP', '/groups/' + str(index) + '/parent',
                      'Use an existing parent without cycles, at depth at most two.')
                break
            chain.append(current)
            current = groups[current].get('parent')
    for index, node in enumerate(model['nodes']):
        if node.get('group') is not None and node['group'] not in groups:
            fault(errors, 'E_GROUP', '/nodes/' + str(index) + '/group', 'Use an existing group or null.')
    endpoints = dict(nodes)
    if model['diagram']['type'] == 'feature':
        endpoints.update(groups)
    for index, edge in enumerate(model['edges']):
        for field in ('from', 'to'):
            if edge[field] not in endpoints:
                fault(errors, 'E_EDGE_UNKNOWN_NODE', '/edges/' + str(index) + '/' + field, 'Use an existing endpoint.')


def source_paths(model, errors):
    sources = []
    for plural in ('nodes', 'edges'):
        for index, item in enumerate(model[plural]):
            for i, source in enumerate(item.get('sources', [])):
                pointer = '/' + plural + '/' + str(index) + '/sources/' + str(i)
                path = source['path']
                if not path or len(path) > 512 or path.startswith('/') or re.match('[A-Za-z]:/', path) or '\\' in path or not printable(path) or any(p in ('', '.', '..') for p in path.split('/')):
                    fault(errors, 'E_SOURCE_PATH', pointer + '/path',
                          'Use a repository-relative path without dot segments or controls.')
                else:
                    sources.append((source, pointer))
                if 'line' in source and source['line'] < 1:
                    fault(errors, 'E_SOURCE_LINE', pointer + '/line', 'Use a line number of at least one.')
    return sources


def validate(model, repo_dir=None):
    """Return (normalised model, errors, warnings)."""
    errors = structure(model)
    if errors:
        return None, errors, []
    result = normalise(model)
    warnings = []
    check_ids_and_kinds(result, errors)
    check_groups_and_edges(result, errors)
    for field in ('title', 'project'):
        check_text(result['diagram'][field], '/diagram/' + field, errors)
    if len(result['nodes']) > 300 or len(result['edges']) > 1000:
        fault(errors, 'E_LIMIT', '/', 'Limit diagrams to 300 nodes and 1000 edges.')
    url = result['repo']['web_url']
    if url is not None and not URL.fullmatch(url):
        fault(errors, 'E_URL', '/repo/web_url',
              'Use a safe HTTPS repository URL without credentials, query or fragment.')
    sources = source_paths(result, errors)
    # Invalid paths still require a commit when source evidence exists.
    has_sources = any(item.get('sources') for item in result['nodes'] + result['edges'])
    if result['repo']['commit'] is None and has_sources and not sources:
        fault(errors, 'E_COMMIT', '/repo/commit', 'Supply a pinned commit for sources.')
    check_sources(result, repo_dir, sources, errors, warnings)
    return result, errors, warnings


RESERVED_LOWER = frozenset(word.lower() for word in RESERVED)
