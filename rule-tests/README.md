# Rule tests

Rule tests hold short snippets that a handbook rule must flag. They sit beside the handbook tree under `rule-tests/`.

## Path

Mirror the handbook path. A handbook at `handbooks/architecture/migration-safety.md` uses the case file `rule-tests/handbooks/architecture/migration-safety.md`.

## Format

A case file has YAML front matter with a `rule:` key. The value is the handbook id (repo-relative path without `.md`). Next comes a required `## Must flag` section with one fenced code block. An optional `## Must not flag` section may follow with another fenced block.

Example:

~~~~markdown
---
rule: handbooks/architecture/migration-safety
---

## Must flag

```text
the snippet the rule must catch
```

## Must not flag

```text
an optional snippet the rule must leave alone
```
~~~~

Rules:

- Front matter must include `rule:`.
- A `## Must flag` section is required. It must hold one fenced code block.
- A `## Must not flag` section is optional.

The `/codify-rule` skill asks for a case before it writes a new handbook entry.
