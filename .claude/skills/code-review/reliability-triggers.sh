#!/usr/bin/env bash
# Read a unified diff from stdin or the first argument.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
source "$ROOT/.claude/hooks/_lib-read-config.sh"
source "$ROOT/.claude/hooks/_lib-portfolio-paths.sh"
CUSTOM=$(portfolio_custom_handbooks_dir)
exec python3 -c '
import fnmatch
import pathlib
import re
import shlex
import sys

root, custom, *args = sys.argv[1:]
if len(args) > 1:
    sys.exit("Usage: reliability-triggers.sh [diff-file]")
patch = pathlib.Path(args[0]).read_text() if args else sys.stdin.read()
paths, lines = [], []
in_hunk = False
for line in patch.splitlines():
    if line.startswith("diff --git "):
        in_hunk = False
        names = shlex.split(line[11:])
        if len(names) == 2:
            paths.extend(name[2:] for name in names)
    elif line.startswith("@@ "):
        in_hunk = True
    elif not in_hunk and line.startswith(("--- ", "+++ ")):
        value = line[4:].split("\t", 1)[0]
        if value.startswith(chr(34)):
            value = shlex.split(value)[0]
        if value != "/dev/null":
            paths.append(value[2:] if value.startswith(("a/", "b/")) else value)
    elif in_hunk and line.startswith(("+", "-")):
        lines.append(line[1:])

files = sorted((pathlib.Path(root) / "handbooks/architecture").glob("reliability-*.md"))
files += sorted((pathlib.Path(custom) / "architecture").glob("reliability-*.md"))
results = []
for file in dict.fromkeys(files):
    text = file.read_text()
    body = text
    if text.startswith("---\n"):
        parts = text.split("\n---\n", 1)
        if len(parts) == 2:
            body = parts[1]
    enforcement = "blocking" if body.startswith("ENFORCEMENT: blocking\n") else "advisory"
    for block in re.split(r"(?=^## )", text, flags=re.M):
        fields = {}
        for name in ("Trigger", "Check", "Source"):
            match = re.search(r"^" + name + r": (.+)$", block, re.M)
            if match:
                fields[name] = match.group(1)
        if not fields:
            continue
        if len(fields) != 3 or not block.startswith("## "):
            sys.exit(f"Invalid reliability item: {file}")
        kind, sep, pattern = fields["Trigger"].partition(": ")
        # Markdown may wrap the pattern in backticks so linters keep it literal.
        pattern = pattern.strip()
        if len(pattern) >= 2 and pattern[0] == "`" and pattern[-1] == "`":
            pattern = pattern[1:-1]
        if not sep or kind not in ("path", "regex"):
            sys.exit(f"Invalid reliability trigger: {file}")
        if kind == "path":
            matched = any(fnmatch.fnmatchcase(path, pattern) for path in paths)
        else:
            try:
                expression = re.compile(pattern, re.I)
            except re.error as error:
                sys.exit(f"Invalid reliability regex in {file}: {error}")
            matched = any(expression.search(line) for line in lines)
        if matched:
            results.append("\n".join([
                block.splitlines()[0], f"Handbook: {file}",
                f"Enforcement: {enforcement}",
                *[f"{name}: {fields[name]}" for name in ("Trigger", "Check", "Source")],
            ]))
if results:
    print("\n\n".join(results))
' "$ROOT" "$CUSTOM" "$@"
