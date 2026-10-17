# AgDR-0200 — A config-listed external repo is exempt from the PR-title and branch-ticket gates

> In the context of adopters who contribute to upstream open-source projects as well as governing their own, facing a PR-create gate that applies this framework's `type(TICKET): description` convention to every target and so refuses a PR that is correct for its destination, I decided to add an opt-in `external_contributions` list in project-config that exempts a listed repo from the title-shape, branch-ticket, and body-completeness checks, with the registry winning, an ambiguous target failing closed (PR-create segment of the first line only; prior-chain / comment `--repo` ignored), and a self-list of the checkout's origin ignored, to make upstream contribution possible without a manual bypass, accepting that this is a config-driven relaxation of a trust-chain gate and that `validate-branch-name.sh` stays unchanged for now.

## Context

`validate-pr-create.sh` parses `--repo` for cross-repo PR creation but never consults the registry. Every `gh pr create` therefore gets the framework's title convention and its branch-ticket check, including a PR aimed at a repository the adopter does not govern and whose own `CONTRIBUTING.md` says something different.

There was no escape hatch. The observed workaround was for the agent to prepare the branch and hand the `gh pr create` command to a human to paste — four times across three upstream projects in a single session.

Rail 1 of `.claude/rules/agdr-decisions.md` makes any change to `.claude/hooks/**` material regardless of diff size, and this change relaxes a gate. AgDR-0180 (the registry `public: true` leak exemption) is the direct precedent for a config-driven, repo-scoped exemption in this trust chain.

## Options Considered

| Option | Pros | Cons |
|---|---|---|
| (a) Status quo — hand the command to a human | No gate surface changes | The agent cannot complete a normal contribution task; the bypass is manual, unrecorded, and trains operators to paste around gates |
| (b) Detect "not in the registry" and exempt automatically | No configuration to maintain | Silent and unbounded: every unregistered target would lose the check, including a typo'd slug or a repo the adopter forgot to register. A gate relaxation must be a deliberate, reviewable statement |
| (c) Put the list in `apexyard.projects.yaml` | One place for all repo knowledge | The registry means "what ApexYard manages", and these repos are definitionally unmanaged. It also gives the registry a second, contradictory sense of membership, which the registry-wins rail then has to disambiguate against itself |
| (d) **Opt-in `external_contributions` list in project-config, registry wins, ambiguous target fails closed** | Explicit and reviewable; ships inert; matches AgDR-0180's shape; keeps "governed" as one concept owned by the registry; the rail makes the dangerous configuration inert rather than merely discouraged | Two places hold repo knowledge; the adopter must maintain the list; the ambiguity guard is heuristic because the command text is not a parsed argv |

## Decision

Chosen: **(d)**.

1. **`external_contributions` lives in `.claude/project-config.json`**, an array of `owner/name` slugs (or URL / SSH forms that normalise to that) matched after normalisation. The shipped default is `[]`, so a fork that never opts in behaves exactly as before. This mirrors `leak_protection.public_framework_repos`, which already classifies repos for hook behaviour from config.

2. **Scope includes the title-shape check and the branch-ticket check**, both inside `validate-pr-create.sh`. #1448 asked for "title and branch conventions"; the branch-ticket check is the branch half that actually fires on a PR-create, and a contributor's branch lives on their own fork under the destination project's naming conventions.

For #1723, the exemption also skips required body sections and the Closes/Refs requirement because upstream projects use their own conventions.
The hook still checks multiple closing references and applies every other existing check.

3. **The registry wins, via the registry parser rather than a bespoke grep.** If a listed repo is also a managed project, the exemption does not apply. The first implementation hand-rolled a line-anchored grep and missed the inline `repos: [a, b]` and trailing-comment shapes, so a governed repo in both places *was* exempt — the documented guarantee was false. `_mrt_parse_registry` in `_lib-multi-repo-trace.sh` already normalises every supported shape, and is now the single source for this question.

4. **An unreadable registry fails closed.** If the parser is unavailable the target is treated as governed. An unreadable registry must not be indistinguishable from an empty one, because the second grants the exemption.

5. **An ambiguous target fails closed, keyed on the PR-create SEGMENT of the first line (#1451 B1 / B1-b / B1-c).** `CMD_REPO` comes from `pr_cmd_target_repo` on the continuation-joined command text — a quote-blind parser that can read a `--repo` token from a later body line or from a prior chained command. Quote-blanking is also line-oriented, so a multi-line `--body "$(cat <<EOF …)"` or stdin heredoc left a body `--repo` visible while the real create targeted the governed cwd. The exemption therefore requires: (a) exactly one `--repo`/`-R` on the **PR-create segment** of the first line — from the `gh pr create` invocation to the next unquoted `&&` / `||` / `;` / `|` or end of line, after quoted spans are blanked and a trailing unquoted `#` comment is stripped; (b) that segment value, resolved with the same `pr_cmd_target_repo` helper, normalises to the same `owner/name` as `CMD_REPO`. If either side cannot be resolved unambiguously, there is no exemption and the normal title/branch gates run. A prior `gh pr view --repo … &&` lookup, a trailing `# … --repo …` comment, or a slug merely *mentioned* inside quotes does not grant the exemption; a real `--repo` on the create segment followed by `&& echo done` still does.

6. **Repo references are normalised to lowercase `owner/name` before comparison (#1451 B2-b).** Both the CLI target and every external-list / registry entry strip scheme, `git@host:`, bare `host/`, trailing `.git`, and trailing `/`. An entry that does not normalise to exactly `owner/name` is ignored (with a stderr note). Without this, `https://github.com/o/r` and `git@github.com:o/r.git` never matched a registry slug, so a governed repo listed in URL form was incorrectly exempted.

7. **An external-list entry that normalises to this checkout's origin is ignored (#1451 A-2).** An ops fork that lists itself must not disable its own title check. The entry is skipped with a stderr note; other list entries still match normally.

8. **Security controls are out of scope.** Leak protection, secret scanning, and the private-refs hooks are untouched. They matter more for these repositories, not less, because they are usually public.

## Consequences

- An adopter can contribute upstream without a manual bypass, and the exemption is visible in config rather than in someone's shell history.
- Two places now hold repo knowledge. The registry remains authoritative for "governed"; this list only ever *removes* convention checks, and never overrides the registry.
- The ambiguity guard is a heuristic over command text, not a parsed argv. It is a **positive grant condition** (PR-create-segment target must resolve and equal `CMD_REPO`), not a refuse-only filter: when it cannot decide, the failure mode is still "no exemption" (a correct external PR may be refused) rather than a skipped gate on a governed create. Escaped quotes can still defeat the first-line quote-blanking step; a structural `gh` argument parser would close that properly and is a larger change than this exemption warrants.
- `validate-branch-name.sh` is unchanged. It fires on push, and a contributor pushes to their own fork, where their own conventions arguably apply. Revisit if an adopter reports being blocked there.
- The `## Testing` / `## Glossary` body-section requirement still applies to an external PR. The `<!-- pr-sections: skip -->` marker is the escape hatch, at the cost of putting a framework HTML comment into an upstream PR body. Left as-is deliberately: those sections improve any PR, and the marker is a visible, deliberate opt-out.

## Artifacts

- Issue: me2resh/apexyard#1448
- PR: me2resh/apexyard#1451
- Precedent: AgDR-0180 (registry `public: true` leak exemption)
- Rule: `.claude/rules/agdr-decisions.md` § rail 1 (trust-chain changes are material at any size)
