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

Wired to `PreToolUse` on `Bash` for ten command shapes:

| Shape | Example |
|-------|---------|
| `gh issue create --repo` | `gh issue create --repo me2resh/apexyard --title "..." --body "..."` |
| `gh pr create --repo` | `gh pr create --repo me2resh/apexyard --title "..." --body "..."` |
| `gh issue comment --repo` | `gh issue comment 42 --repo me2resh/apexyard --body "..."` |
| `gh pr comment --repo` | `gh pr comment 42 --repo me2resh/apexyard --body "..."` |
| `gh api .../issues\|/pulls` | `gh api repos/me2resh/apexyard/issues -f title=... -f body=...` |
| `gh pr review --repo` | `gh pr review 42 --repo me2resh/apexyard --comment --body "..."` |
| `gh pr merge --repo` | `gh pr merge 42 --repo me2resh/apexyard --squash --subject "..." --body "..."` |
| `tracker_create` wrapper | `tracker_create "me2resh/apexyard" "title" "/tmp/body.md"` |
| `tracker_review_submit` wrapper | `tracker_review_submit "me2resh/apexyard" "42" "comment" "/tmp/body.md"` |
| `tracker_pr_merge` wrapper | `tracker_pr_merge "me2resh/apexyard" "42" "squash" true "subject" "/tmp/body.md"` |

me2resh/apexyard#1206 added the last five rows. Two reviewers found the
wrapper gap independently. `code-reviewer.md` tells Rex to call
`tracker_review_submit`, not `gh pr review`, for every review.
`/approve-merge`'s SKILL.md states its own command text never contains
`gh pr merge`. Each wrapper runs its `gh` call inside a sourced shell
function.

The wrapper scan resolves only a literal `owner/repo` in argument 1. It
cannot expand a shell variable or a value on a later line. Pass the target as
a literal slug, or the hook cannot identify the public repository. Keep the
body-file argument on the same command line for the same reason. A follow-up
must add a fail-closed response for unresolved wrapper arguments.

No second command event fires for that inner call. This hook had zero
matchers for `gh pr review`, `gh pr merge`, or any of the three wrapper
names before #1206. A private reference posted through any of these five
shapes reached a public repo unscanned.

**Known gap, not yet closed here:** No hook scans a private reference
committed directly to a file. This gap covers content that never passes
through a `gh` command's title, body, or subject. me2resh/apexyard#1206
tracks the fix as a new, dedicated enforcement point. It will not extend
this hook.

**Scope limit:** this hook matches `gh` command text only. It does not
match `glab`. A GitLab adopter's `tracker.kind: glab` project sends review
bodies through `_tracker_review_glab`. That function pipes the body into
`glab mr note create -m`. No hook scans it at any point.

The hook silently exits 0 in three no-op cases:

1. **Target not public-class** — the command points at a private registered repo (your own project); the concern doesn't apply inside your own org.
2. **`apexyard.projects.yaml` missing** — no registry = no scrub list. The hook has nothing to enforce.
3. **Empty title + empty body + no body-file** — `gh ... comment <n>` without a `-b` / `-F` opens the editor; the hook has nothing to scan.

## Remediation — when a private reference reaches a public repo anyway

This section states what to do once a private reference reaches a public
repo. Gaps 1 and 2 of me2resh/apexyard#1206 are prevention, not
remediation. State this plainly to whoever runs the remediation. Every
self-service action below reduces exposure. GitHub Support can end
exposure on your own repository. It cannot end exposure inside a fork.

The evidence for this claim is direct, not theoretical. Two remediations
ran on the #1206 incident within the same hour:

| Action | What it fixes | What it leaves |
|---|---|---|
| Edit or delete the comment, review, or PR body through the API | The rendered page and the current REST response | Email notifications already sent, third-party scrapes, and the GitHub search index |
| Redact the file in a later commit | The file at the branch tip | The earlier commit, still served by the public API at its own SHA |
| Rewrite the branch history and force-push (with or without a squash) | The branch tip, the Commits tab, and the base branch's ancestry | The orphaned commit, still served by SHA. The force-push itself publishes that SHA in the PR's own timeline event |
| Contact GitHub Support to purge unreachable objects | The object itself, once GitHub confirms the purge | Copies already fetched by mirrors, clones, or scrapers before the purge. Content already living in a fork |

After the redact-then-commit and the rewrite-then-squash had both run,
`gh api repos/<repo>/contents/<path>?ref=<pre-rewrite-sha>` still returned
48,174 bytes containing 2 occurrences. The rewrite changed where the
content was reachable from. It did not remove it.

GitHub's own guide, ["Removing sensitive data from a repository"](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/removing-sensitive-data-from-a-repository),
confirms this for the rewrite-and-force-push step. It states: "If you only
rewrite your history and force push it, the commits with sensitive data
may still be accessible elsewhere: in any clones or forks of your
repository; directly via their SHA-1 hashes in cached views on GitHub;
through any pull requests that reference them." Permanently removing the
cached views and PR references requires "contacting us through the GitHub
Support portal."

A fork is a separate, harder case. GitHub's guide says you "will need to
coordinate with the owners of the forks, asking them to remove the
sensitive data or delete the fork entirely." It gives the reason: "GitHub
cannot provide contact information for these owners." GitHub Support can
purge your own repository's objects. It cannot reach a fork.

### Runbook

1. File the GitHub Support request first. Every other action in this list
   can run before GitHub responds.
2. Redact the leaked content in a new commit next.
3. If the leak sits in a comment, a review, or a PR body, delete or edit
   it through the API. Use `gh api -X DELETE` or `gh api -X PATCH`.
4. Check GitHub for a fork of the public repo. Use
   `gh api repos/<owner>/<repo>/forks` or the repository's network graph.
   If a fork holds the leak, contact its owner directly. GitHub Support
   cannot remove content from a fork.
5. Until GitHub Support confirms the purge, the incident status must read
   reduced exposure. It must not read removed or fixed.
6. The incident closes when GitHub Support confirms the purge. It can also
   close when a review finds the exposed content carried no real risk.

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
| `block-private-refs-in-public-repos.sh` | Project names, repo slugs, workspace paths | `gh` tracker-write time (issue/PR title + body, review body, merge-commit subject/body) |

Both are backstops against routine-but-damaging leaks. Self-discipline is the primary defence; the hook catches the cases where the agent had the private information right in front of it while writing the upstream content and didn't actively suppress it.

## Rationale for mechanical enforcement

Self-discipline doesn't prevent this class of leak. The private project's name is *right there* in the working context while the agent is writing the upstream ticket — not referencing it takes active suppression. Mechanical enforcement is the right shape, same pattern as `check-secrets.sh` and the commit-format hooks.

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*
