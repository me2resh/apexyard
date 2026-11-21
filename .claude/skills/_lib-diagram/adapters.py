"""Convert approved skill data to the shared diagram model."""

import csv
import datetime
import re
import subprocess
from pathlib import Path

from model import BadInput, git, derive_web_url, load


def sources(item):
    result = list(item.get('sources', []))
    evidence = item.get('evidence')
    if evidence:
        path, sep, line = evidence.rpartition(':')
        result.append({'path': path, 'line': int(line)} if sep and line.isdigit()
                      else {'path': evidence})
    return result


def base(kind, project, repo_dir, commit):
    try:
        remote = git(repo_dir, 'remote', 'get-url', 'origin').decode().strip()
    except subprocess.CalledProcessError:
        remote = ''
    url, _ = derive_web_url(remote)
    return dict(schema='apexyard.diagram/v1',
                diagram=dict(type=kind, title=project, project=project, direction='LR'),
                generated=dict(by='/' + ('dfd' if kind == 'dfd' else 'feature-diagram'),
                               date=datetime.date.today().isoformat()),
                repo=dict(name=Path(repo_dir).name, web_url=url, commit=commit),
                groups=[], nodes=[], edges=[])


def from_dfd(path, repo_dir, commit, project):
    data = load(path)
    model = base('dfd', data.get('project', project), repo_dir, commit)
    for key, kind in [('actors', 'actor'), ('processes', 'process'), ('stores', 'store')]:
        for item in data.get(key, []):
            node = dict(id=item['id'], kind=kind, label=item.get('name', item['id']),
                        sources=sources(item), tags=[])
            if key == 'actors' and item.get('type') in ('external_service', 'external_auth'):
                node['kind'] = 'external_service'
            model['nodes'].append(node)
    nodes = {node['id']: node for node in model['nodes']}
    for item in data.get('boundaries', []):
        model['groups'].append(dict(id=item['id'], kind='trust_zone', label=item['name']))
        for member in item.get('contains', []):
            if member not in nodes or 'group' in nodes[member]:
                raise BadInput('Boundary member is unknown or has multiple groups.')
            nodes[member]['group'] = item['id']
    for item in data.get('flows', []):
        model['edges'].append(dict(**{'from': item['source'], 'to': item['target']},
                                   label=item.get('label', item.get('payload_hint', '')),
                                   sources=sources(item)))
    for item in data.get('classifications', []):
        evidence = sources(item)
        targets = [nodes[item['element']]] if item.get('element') in nodes else [
            node for node in model['nodes'] if any(
                a['path'].removeprefix('./') == b['path'].removeprefix('./')
                for a in node['sources'] for b in evidence)]
        if not targets:
            raise BadInput('Classification requires a known element or matching evidence.')
        for node in targets:
            tag = item['label'].lower()
            if tag not in node['tags']:
                node['tags'].append(tag)
            node['sources'].extend(source for source in evidence if source not in node['sources'])
    return model


def from_tsv(path, repo_dir, commit, project):
    model = base('feature', project, repo_dir, commit)
    layers = dict(screen=('Screens', 'UI Screens'), route=('Routes', 'HTTP Routes'),
                  model=('Models', 'Data Models'), job=('Jobs', 'Async Jobs'))
    model['groups'] = [dict(id=ident, kind='layer', label=label) for ident, label in layers.values()]
    counts = dict.fromkeys(layers, 0)
    with open(path, encoding='utf-8', newline='') as stream:
        reader = csv.DictReader(stream, delimiter='\t')
        if reader.fieldnames != ['kind', 'name', 'file', 'line', 'from', 'to', 'label']:
            raise BadInput('TSV requires kind, name, file, line, from, to, label columns.')
        for row in reader:
            if None in row or any(value is None for value in row.values()):
                raise BadInput('TSV row has an incorrect column count.')
            kind = row['kind']
            if kind == 'edge':
                model['edges'].append(dict(**{'from': row['from'], 'to': row['to']}, label=row['label']))
                continue
            if kind not in layers:
                raise BadInput('Unknown TSV element kind.')
            slug = re.sub('[^a-z0-9]+', '_', row['name'].lower()).strip('_')[:40]
            ident = '{}_{}_{}'.format(kind, slug, counts[kind])
            counts[kind] += 1
            node = dict(id=ident, kind=kind, label=row['name'], group=layers[kind][0], sources=[])
            if row['file']:
                source = dict(path=row['file'])
                if row['line']:
                    source['line'] = int(row['line'])
                node['sources'].append(source)
            elif row['line']:
                raise BadInput('A source line requires a file.')
            model['nodes'].append(node)
    return model
