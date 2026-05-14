# Leak Protection — Private Registry Refs on Public Repos

Private project identifiers (names, repo slugs, workspace paths) belong in your fork. They do **not** belong on public framework issue trackers. This rule exists because the leak vector is mechanical: an agent diagnoses a framework bug while working inside a private project, then files the upstream ticket with a helpful *"discovered during `<private-project>` rebuild"* reference. Once filed, that private project name is indexed on a public tracker forever, searchable by anyone.

## The rule

**When writing to a public framework repo (issue / PR / comment), never reference a registered private project by `name`, `repo` slug, workspace path, or `<owner>/<repo>#<N>` ticket notation.**

*Public framework repo* = any repo in the hook's public-class list. Default list:

- `me2resh/apexyard` (the canonical upstream)
- Whatever `git remote get-url upstream` resolves to in the current fork
- Future: overridable via `.claude/project-config.json` → `leak_protection.public_framework_repos`

*Registered project* = any entry in your fork's `apexyard.projects.yaml`. The registry is — by convention — the fork owner's private portfolio.

## What gets scrubbed

- `.projects[].name` — whole-word match, case-insensitive. Skipped when the name is the target repo's own name (mentioning "apexyard" in an apexyard upstream ticket is fine).
- `.projects[].repo` — exact `owner/repo` match, optionally followed by `#<N>` to catch ticket references. Skipped when equal to the target repo.
- `.projects[].workspace` — whole-word match on the workspace path.

## What does NOT get scrubbed

- The fork owner's git identity (name / email) — that's signed on every commit anyway.
- Generic class descriptions: *"a registered project"*, *"one of the managed project workspaces"*, *"during bulk ticket filing"*. This is the recommended rewrite shape.
- Timeline phrases (*"on 2026-04-24"*, *"during the Q2 cleanup"*) — dates and sprint labels don't carry attribution.

## Escape hatch — skip marker

When an upstream ticket legitimately needs to reference a registered project by name — the rare case where the framework has to name a managed-project's tracker, for example an AgDR about a specific migration handled in a managed project — add this HTML comment to the body:

```html
<!-- private-refs: allow -->
```

The hook then exits 0 and prints a one-line warning to stderr. The marker is deliberately visible in the rendered issue so a reader can see "this reference was kept on purpose, not missed".

## When the hook fires

Wired to `PreToolUse` on `Bash` for five command shapes:

| Shape | Example |
|-------|---------|
| `gh issue create --repo` | `gh issue create --repo me2resh/apexyard --title "..." --body "..."` |
| `gh pr create --repo` | `gh pr create --repo me2resh/apexyard --title "..." --body "..."` |
| `gh issue comment --repo` | `gh issue comment 42 --repo me2resh/apexyard --body "..."` |
| `gh pr comment --repo` | `gh pr comment 42 --repo me2resh/apexyard --body "..."` |
| `gh api .../issues\|/pulls` | `gh api repos/me2resh/apexyard/issues -f title=... -f body=...` |

The hook silently exits 0 in three no-op cases:

1. **Target not public-class** — the command points at a private registered repo (your own project); the concern doesn't apply inside your own org.
2. **`apexyard.projects.yaml` missing** — no registry = no scrub list. The hook has nothing to enforce.
3. **Empty title + empty body + no body-file** — `gh ... comment <n>` without a `-b` / `-F` opens the editor; the hook has nothing to scan.

## False-positive handling

If a project's `name` collides with a generic word (a project literally named `auth`, or `core`), the hook will block any upstream ticket that uses that word. Mitigations:

1. **Don't register a private project under a generic one-word name.** `curios-dog` is fine; `auth` is not. This is a good principle independent of leak protection — it also stops `/projects` and `/tasks` from colliding.
2. **Use the skip marker** when you've confirmed the match is incidental. The warning that accompanies the bypass is visible and auditable.
3. **Omit the `name` field temporarily** — the hook reads only registered fields, so redacting one project's name in the registry removes it from the scrub list. Least-preferred option; you lose discovery in `/projects` for that project.

## Relationship to other hooks

The leak-protection hook is a **sibling to `check-secrets.sh`** — both scan outgoing content for identifiers that should never leave the local environment. The difference is scope:

| Hook | Protects | When |
|------|----------|------|
| `check-secrets.sh` | API keys, passwords, tokens | `git commit` time (staged diff) |
| `block-private-refs-in-public-repos.sh` | Project names, repo slugs, workspace paths | `gh` tracker-write time (title + body) |

Both are backstops against routine-but-damaging leaks. Self-discipline is the primary defence; the hook catches the cases where the agent had the private information right in front of it while writing the upstream content and didn't actively suppress it.

## Rationale for mechanical enforcement

Self-discipline doesn't prevent this class of leak. The private project's name is *right there* in the working context while the agent is writing the upstream ticket — not referencing it takes active suppression. Mechanical enforcement is the right shape, same pattern as `check-secrets.sh` and the commit-format hooks.
