# Code reviewer reference

This document holds the long examples and rationale that `.claude/agents/code-reviewer.md` (Rex) used to carry inline.
They moved here in me2resh/apexyard#1650 to cut the input tokens of each review.
Rex does not need this document for a review. The agent file states every check, rule, and required output.
Read this document when you change the agent file or when you want the reason behind a rule.

## Why the content moved

- Every PR pays for at least one Rex review. Each byte of the agent file is input on every request of every review.
- The agent file keeps every check, every blocking rule, the required outputs, and the Output Format.
- This document keeps the worked examples, the reference implementation, and the history behind each rule.
- The eval report in `docs/eval-agents/reports/` records the before and after measurement.

## Floor rules and `omitClaudeMd`

Rex sets `omitClaudeMd: true` in its frontmatter.
A subagent with this setting does not receive the user, project, or local CLAUDE.md files.
It also does not receive the auto-memory index.
Managed policy files still load.

The Rex agent file therefore carries a short "Floor rules" block.
The block lists only the always-on CLAUDE.md rules that Rex enforces.
Do not add a rule that the agent does not check.
Do not move the block into a shared file. A shared file saves no tokens, because each review reads it again.

Hakim (`security-reviewer.md`) keeps CLAUDE.md.
The #1650 eval tested `omitClaudeMd` and a floor block for Hakim too.
Hakim then missed or downgraded a HIGH defect on one corpus entry in 4 of 19 runs, against 0 of 19 before.
So #1650 reverted the Hakim change. The eval report has the numbers.

Build agents keep CLAUDE.md and the memory index.
Their lessons live there, and no check would detect the loss.

## Handbook discovery: shell example

The agent file states the discovery contract. This shell block is one way to run it.

```bash
# Resolve the private custom-handbooks dir (split-portfolio adopters).
# Empty / missing dir → just skip the private layer; not an error.
PRIV=""
if [ -f "$OPS_ROOT/.claude/hooks/_lib-portfolio-paths.sh" ]; then
  source "$OPS_ROOT/.claude/hooks/_lib-read-config.sh"
  source "$OPS_ROOT/.claude/hooks/_lib-portfolio-paths.sh"
  candidate=$(portfolio_custom_handbooks_dir 2>/dev/null)
  [ -n "$candidate" ] && [ -d "$candidate" ] && PRIV="$candidate"
fi

# Applicability-gated buckets — public + private (private may be empty).
DIFF_FILES=$(gh pr diff <number> --name-only)
if printf '%s\n' "$DIFF_FILES" | grep -qE '(^|/)(src|app|packages|services|domain|application|infrastructure)/|docs/agdr/|(^|/)(designs|prds)/|technical-design|feature-spec|migrations/|prisma/schema.prisma'; then
  find handbooks/architecture -name '*.md' 2>/dev/null
  [ -n "$PRIV" ] && find "$PRIV/architecture" -name '*.md' 2>/dev/null
fi

# General handbooks still require topic judgment. Collect candidates, inspect
# the path/title/scope, then read the full handbook only when it applies.
find handbooks/general -name '*.md' 2>/dev/null
[ -n "$PRIV" ] && find "$PRIV/general" -name '*.md' 2>/dev/null

# Diff-matched language buckets — public + private.
echo "$DIFF_FILES" | (
  if grep -qE '\.(ts|tsx)$'; then
    find handbooks/language/typescript -name '*.md' 2>/dev/null
    [ -n "$PRIV" ] && find "$PRIV/language/typescript" -name '*.md' 2>/dev/null
  fi
  # ... etc per language
)

# Domain buckets — public + private. Collect all candidates first, then make
# ONE batched matcher call, so the Bash call count stays constant.
DOMAIN_HBS=()
for d in handbooks/domain/*/ ${PRIV:+$PRIV/domain/*/}; do
  [ -d "$d" ] || continue
  for hb in "$d"*.md; do
    [ -f "$hb" ] || continue
    [ "$(basename "$hb")" = "README.md" ] && continue
    DOMAIN_HBS+=("$hb")
  done
done
if [ ${#DOMAIN_HBS[@]} -gt 0 ]; then
  printf '%s\n' "$DIFF_FILES" | python3 match_handbooks.py "${DOMAIN_HBS[@]}"
fi
```

One batched call matters in a sandbox, because each `python3` call can raise a permission prompt.

## Domain handbook matcher: reference implementation

This batched Python matcher takes N handbook paths in `argv` and the changed-file list on stdin.
It prints the handbooks to load, one for each line.

```python
#!/usr/bin/env python3
# match_handbooks.py — batched load decision for N domain handbooks.
# Usage: match_handbooks.py <handbook1> [<handbook2> ...] < diff-files-on-stdin
# Prints loadable handbook paths to stdout, one per line. Exits 0 always.

import re, sys

def expand_braces(glob):
    out = ['']; i = 0
    while i < len(glob):
        c = glob[i]
        if c == '{':
            depth = 1; j = i + 1
            while j < len(glob) and depth:
                if glob[j] == '{': depth += 1
                elif glob[j] == '}': depth -= 1
                if depth: j += 1
            if depth:
                out = [p + c for p in out]; i += 1
            else:
                alts = glob[i+1:j].split(',')
                out = [p + a for p in out for a in alts]
                i = j + 1
        else:
            out = [p + c for p in out]; i += 1
    return out

def glob_to_regex(glob):
    rgx = ''; i = 0
    while i < len(glob):
        c = glob[i]
        if c == '*':
            if i + 1 < len(glob) and glob[i+1] == '*':
                # `**/` — zero or more path segments. `(?:.*/)?` matches
                # either empty (root file) or any prefix ending in `/`,
                # which is bash globstar semantics.
                if i + 2 < len(glob) and glob[i+2] == '/':
                    rgx += '(?:.*/)?'; i += 3
                else:
                    rgx += '.*'; i += 2  # `**` not followed by `/` — be permissive
            else:
                rgx += '[^/]*'; i += 1
        elif c == '?': rgx += '.'; i += 1
        elif c in '.()[]+^$|\\': rgx += '\\' + c; i += 1
        else: rgx += c; i += 1
    return '^' + rgx + '$'

# Strip a YAML inline comment ` # ...` before the list-item regex runs.
# Without this strip, `- "src/foo/**"  # rationale` captures the comment as
# part of the glob and silently matches nothing.
_STRIP_COMMENT = re.compile(r'\s+#.*$')

def should_load(hb, diff):
    try:
        with open(hb) as f: lines = f.readlines()
    except OSError:
        return False
    if not lines or lines[0].rstrip() != '---':
        return True  # no frontmatter → always load
    fm_end = next((i for i in range(1, len(lines)) if lines[i].rstrip() == '---'), None)
    if fm_end is None:
        return True  # unterminated → degrade visibly to always-load
    globs = []; in_paths = False
    for raw in lines[1:fm_end]:
        line = _STRIP_COMMENT.sub('', raw)
        if re.match(r'^\s*#', line) or not line.strip(): continue
        if re.match(r'^paths\s*:', line):
            in_paths = True
            tail = line.split(':', 1)[1].strip()
            if tail.startswith('['):
                inner = tail.strip('[]').strip()
                if inner:
                    globs.extend([s.strip().strip('"\'') for s in inner.split(',')])
                in_paths = False
            continue
        if in_paths:
            if not re.match(r'^\s', line): in_paths = False; continue
            m = re.match(r'^\s*-\s*["\']?(.*?)["\']?\s*$', line)
            if m and m.group(1): globs.append(m.group(1))
    if not globs:
        return True  # no paths key, or empty list → always load
    patterns = [re.compile(glob_to_regex(g)) for orig in globs for g in expand_braces(orig)]
    for f in diff:
        if any(rgx.match(f) for rgx in patterns):
            return True
    return False

def main():
    diff = [ln.strip() for ln in sys.stdin.read().splitlines() if ln.strip()]
    for hb in sys.argv[1:]:
        if should_load(hb, diff):
            print(hb)

main()
```

## Handbook findings: full example

```markdown
### Handbook Findings

⛔ **Migration Safety (blocking)** — `handbooks/architecture/migration-safety.md`
- `prisma/migrations/20260514_drop_role/migration.sql:3` drops `users.role_v1` which the previous release reads in `src/auth/role-resolver.ts:42`. Split into a deprecate-then-drop pair across two releases. (See handbook § "What Rex flags" #1.)

⚠ **Clean Architecture Layers** — `handbooks/architecture/clean-architecture-layers.md`
- `src/domain/order.ts:8` imports `@aws-sdk/client-dynamodb`. Move persistence to `src/infrastructure/`. (See handbook § "Sample finding".)

⚠ **TypeScript Strict Mode** — `handbooks/language/typescript/strict-mode.md`
- `src/handlers/user.ts:42` declares `function fetchUser(id: any)` — replace with `string` or a domain value object.

⚠ **Payment Idempotency** — `handbooks/domain/payments/idempotency-keys.md`
- `src/handlers/stripe-webhook.ts:88` retries a `charges.create` call without supplying the `Idempotency-Key` header. Add the request UUID per handbook § "What Rex flags" #2.
```

## Label-only summary bullets: examples

The heuristic flags a bullet with 6 words or fewer and no verb.

These bullets trigger it:

- `- State fix` (2 words, no verb)
- `- OPA/Rego compliance policies` (3 words, no verb)
- `- CI pipeline changes` (3 words, no verb)
- `- Pre-commit hooks` (2 words, no verb)

These bullets do not trigger it:

- `- Fixed broken repository state — added moved blocks so Terraform renames…` (a verb, more than 6 words, a reason)
- `- Bumps lockfile to lodash 4.17.21 (CVE-2021-23337)` (a dependency-bump shape)
- `- Renames Foo → Bar across 17 files` (a mechanical-refactor shape)

The check is advisory, because a simple heuristic has a high false-positive rate.
A legitimate one-line bug fix or dependency bump would otherwise churn the merge gate.

## Fallow findings: example

````markdown
### Fallow Findings  *(advisory — JS/TS static analysis, changed scope)*

| Category | Location | Finding |
|----------|----------|---------|
| Unused export | `src/lib/format.ts:14` | `formatLegacyDate` is exported but unreferenced |
| Duplication | `src/a.ts:30` ↔ `src/b.ts:51` | 18-line clone (`dup:1a2b3c4d`) |
| Complexity | `src/handlers/order.ts:88` | `processOrder` cyclomatic 24 — refactor candidate |

**Proposed fixes (dry run — not applied):**

```
fallow fix --dry-run
- remove unused export formatLegacyDate (src/lib/format.ts)
- drop unused dependency left-pad (package.json)
```

(Author can apply locally with `fallow fix --yes` after review.)
````

Fallow findings are candidates, and its security output is unverified.
A narrow blocking subset, such as a new circular dependency, needs its own AgDR first (AgDR-0069).

## Approval marker: rationale

### Why the reviewer writes its own marker

The separation that the merge gate depends on lives in which agent writes the marker.
It does not live in the GitHub review-state UI.
In a single-account setup, GitHub blocks self-approval, so a host "Approved" state is not available.
Since #1026, `warn-review-marker-write.sh` is advisory (AgDR-0111).
A build agent's identical write is therefore not stopped mechanically.
The Rex write is legitimate because an independent review happened.

### Why `MARKER_HOME` is resolved once, pin-first

The walk-up resolution depends on `$PWD`.
Suppose a reviewer clones the fork into a temporary directory and changes into it first.
The walk-up then resolves to that throwaway tree, and the merge gate cannot find the marker.
`pin-ops-root.sh` (#381) captures the launch-time ops root at SessionStart.
`_lib-ops-root.sh::resolve_ops_root` reads that pin first.
In split-portfolio mode, a plain walk-up resolves to the private portfolio sibling (#559).
That directory has no `_lib-review-markers.sh`, so the marker would land under a bare name where no gate reads it.

### Why `{repo}` is never re-derived (#887)

An unscoped `gh pr view {number} --json headRepository` call has two faults.
It reads the head (fork) repository, not the base repository.
It also relies on the ambient default of `gh`, which prefers the parent repository.
That default is wrong for a same-repo fork PR opened against the fork's own `main`.
`pr_base_repo` requires the explicit repository and scopes its query to it.
A wrong repository then fails closed instead of keying the marker on an unrelated PR.

### Why the marker is keyed on the base repository (#765)

The merge gate keys on the merge command's `--repo` value or API path.
For a cross-fork PR, that is always the base repository.
Keying the marker on the head repository blocked cross-fork approvals.

### Wrong marker contents

Each of these breaks the whitespace-strip-then-compare check of the merge gate:

```
PR: 42
SHA: 2933a06e28a1e98aee8cdef18a0dcaaa0f610b08
```

```json
{"pr": 42, "sha": "2933a06e28a1e98aee8cdef18a0dcaaa0f610b08"}
```

```
2933a06e28a1e98aee8cdef18a0dcaaa0f610b08 (reviewed 2026-04-17)
```

The correct content is 41 bytes: 40 hex characters and one newline.
Check it with `od -c "$REX_MARKER" | head -2`.

## Reduced-scope review: why the merge gate stays unconditional

`block-unreviewed-merge.sh` is a control that reads structured state.
It compares a marker with the HEAD that the forge reports.
It cannot inspect the content of a diff to decide a tier.
So a Lean diff still needs a Rex marker, and only the depth of the review changes (AgDR-0116).
