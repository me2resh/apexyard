# AgDR-0200 — A config-listed external repo is exempt from the PR-title and branch-ticket gates

> In the context of adopters who contribute to upstream open-source projects as well as governing their own, facing a PR-create gate that applies this framework's `type(TICKET): description` convention to every target and so refuses a PR that is correct for its destination, I decided to add an opt-in `external_contributions` list in project-config that exempts a listed repo from the title-shape and branch-ticket checks only, with the registry winning and an ambiguous target failing closed, to make upstream contribution possible without a manual bypass, accepting that this is a config-driven relaxation of a trust-chain gate and that `validate-branch-name.sh` stays unchanged for now.

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

1. **`external_contributions` lives in `.claude/project-config.json`**, an array of `owner/name` slugs matched case-insensitively. The shipped default is `[]`, so a fork that never opts in behaves exactly as before. This mirrors `leak_protection.public_framework_repos`, which already classifies repos for hook behaviour from config.

2. **Scope is the title-shape check and the branch-ticket check**, both inside `validate-pr-create.sh`. #1448 asked for "title and branch conventions"; the branch-ticket check is the branch half that actually fires on a PR-create, and a contributor's branch lives on their own fork under the destination project's naming conventions.

3. **The registry wins, via the registry parser rather than a bespoke grep.** If a listed repo is also a managed project, the exemption does not apply. The first implementation hand-rolled a line-anchored grep and missed the inline `repos: [a, b]` and trailing-comment shapes, so a governed repo in both places *was* exempt — the documented guarantee was false. `_mrt_parse_registry` in `_lib-multi-repo-trace.sh` already normalises every supported shape, and is now the single source for this question.

4. **An unreadable registry fails closed.** If the parser is unavailable the target is treated as governed. An unreadable registry must not be indistinguishable from an empty one, because the second grants the exemption.

5. **An ambiguous target fails closed.** `CMD_REPO` comes from a quote-blind parser that reads a `--repo` token anywhere in the command text, including inside the quoted `--title` or `--body`. Before this exemption a wrong `CMD_REPO` only mis-aimed the ticket lookup; here it would remove the gate from a PR whose real target is the governed cwd repo — and a PR body quoting an upstream command is exactly the content this feature makes more likely, as well as an injection surface. So the exemption requires: quoted spans blanked, exactly one `--repo`/`-R` flag remaining, and the parsed slug appearing as that flag's value outside any quoted span. A slug merely *mentioned* in the title does not defeat a real flag.

6. **Security controls are out of scope.** Leak protection, secret scanning, and the private-refs hooks are untouched. They matter more for these repositories, not less, because they are usually public.

## Consequences

- An adopter can contribute upstream without a manual bypass, and the exemption is visible in config rather than in someone's shell history.
- Two places now hold repo knowledge. The registry remains authoritative for "governed"; this list only ever *removes* convention checks, and never overrides the registry.
- The ambiguity guard is a heuristic over command text, not a parsed argv, so escaped quotes can still defeat the quote-blanking step. It is used only to **refuse** an exemption, never to grant one, so its failure mode is a correct PR being refused rather than a gate being skipped. A structural `gh` argument parser would close it properly; that is a larger change than this exemption warrants.
- `validate-branch-name.sh` is unchanged. It fires on push, and a contributor pushes to their own fork, where their own conventions arguably apply. Revisit if an adopter reports being blocked there.
- The `## Testing` / `## Glossary` body-section requirement still applies to an external PR. The `<!-- pr-sections: skip -->` marker is the escape hatch, at the cost of putting a framework HTML comment into an upstream PR body. Left as-is deliberately: those sections improve any PR, and the marker is a visible, deliberate opt-out.

## Artifacts

- Issue: me2resh/apexyard#1448
- PR: me2resh/apexyard#1451
- Precedent: AgDR-0180 (registry `public: true` leak exemption)
- Rule: `.claude/rules/agdr-decisions.md` § rail 1 (trust-chain changes are material at any size)
