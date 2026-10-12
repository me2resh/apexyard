"""Preserve user exclusions and track the exact writer entry in a local sidecar."""
import fnmatch
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile

SUFFIX = '/.claude/rules/**'
META = '\\*?[]{}()!+@'


def escape_root(root):
    # Claude Code normalizes backslashes in patterns to slashes. Use bracket
    # literals, not backslash escapes, so metacharacters survive normalization.
    if '\\' in root:
        raise ValueError('backslash paths cannot be represented safely')
    return ''.join('[' + c + ']' if c in META else c for c in root)


def read_safe(target):
    """Read regular files without following a final-component symlink."""
    try:
        fd = os.open(target, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError:
        return None
    with os.fdopen(fd, 'rb') as stream:
        if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
            raise ValueError('unsafe local file')
        return stream.read()


def replace_safe(target, content, original):
    fd, temporary = tempfile.mkstemp(prefix='.rule-excludes-', dir=target.parent)
    try:
        if original is not None:
            os.fchmod(fd, stat.S_IMODE(target.lstat().st_mode))
        with os.fdopen(fd, 'wb') as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        if read_safe(target) != original:
            raise ValueError('local file changed concurrently')
        os.replace(temporary, target)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def matches(pattern, path):
    # Protect escaped glob characters before fnmatch translates the pattern.
    literals = {}
    def protect(match):
        token = chr(0xE000 + len(literals))
        literals[token] = match.group(1)
        return token
    protected = re.sub(r'\[([*?\[\]{}()!+@])\]', protect, pattern)
    translated = fnmatch.translate(re.sub(r'\\(.)', protect, protected))
    for token, literal in literals.items():
        translated = translated.replace(token, re.escape(literal))
    return re.fullmatch(translated, path) is not None


def safe_pattern(pattern, root, home):
    denied = [root + '/CLAUDE.md', root + '/AGENTS.md',
              home + '/.claude/CLAUDE.md', root + '/.claude/hooks/example.sh',
              root + '/.claude/settings.json']
    denied.extend(str(p) for p in Path(root, '.claude/hooks').rglob('*'))
    denied += [str(Path(p).resolve()) for p in denied]
    return pattern.startswith('/') and not any(matches(pattern, p) for p in denied)


def members(raw):
    """Return top-level value spans; reject duplicate keys rather than guess."""
    decoder = json.JSONDecoder()
    index = raw.index('{') + 1
    spans = {}
    while True:
        while raw[index].isspace():
            index += 1
        if raw[index] == '}':
            return spans, index
        key, index = decoder.raw_decode(raw, index)
        while raw[index].isspace():
            index += 1
        if raw[index] != ':' or key in spans:
            raise ValueError('ambiguous object')
        index += 1
        while raw[index].isspace():
            index += 1
        start = index
        _, index = decoder.raw_decode(raw, index)
        spans[key] = (start, index)
        while raw[index].isspace():
            index += 1
        if raw[index] == ',':
            index += 1
        elif raw[index] != '}':
            raise ValueError('invalid object')


def advisory(root, home, excludes):
    files = list(Path(home, '.claude/rules').rglob('*.md'))
    files += list(Path(root, 'workspace').glob('*/.claude/rules/**/*.md'))
    if any(matches(pattern, str(file)) or matches(pattern, str(file.resolve()))
           for pattern in excludes for file in files):
        print('Rule excludes advisory: personal or managed-project rule files are excluded by existing settings.')


def main(root, home):
    target = Path(root, '.claude/settings.local.json')
    session = Path(root, '.claude/session')
    if session.is_symlink() or (session.exists() and not session.is_dir()):
        raise ValueError('unsafe session directory')
    session.mkdir(exist_ok=True)
    sidecar = session / 'rule-excludes.owned'
    previous = read_safe(sidecar)
    recorded = previous.decode('utf-8') if previous is not None else None
    settings_original = read_safe(target)
    original = settings_original if settings_original is not None else b'{}\n'
    raw = original.decode('utf-8')
    existing = json.loads(raw)
    if not isinstance(existing, dict):
        raise ValueError('settings must be an object')
    spans, end = members(raw)
    entries = existing.get('claudeMdExcludes', [])
    if not isinstance(entries, list) or not all(isinstance(p, str) for p in entries):
        raise ValueError('invalid exclusions')
    pattern = escape_root(root) + SUFFIX
    if not safe_pattern(pattern, root, home):
        raise ValueError('protected path excluded')
    wanted = [p for p in entries if not (recorded != pattern and p == recorded)]
    if pattern not in wanted:
        wanted.append(pattern)
    # jq merge changes precisely one key. Preserve every other value's lexical bytes.
    merged = subprocess.run(['jq', '--argjson', 'entries', json.dumps(wanted),
                             '. + {claudeMdExcludes: $entries}'], input=original,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)
    result = json.loads(merged.stdout)
    value = json.dumps(result['claudeMdExcludes'], ensure_ascii=False)
    if entries != wanted or 'claudeMdExcludes' not in existing:
        if 'claudeMdExcludes' in spans:
            start, stop = spans['claudeMdExcludes']
            updated = raw[:start] + value + raw[stop:]
        else:
            updated = raw[:end] + (',' if spans else '') + '"claudeMdExcludes": ' + value + raw[end:]
        if json.loads(updated) != result:
            raise ValueError('splice differs from jq merge')
        replace_safe(target, updated.encode('utf-8'), settings_original)
        print('Rule excludes: updated .claude/settings.local.json for this ops clone (effective next session).')
    if previous != pattern.encode('utf-8'):
        replace_safe(sidecar, pattern.encode('utf-8'), previous)
    # Arrays merge across settings layers. Inspect those layers without editing them.
    exclusions = list(wanted)
    for layer in [Path(home, '.claude/settings.json'), Path(root, '.claude/settings.json')]:
        if layer.is_file():
            other = json.loads(layer.read_bytes()).get('claudeMdExcludes', [])
            if isinstance(other, list):
                exclusions += [p for p in other if isinstance(p, str)]
    advisory(root, home, exclusions)


if __name__ == '__main__':
    main(*sys.argv[1:])
