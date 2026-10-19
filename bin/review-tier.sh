#!/usr/bin/env bash
# Export this file from the trusted base tree, never from the PR working tree.
# Safe from any working directory: isolated Python (-I) and a temporary cwd.
# Usage: bash review-tier.sh <repo> <base-sha> <reviewed-sha> [head-ref]
# Output permits only the existing Reduced-Scope pass. All errors mean Full.
if ! command -v python3 >/dev/null 2>&1; then
  printf '%s\n' '{"depth":"Full","reason":"python3 unavailable"}'
  exit 0
fi

repo=${1-}
if [ -z "$repo" ]; then
  printf '%s\n' '{"depth":"Full","reason":"expected repo, base SHA, reviewed SHA and optional head ref"}'
  exit 0
fi
# Resolve the repository to an absolute path before leaving the caller's cwd.
case $repo in
  /*) ;;
  *)
    if ! repo=$(cd -- "$repo" 2>/dev/null && pwd -P); then
      printf '%s\n' '{"depth":"Full","reason":"repository path unavailable"}'
      exit 0
    fi
    ;;
esac
shift

neutral=$(mktemp -d) || {
  printf '%s\n' '{"depth":"Full","reason":"neutral directory unavailable"}'
  exit 0
}
cleanup() { rm -rf -- "$neutral"; }
trap cleanup EXIT
trap 'cleanup; exit 1' HUP INT TERM
if ! cd -- "$neutral"; then
  printf '%s\n' '{"depth":"Full","reason":"neutral directory unavailable"}'
  exit 0
fi

python3 -I - "$repo" "$@" <<'PY'
import json
import re
import subprocess
import sys


def classify():
    if len(sys.argv) not in (4, 5):
        raise ValueError('expected repo, base SHA, reviewed SHA and optional head ref')
    repo, base, head = sys.argv[1:4]
    ref = sys.argv[4] if len(sys.argv) == 5 else 'HEAD'
    if not all(re.fullmatch(r'[0-9a-f]{40}', s) for s in (base, head)):
        raise ValueError('full commit SHAs required')
    if ref.startswith('-'):
        raise ValueError('invalid head ref')

    def git(*args):
        return subprocess.check_output(
            ['git', '-C', repo, '-c', 'core.fsmonitor=false',
             '-c', 'core.attributesFile=/dev/null', *args],
            stderr=subprocess.DEVNULL, timeout=30)

    def current():
        return git('rev-parse', '--verify', ref + '^{commit}').decode().strip()

    if current() != head:
        raise ValueError('head changed since tier request')
    for sha in (base, head):
        if git('rev-parse', '--verify', sha + '^{commit}').decode().strip() != sha:
            raise ValueError('commit unavailable')

    def fields(raw):
        if not raw or not raw.endswith(b'\0'):
            raise ValueError('empty or truncated file list')
        return raw[:-1].decode('utf-8', 'strict').split('\0')

    # Capture git output directly. No forge pagination or caller-supplied list.
    parts = fields(git('diff', '--no-ext-diff', '--no-textconv', '--name-status',
                      '-z', '-M', '-C', '--find-copies-harder', base + '..' + head, '--'))
    paths = set()
    destinations = set()
    i = 0
    while i < len(parts):
        status = parts[i]
        i += 1
        if not re.fullmatch(r'[ACDMRTUXB][0-9]*', status):
            raise ValueError('invalid diff status')
        count = 2 if status[0] in 'RC' else 1
        if i + count > len(parts):
            raise ValueError('truncated rename or copy')
        group = parts[i:i + count]
        if not all(group):
            raise ValueError('empty path')
        paths.update(group)
        destinations.add(group[-1])
        i += count
    # Independent listing detects a list cut at a complete record boundary.
    plain = set(fields(git('diff', '--no-ext-diff', '--no-textconv', '--no-renames',
                           '--name-only', '-z', base + '..' + head, '--')))
    if not plain <= paths or not destinations <= plain:
        raise ValueError('incomplete file list')

    # Prompt text and its references are Full, including references introduced
    # by this PR. Search path ancestors too, so a named directory is protected.
    prompt_text = ''
    for sha in (base, head):
        names = fields(git('ls-tree', '-r', '--name-only', '-z', sha, '--'))
        prompt_names = [p for p in names if p.startswith((
            '.claude/', '.agents/', '.codex/', 'roles/', 'templates/', 'workflows/'))
            or p in ('CLAUDE.md', 'AGENTS.md', 'SYSTEM.md')]
        for name in prompt_names:
            prompt_text += git('show', sha + ':' + name).decode('utf-8', 'replace') + '\n'

    for path in sorted(paths):
        if not re.fullmatch(r'docs/(?:[A-Za-z0-9_-]+/)*[A-Za-z0-9_-]+\.(?:md|png|jpg|jpeg|gif|webp)', path):
            return 'Full', 'path outside allowlist', sorted(paths)
        if path.startswith(('docs/agdr/', 'docs/orbit/')):
            return 'Full', 'decision or machine-consumed records', sorted(paths)
        pieces = path.split('/')
        references = ['/'.join(pieces[:n]) for n in range(2, len(pieces) + 1)]
        if any(p in prompt_text for p in references):
            return 'Full', 'prompt reference', sorted(paths)
        for sha in (base, head):
            entry = git('ls-tree', sha, '--', path)
            if entry and not entry.startswith(b'100644 blob '):
                return 'Full', 'non-regular documentation file', sorted(paths)
    if current() != head:
        raise ValueError('head changed during tier check')
    return 'Reduced-scope-allowed', 'Rex must still apply both rails', sorted(paths)


try:
    depth, reason, paths = classify()
    print(json.dumps(dict(depth=depth, reason=reason, paths=paths,
                          base_sha=sys.argv[2], reviewed_sha=sys.argv[3])))
except Exception as error:
    print(json.dumps(dict(depth='Full', reason=str(error))))
PY
status=$?
if [ "$status" -ne 0 ]; then
  printf '%s\n' '{"depth":"Full","reason":"tier process failed"}'
fi
exit 0
