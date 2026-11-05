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


def open_read_flags(os_module=None):
    """Open flags for a read that does not follow a final-component symlink.

    Windows Python has no O_NOFOLLOW and no O_NONBLOCK. Missing flags
    contribute 0. POSIX keeps both when the interpreter defines them.
    """
    module = os if os_module is None else os_module
    flags = module.O_RDONLY
    flags |= getattr(module, 'O_NOFOLLOW', 0)
    flags |= getattr(module, 'O_NONBLOCK', 0)
    return flags


def read_safe(target):
    """Read a regular file. Refuse a symlink at the final path component.

    lstat runs before open so a Windows interpreter that lacks O_NOFOLLOW
    still refuses a symlink that is already there. POSIX also passes
    O_NOFOLLOW, which closes the gap between lstat and open.
    """
    try:
        info = os.lstat(target)
    except FileNotFoundError:
        return None
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
        raise ValueError('unsafe local file')
    try:
        fd = os.open(target, open_read_flags())
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


def splice_member(raw, key, value):
    spans, end = members(raw)
    encoded = json.dumps(value, ensure_ascii=True)
    if key in spans:
        start, stop = spans[key]
        return raw[:start] + encoded + raw[stop:]
    return raw[:end] + (',' if spans else '') + json.dumps(key) + ': ' + encoded + raw[end:]


def portfolio_permissions(root, home, portfolio):
    """Add only the helper's exact portfolio directory, preserving other bytes."""
    path = Path(portfolio)
    if not portfolio or not path.is_absolute():
        raise ValueError('missing portfolio root')
    # Inspect the original components before collapsing '..' or symlinks.
    current = Path(path.anchor)
    for part in path.parts[1:]:
        current = current / part
        if current.is_symlink():
            raise ValueError('symlinked portfolio root')
    path = path.resolve(strict=True)
    ops = Path(root).resolve(strict=True)
    if path == ops or ops in path.parents:
        return
    if not path.is_dir() or path == Path('/') or path == Path(home).resolve() or path in ops.parents:
        raise ValueError('unsafe portfolio root')
    target = Path(root, '.claude/settings.local.json')
    original = read_safe(target)
    raw = (original if original is not None else b'{}\n').decode('utf-8')
    existing = json.loads(raw)
    if not isinstance(existing, dict):
        raise ValueError('settings must be an object')
    spans, _ = members(raw)
    permissions = existing.get('permissions', {})
    if not isinstance(permissions, dict):
        raise ValueError('permissions must be an object')
    entries = permissions.get('additionalDirectories', [])
    if not isinstance(entries, list) or not all(isinstance(p, str) for p in entries):
        raise ValueError('invalid additional directories')
    if 'permissions' in spans:
        start, stop = spans['permissions']
        nested = raw[start:stop]
        members(nested)
    else:
        nested = '{}'
    if str(path) in entries:
        return
    updated_permissions = splice_member(nested, 'additionalDirectories', entries + [str(path)])
    if 'permissions' in spans:
        updated = raw[:start] + updated_permissions + raw[stop:]
    else:
        _, end = members(raw)
        updated = raw[:end] + (',' if spans else '') + '"permissions": ' + updated_permissions + raw[end:]
    replace_safe(target, updated.encode('utf-8'), original)
    print('Portfolio permissions: updated .claude/settings.local.json (effective next session).')


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
    if sys.argv[1:2] == ['--portfolio-permissions']:
        portfolio_permissions(*sys.argv[2:])
    else:
        main(*sys.argv[1:])
