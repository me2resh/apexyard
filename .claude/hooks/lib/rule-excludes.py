"""jq owns the merge; splice only its target value to preserve other bytes.

Reserved writer signature: absolute, escaped literal root + /.claude/rules/**.
Only this signature is removed on relocation. Relative/wide/user globs stay.
"""
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


def owned(pattern):
    if not isinstance(pattern, str) or not pattern.startswith('/') or not pattern.endswith(SUFFIX):
        return False
    prefix = pattern[:-len(SUFFIX)]
    literal = re.sub(r'\[([*?\[\]{}()!+@])\]', lambda m: m.group(1), prefix)
    try:
        return escape_root(literal) == prefix
    except ValueError:
        return False


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
    # Refuse links and unusual files rather than overwrite their targets.
    if target.is_symlink() or (target.exists() and not target.is_file()):
        raise ValueError('unsafe settings file')
    original = target.read_bytes() if target.exists() else b'{}\n'
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
    wanted = [p for p in entries if not owned(p)] + [pattern]
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
        fd, temporary = tempfile.mkstemp(prefix='.rule-excludes-', dir=target.parent)
        try:
            if target.exists():
                os.fchmod(fd, stat.S_IMODE(target.stat().st_mode))
            with os.fdopen(fd, 'wb') as stream:
                stream.write(updated.encode('utf-8'))
                stream.flush()
                os.fsync(stream.fileno())
            # Do not overwrite an intervening user edit.
            if target.exists() and target.read_bytes() != original:
                raise ValueError('settings changed concurrently')
            os.replace(temporary, target)
            print('Rule excludes: updated .claude/settings.local.json for this ops clone (effective next session).')
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
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
