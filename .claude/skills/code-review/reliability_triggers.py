"""Select reliability checklist items whose trigger matches a unified diff."""
import fnmatch
import pathlib
import re
import sys

LABELS = ("Trigger", "Check", "Source")
VALID = re.compile(r"^(Trigger|Check|Source): (.*)$")
LOOKS_LIKE_FIELD = re.compile(
    r"^[\W\d]*(trigger|check|source)[\s*_`|]*[:|]", re.I)
HEADING = re.compile(r"^#{2,6} ")
SIMPLE = {"n": 10, "t": 9, "\\": 92, '"': 34, "a": 7, "b": 8, "f": 12, "r": 13, "v": 11}


def unquote(text):
    """Decode a git C-quoted name such as "a/caf\\303\\251.yml"."""
    if not (len(text) >= 2 and text[0] == '"' and text[-1] == '"'):
        return text
    out, i, body = bytearray(), 0, text[1:-1]
    while i < len(body):
        char = body[i]
        if char == "\\" and i + 1 < len(body):
            nxt = body[i + 1]
            if nxt in "01234567":
                digits = re.match(r"[0-7]{1,3}", body[i + 1:]).group(0)
                out.append(int(digits, 8) & 255)
                i += 1 + len(digits)
                continue
            if nxt in SIMPLE:
                out.append(SIMPLE[nxt])
                i += 2
                continue
        out.extend(char.encode())
        i += 1
    return out.decode("utf-8", "replace")


def split_quoted(text):
    """Return the first quoted name in text and the rest, or None."""
    i = 1
    while i < len(text):
        if text[i] == "\\":
            i += 2
            continue
        if text[i] == '"':
            return text[:i + 1], text[i + 1:]
        i += 1
    return None


def header_names(rest):
    """Split the text after 'diff --git ' into two names. Never raise."""
    if rest.startswith('"'):
        parts = split_quoted(rest)
        if parts:
            first, remainder = parts
            return [unquote(first), unquote(remainder.lstrip(" "))]
        return []
    if rest.endswith('"'):
        index = rest.find(' "b/')
        if index > 0:
            return [rest[:index], unquote(rest[index + 1:])]
        return []
    size = (len(rest) - 5) // 2
    if size > 0 and len(rest) == 2 * size + 5 and rest[2:2 + size] == rest[-size:]:
        return [rest[:2 + size], rest[-(2 + size):]]
    index = rest.find(" b/")
    return [rest[:index], rest[index + 1:]] if index > 0 else []


def strip_prefix(name):
    return name[2:] if name.startswith(("a/", "b/")) else name


def parse_diff(patch):
    """Return changed paths and the added and removed lines."""
    paths, lines = [], []
    fallback, explicit = [], []
    in_hunk = False

    def flush():
        paths.extend(explicit or fallback)
        fallback.clear()
        explicit.clear()

    for line in patch.splitlines():
        if line.startswith("diff --git "):
            flush()
            in_hunk = False
            fallback.extend(strip_prefix(name) for name in header_names(line[11:]))
        elif line.startswith("@@ "):
            in_hunk = True
        elif not in_hunk and line.startswith(("rename from ", "rename to ", "copy from ", "copy to ")):
            explicit.append(unquote(line.split(" ", 2)[2]))
        elif not in_hunk and line.startswith(("--- ", "+++ ")):
            value = line[4:]
            if value.startswith('"'):
                parts = split_quoted(value)
                value = parts[0] if parts else value.split("\t", 1)[0]
            else:
                value = value.split("\t", 1)[0]
            value = unquote(value)
            if value != "/dev/null":
                explicit.append(strip_prefix(value))
        elif in_hunk and line.startswith(("+", "-")):
            lines.append(line[1:])
    flush()
    return paths, lines


def fail(message):
    sys.exit(f"reliability-triggers: {message}")


def parse_items(file):
    """Parse one handbook file. Stop with an error for any malformed item."""
    text = file.read_text()
    body = text
    if text.startswith("---\n"):
        parts = text.split("\n---\n", 1)
        if len(parts) == 2:
            body = parts[1]
    enforcement = "blocking" if body.startswith("ENFORCEMENT: blocking\n") else "advisory"
    blocks, current = [], None
    for line in body.splitlines():
        if HEADING.match(line):
            current = {"heading": line, "fields": {}}
            blocks.append(current)
            continue
        if current is None:
            if LOOKS_LIKE_FIELD.match(line):
                fail(f"{file}: field line before any heading: {line.strip()!r}")
            continue
        match = VALID.match(line)
        if match:
            name, value = match.groups()
            if name in current["fields"]:
                fail(f"{file}: item {current['heading']!r}: repeated field {name}")
            current["fields"][name] = value
        elif LOOKS_LIKE_FIELD.match(line):
            fail(f"{file}: item {current['heading']!r}: malformed field line "
                 f"{line.strip()!r}; use the plain form 'Name: value'")
    items = []
    for block in blocks:
        fields, heading = block["fields"], block["heading"]
        if not fields:
            continue
        missing = [name for name in LABELS if name not in fields]
        if missing:
            fail(f"{file}: item {heading!r}: missing {', '.join(missing)}")
        kind, sep, pattern = fields["Trigger"].partition(": ")
        pattern = pattern.strip()
        if len(pattern) >= 2 and pattern[0] == "`" and pattern[-1] == "`":
            pattern = pattern[1:-1].strip()
        if not sep or kind not in ("path", "regex"):
            fail(f"{file}: item {heading!r}: trigger must start with 'path: ' or 'regex: '")
        if not pattern:
            fail(f"{file}: item {heading!r}: empty trigger pattern")
        expression = None
        if kind == "path":
            pattern = pattern[2:] if pattern.startswith("./") else pattern
        else:
            try:
                expression = re.compile(pattern, re.I)
            except re.error as error:
                fail(f"{file}: item {heading!r}: invalid regex: {error}")
        items.append((heading, kind, pattern, expression, fields, enforcement))
    if not items:
        fail(f"{file}: no reliability items found")
    return items


def main(argv):
    root, custom, *args = argv
    if len(args) > 1:
        fail("Usage: reliability-triggers.sh [diff-file]")
    patch = pathlib.Path(args[0]).read_text() if args else sys.stdin.read()
    paths, lines = parse_diff(patch)
    files = sorted((pathlib.Path(root) / "handbooks/architecture").glob("reliability-*.md"))
    files += sorted((pathlib.Path(custom) / "architecture").glob("reliability-*.md"))
    results = []
    for file in dict.fromkeys(files):
        for heading, kind, pattern, expression, fields, enforcement in parse_items(file):
            if kind == "path":
                matched = any(fnmatch.fnmatchcase(path, pattern) for path in paths)
            else:
                matched = any(expression.search(line) for line in lines)
            if matched:
                results.append("\n".join([
                    heading, f"Handbook: {file}", f"Enforcement: {enforcement}",
                    *[f"{name}: {fields[name]}" for name in LABELS],
                ]))
    if results:
        print("\n\n".join(results))


if __name__ == "__main__":
    main(sys.argv[1:])
