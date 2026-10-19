# Notes for the scaffold initiative (current: revision 5)

These notes sit beside the initiative record. The ORBIT v0.1 schema for that record type has no fields for constraints, decisions, dependencies or proof. The initiative record stays valid ORBIT. The record type and the file names keep the `plan-` prefix (AgDR-0226).

## Revision 5

Owner direction, 2026-10-19: do not create boilerplates for setup. The agent builds a current setup from the context, the information and the answers. It walks the owner through the pipeline, the environments when needed and a local run to test, as part of the flow. /scaffold is the base DevOps team for the project.

The owner chose three things on the same day:

- Retire the starters. Keep the floor as a set of checks that every generated project must pass.
- Use a guided setup that asks before each outward step. Cloud infrastructure stays a reviewed IaC draft and is never applied.
- Look up each version in the live registry at generation time, then pin it exactly.

The title changes to "Scaffold: a working DevOps base for every project". The intent follows the q2 answer.

### Challenge and CEO decisions

Naqid (The Contrarian) ran on this draft on 2026-10-19. The verdict was proceed-with-changes. The CEO decided these changes on the same day:

1. **The starter becomes a test fixture, retired last in o2.** The typescript-nextjs starter moves to a test fixture path, for example under `.claude/hooks/tests/fixtures/scaffold/`. CI uses it to prove the floor verifier. The generator never copies it into a project. The move happens only after a recorded generation run passes the verifier (ac2-19). ac2-18 stays, with two carve-outs: the fixture, and the verifier and handbooks that are copied verbatim.
2. **A framework-owned floor verifier.** Every generated project has a fixed set of gate scripts and a seeded-fault manifest (ac2-21). A framework verifier, copied verbatim, checks each gate (ac2-22). A placeholder gate fails the floor (ac2-23). A scheduled, non-blocking evaluation records the floor pass rate on canonical specs (ac2-24).
3. **Supply chain.** Use the newest version that is at least 7 days old in the configured registry (ac2-4, ac2-17). Exclude yanked and deprecated versions, and reject a new or near-zero-download package name (ac2-25). The package manager resolves peers for the full set (ac2-26). The local install runs with install scripts disabled (ac2-27).
4. **o10 enforcement.** A hook or an approval marker enforces each outward gh or git call, not the skill text alone (ac10-1). Each outward action targets only the repository that this run created (ac10-7). The remote is private by default (ac10-2). Branch protection adds a rule and never replaces an existing rule set (ac10-5). Hakim challenges o10 before its slice is cut. Open question 8 now needs an answer before o9.
5. **Order inside o2.** See `## Order`.

The CEO also decided the reconciliation change: starter-backed achieved o2 criteria become partially-verified until a generated project proves them. See "Record moves".

### Outcome changes

| Revision 4 outcome | Revision 5 outcome | Change |
|--------------------|--------------------|--------|
| o1-interview-sized-to-scale | o1-interview-sized-to-scale | No change. ac1-1 gets a shape-only edit. |
| o2-floor-and-recommended-path | o2-floor-checks-live-versions | Replaced. Floor checks and live versions replace the starter criteria. The new ID shows the new meaning. |
| o3-handover-gap-fill | o3-handover-gap-fill | The gaps are measured against the DevOps base (ac3-2). |
| o4-infra-and-cost | o4-infra-and-cost | The title drops "and budget", because ac4-1 asks no budget question. The intent drops the starter. |
| o5-more-stacks | No outcome | Dropped. See "Dropped outcome o5". |
| o6-fitness-functions | o6-fitness-functions | No change. |
| o7-entry-points | o7-entry-points | The remote part of ac7-2 moves to ac10-2. The title names registration instead of the remote. |
| o8-lessons-loop | o8-lessons-loop | A finding traces to the generation rules, not to the starter (ac8-1). |
| No source | o9-local-run-in-flow | New. ac2-10 moves here as ac9-1. |
| No source | o10-guided-pipeline-and-environments | New. The remote part of ac7-2 moves here as ac10-2. |

### Retired criteria

The evidence of each retired criterion stays in `docs/orbit/history/reconciliation-plan-apexyard-scaffold-20261013T205912Z.json`. Nothing is deleted.

| Revision 4 criterion | Revision 4 status | Disposition in revision 5 |
|----------------------|-------------------|---------------------------|
| ac2-2: "A rule table in the framework maps the spec to a golden path. In o2 the table holds typescript-nextjs with a starter. A spec that no golden path fits gets the custom start of ac2-16, not a stop." | achieved (#1722) | Retired. No stack has a starter now, so no spec maps to one. ac2-1 keeps the stack recommendation through the rules table. |
| ac2-4, the starter part: "The typescript-nextjs bundle ships a starter directory with a minimal source tree, its tool configuration and exact pinned versions. The bundle VERSION gets a minor bump." | achieved (#1722) | Retired. ac2-4 keeps exact pins for every dependency and adds the live registry lookup. Its status changes to not-verified. The audit before a pin is now ac2-7, inside the local floor run of ac2-20. |
| ac2-5, the copy part: "One copy script copies the starter, handbooks, CI files and topology anchor into workspace/<name>/." | achieved (#1716, #1722) | Retired with the starter. ac2-5 keeps the secrets check and adds placeholders only. |
| ac2-10: "One command migrates, seeds and starts the project locally. One command resets local data to the seed." | achieved (#1722) | Moved to ac9-1, which adds the install step. Its evidence carries, and ac9-1 is partially-verified. |
| ac2-16, the custom part: "The skill marks the project custom and drafts a golden-path request for the owner." | achieved (#1716) | Retired. Every stack is built from the answers, so no project is custom and no golden-path request is necessary. ac2-16 keeps the floor for every stack. |
| ac7-2, the remote part: "After the owner says yes, it creates the remote with a README-only default branch and opens the scaffold as a PR." | not-verified | Moved to ac10-2. ac7-2 keeps the registry entry. |

### Reworded criteria

| Criterion | Change |
|-----------|--------|
| ac2-9 | "the starter sets" becomes "the generated project sets". The baseline does not change. |
| ac2-11 | The framework floor verifier runs in framework CI against the clean test fixture and its seeded faults. |
| ac10-1, ac10-2, ac10-5 | CEO decision 4: hook or marker enforcement, a private remote by default, and no replaced rule set. |
| ac2-12 | "the generated typescript-nextjs project" becomes "a generated web project". |
| ac3-2 | The report compares the repository with the DevOps base, not the closest topology. |
| ac8-1 | "a starter fix" becomes "a rule fix", and "a new check" becomes "a new floor check". |
| ac1-1, ac2-1, ac3-1, ac4-1, ac4-2, ac7-6 | Shape only. Each now has at most two sentences of at most 25 words. The meaning does not change. |

### New criteria

| Criterion | Source |
|-----------|--------|
| ac2-17 | q5 constraint 4: no registry access means stop, never guess. CEO decision 3 names the configured registry. |
| ac2-18 | q4 principle 1: no template files copied. CEO decision 1 names the carve-outs: the test fixture, the verbatim floor verifier and the handbooks. |
| ac2-19 | q4 principle 7: the #1722 starter is removed from projects. CEO decision 1 keeps it as a CI test fixture. |
| ac2-20 | q4 principle 3: the floor checks pass locally before any remote step. CEO decision 2 makes the floor verifier the check. |
| ac2-21 to ac2-24 | CEO decision 2: the framework-owned floor verifier and the scheduled evaluation. |
| ac2-25 to ac2-27 | CEO decision 3: supply-chain rules. ac2-4 adds the 7-day minimum age. |
| ac9-1 to ac9-4 | q3 outcome "a local run in the flow" and q4 principle 4. |
| ac10-1 to ac10-6 | q3 outcome "a guided pipeline and environments", q4 principles 5 and 6, and q5 constraints 2 and 3. |
| ac10-7 | CEO decision 4: outward actions target only the repository that this run created. |

### Dropped outcome o5

o5-more-stacks added python-fastapi and go-data-pipeline starters. With no starters, the agent builds any stack from the answers, so the outcome has no work left. Its six criteria were all not-verified, so no evidence is lost.

| Criterion | Why it is dropped |
|-----------|-------------------|
| ac5-1 | The rules table already recommends a stack for each shape (ac2-1). The summary already shows a language clash with the company setup. |
| ac5-2 | It listed composed shapes as gaps. Open question 5 closes with it. |
| ac5-3 | More starters go against the owner direction. |
| ac5-4 | ac2-6 and ac2-16 apply the floor gates to every stack. |
| ac5-5 | No copy script remains to share with /handover. o3 shares the interview and the floor checks instead. |
| ac5-6 | A scoring script for each bundle has no bundle starters to score. ac2-12 and ac3-5 keep the harnessability measure. |

### Record moves

- The revision 4 record moves to `docs/orbit/history/`.
- The three revision 4 reconciliations move to `docs/orbit/history/`. The validator needs each active reconciliation to reference the current revision.
- `slice-scaffold-o2-starter` merged in #1722 and moves to `docs/orbit/history/`.
- A new snapshot and reconciliation at upstream dev cee2d23 record the revision 5 statuses: 9 achieved, 10 partially-verified and 49 not-verified.
- After the challenge, these criteria change from achieved to partially-verified, because their evidence depends on the starter: ac2-5, ac2-6, ac2-7, ac2-8, ac2-9, ac2-11 and ac2-16. ac2-7 and ac2-16 copy their gate scripts from the starter.
- ac2-14 also changes to partially-verified. Hakim reviewed a scope with fixed write paths and a never-push rule. Revision 5 adds generated paths and confirmed outward steps, so Hakim must review the scope again.
- ac2-1, ac2-3, ac2-13 and ac2-15 stay achieved. Their evidence does not depend on the starter.

## Revision 4

Owner direction, 2026-10-13: the initiative name must be clear in the ORBIT pane. The pane shows only the first words of a title.

- The title changes to "Scaffold: start every project at one quality floor". The old title was "Start or catch up a project from a golden path, through an interview sized to its scale".
- ac2-16 drops the words "to file", so it has 50 words, the limit. Its meaning does not change.
- The intent, the outcomes, the other criteria and the constraints do not change.
- The owner chose to skip the Naqid challenge for this revision, because it changes only the title and two words.

## Revision 3

Owner direction, 2026-10-13, after a live test run of the first interview: ask where the project runs first, then recommend the technology and the pipeline. Remove the cost, currency and test questions. Keep the interview simple, but effective for infrastructure and pipelines.

A roundtable of the platform, UX, architecture and product roles, with a contrarian, converged on the design. AgDR-0238 records it. The owner approved it on the same day, with two more decisions: Netlify is the default managed hosting service, and outcome o4 shows a rough cost range with no budget question.

Criterion changes in revision 3:

| Criterion | Change |
|-----------|--------|
| ac1-1 | Host first, not scale first. A demo asks 3 questions, a small product 4, a production service 5. |
| ac1-5 | Adds the answer sources default and derived. |
| ac2-1 | A rules table recommends the stack and the pipeline from the host and the shape. Language, coverage floor and design become defaults. |
| ac4-1 | No cost, budget or currency question. Scale comes from who uses the project. |
| ac4-2 | A host of none yet gives an open question, not a draft. |
| ac4-5 | A rough cost range, with no budget question and no budget comparison. |
| ac4-6 | The price table serves the cost range. |
| ac5-1 | The language comes from the golden path. The summary shows a clash with onboarding. |
| ac6-2 | The page-size budget is a default of 500 KB that the owner can change. |

## Revision 2

Owner direction, 2026-10-13: /scaffold is a framework skill. It serves new projects and /handover. The interview depth follows the project's scale. Every question offers a recommended answer with a plain reason. Many adopters are not engineers.

The owner also decided that the skill is not tied to the golden paths. A few tested golden paths stay as the recommended options. Any other stack gets a custom start with the stack-agnostic floor (ac2-16). Next.js is the first starter only because it exists today and scores high on all five harnessability dimensions.

The owner also replaced owner decision 3: the build starts when these records merge, not after the 6 Nov scope freeze.

On 2026-10-12, the owner included the scaffold in the first project plan. A reference project then showed the gaps below. /handover is a second consumer, so the skill needs its own initiative. The owner closed the retirement PR (#1696) without a merge. The owner closed #1697 as superseded.

Lessons from a reference project:

- The interview did not ask for design direction or deployment target (ac2-1).
- A generator pinned a framework version with critical advisories (ac2-4, ac2-7).
- An ORM failed because the build environment blocked install scripts and network access (ac2-8).
- The team added the security baseline only after review (ac2-9).
- One-command start and reset helped demos (ac2-10).

Revision 2 adds o1 and o8. Revision 1 o1 becomes o2 with new criteria. Retrofit mode moves from o6 to o3 and becomes handover gap-fill.

| Revision 1 outcome | Revision 2 outcome |
|--------------------|--------------------|
| o1-nextjs-thin-path | o2-floor-and-recommended-path |
| o2-more-stacks | o5-more-stacks |
| o3-fitness-functions | o6-fitness-functions |
| o4-infra-and-cost | o4-infra-and-cost |
| o5-entry-and-handoff | o7-entry-points |
| o6-retrofit-mode | o3-handover-gap-fill |
| No source | o1-interview-sized-to-scale |
| No source | o8-lessons-loop |

Criterion changes. Revision 1 criteria that are not in this table moved word for word under the outcome mapping above. The only edits are renumbered cross-references (ac5-4, ac5-5) and the term gap-fill for retrofit (ac3-1 to ac3-5).

| Revision 1 | Revision 2 | Change |
|------------|------------|--------|
| ac1-1 | ac2-1, ac1-2 | Split. ac2-1 holds the questions and adds deployment target and design direction. ac1-2 holds one question at a time, AskUserQuestion and the recommended answer with a reason. |
| ac1-1 | ac1-3 | The clause "each question accepts the answer unknown" becomes "Not sure, recommend for me", which records the recommendation and its reason. |
| ac1-2 | ac1-4 | No change. |
| ac1-3 | ac1-5 | "Records unknown, never guesses" becomes "records the source of each answer". A recommendation is recorded as recommended (ac1-3), never as a silent guess. |
| ac1-4 | ac2-2, ac2-16 | A spec that no golden path fits gets the custom start, not a stop. |
| ac1-6 | ac2-4 | Adds exact versions for every dependency and an audit of generator versions. |
| ac1-5, ac1-7 to ac1-13 | ac2-3, ac2-5, ac2-6, ac2-11 to ac2-15 | No change. |
| No source | ac1-1, ac2-7 to ac2-10, ac3-6, ac8-1, ac8-2 | New in revision 2. |

ac4-1 and ac1-3 do not conflict. ac4-1 covers scale, budget and compliance facts: the skill never guesses a fact. ac1-3 covers choices: the owner can accept a recommended choice. In these notes, golden path means a topology bundle, and handover gap-fill is the revision 2 name for retrofit mode.

## Interview

- 2026-10-13, q1-outcome: Any project, new or handed over, gets its missing foundations through one /scaffold interview. Its depth matches the project's scale. Every question offers a recommended answer.
- 2026-10-13, q2-intent: Both audiences. Engineers get golden-path foundations without setup work. Non-engineers get safe, explained defaults. Every project starts or catches up to the same quality floor.
- 2026-10-13, q3-outcomes: Eight outcomes, with handover gap-fill early. o1 interview sized to scale, o2 hardened Next.js starter, o3 handover gap-fill, o4 infra and cost draft. o5 more stacks, o6 fitness functions, o7 entry points, o8 lessons loop. Amended the same day: the interview recommends among a few tested golden paths. Any other stack gets a custom start with the stack-agnostic floor.
- 2026-10-13, q4-acceptance: Keep the revision 1 criteria under the new outcomes. Add criteria for scale, recommendations, design, deployment, audited pins, build-environment check and security baseline. Also add one-command start, gap sizing and the lessons loop.
- 2026-10-13, q5-constraints: Keep the revision 1 constraints. Add: no project names in framework text or records. Use recommendations in plain language for non-engineers. Handover gap-fill never overwrites a file without a yes for that file.
- 2026-10-13, q6-save: Save revision 2 as drafted.
- 2026-10-13, q1-outcome (revision 3): Unchanged. The owner added: the interview must be simple but effective at producing good infrastructure and pipelines.
- 2026-10-13, q2-intent (revision 3): Unchanged.
- 2026-10-13, q3-outcomes (revision 3): Unchanged. The eight outcomes stay.
- 2026-10-13, q4-acceptance (revision 3): Ask where the project runs first and recommend the technology and pipeline. Remove the cost, currency and test questions. Amend ac1-1, ac1-5, ac2-1, ac4-1, ac4-2, ac4-5, ac4-6, ac5-1 and ac6-2.
- 2026-10-13, q5-constraints (revision 3): Netlify is the default managed hosting service. Outcome o4 shows a rough cost range and asks no budget question.
- 2026-10-13, q6-save (revision 3): Apply the converged roundtable design, with a plan amendment and a short AgDR.
- 2026-10-13, q1-outcome (revision 4): Unchanged. The owner chose the clear title "Scaffold: start every project at one quality floor".
- 2026-10-13, q2-intent (revision 4): Unchanged.
- 2026-10-13, q3-outcomes (revision 4): Unchanged. The eight outcomes stay.
- 2026-10-13, q4-acceptance (revision 4): Unchanged, except that ac2-16 is shortened to 50 words with the same meaning.
- 2026-10-13, q5-constraints (revision 4): Unchanged.
- 2026-10-13, q6-save (revision 4): Save revision 4 and skip the Naqid challenge, because only the title and two words change.
- 2026-10-19, q1-outcome: Every new project starts with a working DevOps base: a current stack, a CI pipeline, environments when needed, and a local run the user tests in the flow. The agent builds it from the answers, not from a boilerplate. Existing repos brought in by /handover get the same DevOps base through a gap-fill PR.
- 2026-10-19, q2-intent: /scaffold acts as the project's base DevOps team. It builds the setup from context and answers with live current versions, walks the user through each step, and every project passes the same quality-floor checks.
- 2026-10-19, q3-outcomes: Revised set of 9. Keep: interview sized to scale, infra and cost draft, handover gap-fill, fitness functions, entry points, lessons loop. Replace the starters with: the generated setup passes the floor checks (live versions, exact pins). Add: a local run in the flow; a guided pipeline and environments (each outward step confirmed, first CI run green). Drop: more-stacks.
- 2026-10-19, q4-acceptance: Seven principles: no template files copied; versions come from a registry lookup at generation time with the source recorded; floor checks pass locally before any remote step; the local run is shown working; each outward action asks first; the first remote CI run is green; the #1722 starter is removed.
- 2026-10-19, q5-constraints: 1) Never apply cloud infrastructure; the IaC stays a reviewed draft. 2) Never write a real secret; only named placeholders and the user's own secret-store step. 3) Each outward action (repo, environments, branch protection, CI secrets) asks first. 4) No registry access means stop and say so, never guess versions. 5) /scaffold stays a framework skill, sized to scale. 6) One slice = one ticket = one PR.
- 2026-10-19, q6-save: Save r5 and open PR. Naqid ran on the draft (proceed-with-changes); the CEO's decisions 1-5 are applied.

## Where the initiative comes from

Owner intent, 2026-10-12: a new skill scaffolds a new project. It reads the golden-path directory, finds a template and pipelines, and customises the project after an interview. The interview covers best practices, fitness functions, quality gates, technology, IaC, cost and scale.

Evidence read on upstream/dev at 2854837, and checked again at 0eda785:

- `topologies/README.md` and the three bundles (`typescript-nextjs`, `python-fastapi`, `go-data-pipeline`). Each bundle holds handbooks, one CI file and one AgDR template. No bundle holds starter source code or tool configuration. ac2-4 and ac5-3 add a starter directory for this reason.
- Only `/handover` step 1.5 and step 5.5 pick and copy a bundle today. A new project has no path to a bundle except through `/handover` on an empty repository.
- `golden-paths/` holds only `pipelines/`. `golden-paths/typescript/` does not exist yet. The harness golden-path initiative o5 creates it.
- `golden-paths/pipelines/terraform-ci.yml` runs `terraform apply -auto-approve` on push to `main`. A copied file would apply on the first merge. ac4-4 keeps the apply job off.
- `golden-paths/pipelines/code-quality.yml` and `topologies/typescript-nextjs/golden-paths/nextjs-ci.yml` have no coverage floor. The FastAPI and Go CI files fail below 80 percent. The Next.js bundle-size check only warns.
- `/handover` step 4.5 scores harnessability on five dimensions (AgDR-0042). Its framework-opinionation table rates FastAPI and Go Gin or Echo as moderate. Only typescript-nextjs can score high on all five dimensions (ac2-12, ac5-6).
- `.claude/skills/handover/tests/test_harnessability_scoring.sh` greps SKILL.md and runs no scoring. ac5-6 adds an executable scoring script for this reason.
- `/onboard` step 4b registers a new project with no assessment and no bundle. ac7-1 makes `/scaffold` the recommended path there.
- `/walking-skeleton` asks for the layers and the deploy target. The spec already holds both, so ac7-3 passes them as defaults.
- `bootstrap_skills` in `.claude/project-config.defaults.json` lists setup, handover, update, split-portfolio, onboard and tutorial. ac2-14 adds scaffold.
- No Terraform module template and no price table exist in the repository. o4 has the agent write the infrastructure draft from the spec, not from a template library.
- The initiative record schema (orbit-spec `schema/plan.schema.json`) has no proof field. Each criterion holds only the condition. The table below holds its proof (direction of me2resh/apexyard#1618).

## Owner decisions

Owner decisions, 2026-10-12:

1. **Replaced in revision 2 (see Revision 2).** **Slice 1 is a thin end-to-end slice for typescript-nextjs only.** It includes four interview questions: service shape, language, host and coverage floor. It selects a topology and generates a working project with CI and gates. Other stacks and the full interview come in later slices. o2 holds this slice.
2. **Infra and cost stay in this initiative as a later outcome (o4).** Also when no starter template exists for a stack, the agent recommends best-practice infrastructure and a cost estimate. The estimate matches the project's scale and budget. The agent writes both as a draft and never applies them. The estimate uses a static price table with a price date and a "not a quote" statement (ac4-6). Generated Terraform strings get an ASCII-only check (ac4-3).
3. **Replaced in revision 2 (see Revision 2).** **Build starts after the 6 Nov scope freeze.** The records can merge now. No build ticket opens before 6 Nov.
4. **Records PRs use an `orbit/<initiative>-<slug>` branch with no ticket (#1673).** Only the next slice gets a ticket, after its slice record merges.

5. **/scaffold has four entry points.** Each entry point offers /scaffold and starts nothing without the owner's yes. A no leaves no files.
   - After /write-spec produces an approved PRD for a new product, it offers /scaffold. The interview reuses PRD answers and asks only for gaps.
   - For a new fork, /onboard recommends /scaffold when the owner selects start a new project. The interview reuses recorded answers.
   - An ORBIT slice handoff offers /scaffold when it needs a new repository. The spec uses initiative outcomes and constraints without repeating recorded questions.
   - For an existing repository, /handover offers retrofit mode against the closest golden path. It proposes missing CI pipelines, quality gates and fitness functions.
   - Retrofit changes use a branch and PR. The skill never overwrites an existing file without the owner's yes. The report records harnessability before and after.
   - Retrofit mode is the later outcome o3.

Owner decision, 2026-10-19:

6. **The agent builds the setup, not a boilerplate.** The starters retire, and the floor stays as checks. A guided setup asks before each outward step. Cloud infrastructure stays a reviewed IaC draft. Each version comes from a live registry lookup, then gets an exact pin. This replaces the starter part of open question 1 and of decision 2.
7. **The Naqid challenge changes, 2026-10-19.** The starter becomes a CI test fixture and retires last in o2. A framework-owned floor verifier checks every project. Versions follow supply-chain rules with a 7-day minimum age. A hook or a marker enforces each outward call in o10. See "Challenge and CEO decisions" in Revision 5.

## Challenge disposition

Naqid (The Contrarian) returned "proceed-with-changes" with 16 changes on the first draft. Revision 1 applies 15 and rejects 1.

This challenge disposition applies to revision 1.

| Naqid change | Disposition |
|--------------|-------------|
| 1. Harnessability high for typescript-nextjs only | Applied: ac2-12 and ac5-6. |
| 2. The scoring test runs no scoring | Applied: ac5-6 adds an executable scoring script. The o2 slice records a /handover step 4.5 run as the proof of ac2-12. |
| 3. ac6-2 shared code against C9 | Applied: revision 1 accepts the /handover refactor with a regression test (ac5-5). C9 now says so. |
| 4. Slice 1 as a thin vertical | Applied: owner decision 1, outcome o2. |
| 5. Cut the interview to four questions | Applied: ac2-1 and ac1-2. Each later question moves to the outcome that needs its answer (ac5-1, ac6-2, ac4-1). |
| 6. A rule table, not a ranking script | Applied: ac2-2 and ac5-1. |
| 7. Remove latency and cost CI budgets | Applied: ac6-2 keeps the bundle-size budget only. |
| 8. Move IaC and cost to another initiative | Rejected: owner decision 2 keeps them here as o4. The agent writes the draft from the spec, so no Terraform library is needed first. |
| 9. ASCII-only check on .tf strings | Applied: ac4-3. |
| 10. Static price table, price date, not a quote | Applied: ac4-6, with the 6-month CI check. |
| 11. One AgDR for the scaffold | Applied: ac2-13. |
| 12. Bootstrap scope review | Applied: ac2-14 requires a Hakim review. Open question 5 stays open until o7, because o2 creates no remote. |
| 13. Limit the fixture toolchains, record CI time | Applied: ac2-11 and ac5-4. |
| 14. Starter maintenance | Applied: exact pinned versions (ac2-4, ac5-3). The ac2-11 fixture test proves that the starter still builds. |
| 15. Settle the timing before slice 1 | Applied: owner decision 3. |
| 16. Name the cheaper alternative | Applied: see "Baseline to beat". |

## Baseline to beat

Revision 5: the baseline is a generic agent prompt that writes a project with no floor checks, no recorded version source and no guided pipeline. /scaffold must add the local floor run, the live version record, the local run in the flow and a green first CI run.

Revision 1 to revision 4 baseline:

The cheaper alternative is this: `/onboard` step 4b calls `/handover` step 1.5 and step 5.5 on the empty repository. Starter directories and a coverage floor in `nextjs-ci.yml` complete it. Slice 1 must deliver more than that path does. The path adds a spec file, a rule table with reasons and seeded-fault proof. It also adds bootstrap scope without a ticket first.

## Constraints

- **C1. No secrets in generated files.** Generated CI names a secret only by reference, for example `secrets.AWS_CI_ROLE_ARN`. An env example file holds named placeholders only. The owner puts each real value in the secret store. The generated tree passes `check-secrets.sh` (ac2-5, ac10-4).
- **C2. No outward action without the owner's yes.** The skill asks before each outward action: the remote repository, `git push`, environments, branch protection, CI secrets and tracker writes. It runs each one only after an explicit yes for that step. A hook or an approval marker enforces the yes, and each action targets only the repository that this run created (ac10-1, ac10-7).
- **C3. The scaffold goes through review.** After the owner's yes, the remote starts with a README-only default branch. The skill proposes the scaffold on a branch as the first PR, with Rex and the other merge gates. The skill never pushes the scaffold to the default branch.
- **C4. IaC is never applied by the skill.** The skill runs no `terraform apply`, no `terramate run` that applies, and no cloud write call. It needs no cloud credentials (ac4-7). Generated Terraform CI keeps its apply job off until the owner turns it on (ac4-4).
- **C5. The skill writes in ASD-STE100.** It reads `.claude/rules/writing-standard.md` before it writes a durable file. Each generated Markdown file passes `bin/check-writing-profile.sh` (ac2-15).
- **C6. Framework governance wins.** No slice bypasses tickets, reviews, review markers or merges. The bootstrap exemption covers only the paths that ac2-14 names.
- **C7. One slice, one ticket, one PR.** Each outcome has one open slice at a time. A fault found inside a slice is a step in that slice.
- **C8. Reuse, do not fork.** `/scaffold` and `/handover` gap-fill share one interview, one set of generation rules and one set of floor checks. The agent reads `golden-paths/pipelines/` and the bundles as reference and writes each file new (ac2-18). Revision 5 drops the shared copy script of revision 4.
- **C9. Opt-in for adopters.** Each entry point needs the owner's yes before /scaffold starts. `/onboard` keeps its light registration (ac7-1). `/handover` keeps its default behaviour. Gap-fill mode needs a separate yes (o3).
- **C10. Every price is dated and is not a quote.** The price table carries a price date. Each generated estimate shows that date and says that the figures are not a quote (ac4-6).
- **C11. No project names.** Framework text and records use no project names. Use "a recent project" or "a reference project" when needed.
- **C12. Plain-language recommendations.** Each recommendation gives a plain reason that a non-engineer can understand (ac1-2).
- **C13. No overwrite without a per-file yes.** Handover gap-fill needs the owner's explicit yes for each existing file before it overwrites that file (ac3-4).
- **C14. No guessed versions.** When the lookup in the configured registry fails, the skill stops and tells the owner. It never writes a version from memory (ac2-17). Each version is at least 7 days old (ac2-4).
- **C15. One framework skill, sized to scale.** `/scaffold` stays a framework skill for every project. The interview and the setup depth follow the scale (o1).

## Overlaps

### Harness golden-path initiative (revision 3)

- **o5 (DDD boundaries).** It owns the dependency-cruiser config in `golden-paths/typescript/` and the step in `code-quality.yml`. This initiative reuses that config for TypeScript projects (ac6-1) and does not rebuild it. This initiative adds the layer check for Python and Go only.
- **o6 (logging standard).** It owns the logging rule, `handbooks/general/logging.md` and the Logger port example. A generated TypeScript backend copies that port when o6 has shipped. This initiative sets no logging criterion of its own.
- **o2 and o3 (Cursor and Codex gates).** No overlap. `/scaffold` runs in any harness that runs the other skills.
- **o1 (fail-closed gates).** No overlap. The bootstrap exemption in ac2-14 uses the existing marker and the ticket-first gate as they are.

### Skills

- **`/handover`.** It adopts an existing repository. `/scaffold` starts a new one. Both use the same interview and floor checks (C8). The harnessability assessment is the acceptance test (ac2-12, ac3-5).
- **`/onboard` step 4b.** It registers a new project with no bundle. ac7-1 adds `/scaffold` as the recommended option.
- **`/walking-skeleton`.** It files the first kept slice. `/scaffold` makes the repository that slice lands in, and it stops before any feature code. The hand-off is ac7-3.
- **`/setup`.** It records the company stack in `onboarding.yaml`. `/scaffold` reads it and does not ask again (ac1-4).
- **`/validate-idea`, `/write-spec` and `/tech-vision`.** They own the product case, the PRD and the target architecture. `/scaffold` reads a PRD when one exists (ac1-4). It asks product questions only to size the stack, not to write a PRD.
- **Token-efficiency initiative.** No overlap. The new skill body follows the lean-skill rules of its o6.

## Outcomes

| Outcome | Result | Criteria |
|---------|--------|----------|
| o1-interview-sized-to-scale | The interview matches project scale and recommends an answer for each question. | 5 |
| o2-floor-checks-live-versions | The agent builds the setup from the answers with live current versions. A framework verifier proves the floor checks, and the starter stays only as a test fixture. | 25 |
| o3-handover-gap-fill | Handover gap-fill adds the missing DevOps base through a PR, with gap sizes from project scale. | 6 |
| o4-infra-and-cost | The skill writes an infrastructure draft and a monthly cost estimate. It never applies infrastructure. | 7 |
| o6-fitness-functions | Generated CI checks layer boundaries and bundle size. A fitness-functions file lists the gates and their source answers. | 4 |
| o7-entry-points | Entry points reuse answers and offer /scaffold. The scaffold registers the project and offers /walking-skeleton. | 8 |
| o8-lessons-loop | Review findings produce scaffold changes and anonymous changelog lines. | 2 |
| o9-local-run-in-flow | The skill starts the project locally in the flow, and the owner sees it work. | 4 |
| o10-guided-pipeline-and-environments | The skill guides the remote, the pipeline and the environments, asks before each outward step, and the first CI run is green. | 7 |

## Proof

The initiative record schema has no proof field, so the proof for each criterion is here (direction of me2resh/apexyard#1618). The revision 4 proof table is in the git history of this file.

- ac1-1: Fixture runs ask the host first. The question counts are 3, 4 and 5 for demo, small and production.
- ac1-2: A fixture transcript shows the recommended answer first for each question, with one plain sentence that gives its reason.
- ac1-3: A fixture transcript selects 'Not sure, recommend for me'. The spec records the recommended value, its reason and the recommended mark.
- ac1-4: A fixture with a filled tech_stack block, where the transcript skips those questions.
- ac1-5: The schema file, and a test that validates a good and a bad spec. The valid spec includes the default and derived sources.
- ac2-1: The rules table, a --derive test for each row, and the summary text that shows the defaults. A none-yet host writes an open question.
- ac2-3: The skill text, and a spec written after an override.
- ac2-4: A generation run records each version, its registry source and its publish date. Each version is the newest at least 7 days old. A manifest check confirms exact versions.
- ac2-5: `check-secrets.sh` output on a generated tree, and a test with a planted secret. The env example file holds named placeholders only.
- ac2-6: The generated CI file, and the ac2-11 test.
- ac2-7: A fixture with a seeded vulnerable production pin fails the audit for high and critical advisories. A clean fixture passes.
- ac2-8: Build-environment fixtures block install scripts and network access. Each AgDR records the failed check and the selected fallback.
- ac2-9: Tests in a generated web project check HttpOnly, SameSite and the Secure rule. Route tests enforce JSON-only state changes and problem+json errors with stable codes.
- ac2-11: The framework CI job runs the floor verifier on the clean test fixture and on each seeded fault, and the PR records the CI time.
- ac2-12: A recorded `/handover` step 4.5 run on a generated web project, in the PR.
- ac2-13: The generated AgDR file in the fixture run.
- ac2-14: `bootstrap_skills` in the defaults file, the bootstrap scope section, a hook test and the Hakim review on the PR.
- ac2-15: `bin/check-writing-profile.sh` output, and the docs diff with the skill counts.
- ac2-16: A generated project for a stack with no topology bundle has each floor gate, the exact-pin check and the security baseline notes.
- ac2-17: A test runs generation with the configured registry blocked. The skill stops with a plain message and writes no version.
- ac2-18: A test confirms that no generated file comes from a starter or template directory, except the verifier and the handbooks. A run transcript shows each written file and its source answer.
- ac2-19: The diff moves `topologies/typescript-nextjs/starter` to the test fixture path. A search finds no copy step in the generator. The PR cites the recorded generation run that passed the verifier.
- ac2-20: A run transcript shows the floor verifier passing on the local tree before the first remote offer. A test with a failing gate shows no remote offer.
- ac2-21: A generated fixture project has the six gate scripts and a seeded-fault manifest that names one fault for each gate.
- ac2-22: Verifier output on a generated project shows each gate passing clean, failing on its fault and using the spec threshold. A checksum shows the verifier is unchanged.
- ac2-23: A fixture with a placeholder gate that always passes makes the verifier fail the floor.
- ac2-24: The scheduled workflow is non-blocking, uses the canonical specs and writes the floor pass rate for each run.
- ac2-25: Lookup tests with a yanked version, a deprecated version and a new low-download package name. Each case is excluded or rejected with a message.
- ac2-26: A fixture with a peer conflict shows the package manager resolving the full set in one step.
- ac2-27: The local install command in the generated project disables install scripts, for example `npm ci --ignore-scripts`.
- ac3-1: Accept and decline /handover gap-fill transcripts, with a file comparison that shows no writes after a no.
- ac3-2: A fixture gap report lists missing floor checks, CI pipeline steps, environments and local run steps, each with a reason.
- ac3-3: The proposed branch diff and PR from an accepted gap-fill fixture.
- ac3-4: A fixture with existing files, explicit file approvals and a diff proving unapproved files were not overwritten.
- ac3-5: The fixture report with before and after scores for all five harnessability dimensions.
- ac3-6: A gap report assigns must, should or later from scale. A fixture transcript asks only about gaps and recommends each answer.
- ac4-1: The question bank and a test that no question asks about cost, budget or currency.
- ac4-2: The draft recommendation for an AWS spec, for a host with no IaC template, and the open question for a none-yet host.
- ac4-3: `terraform validate`, `tflint` and ASCII check output in framework CI, and a seeded non-ASCII fault.
- ac4-4: The generated CI file, and a test that no apply job runs by default.
- ac4-5: The generated cost range for a small and a production spec, with drivers and assumptions and no budget comparison.
- ac4-6: The price table, the not-a-quote line in each cost range, and the price-date CI check.
- ac4-7: A search test over the skill text and scripts for apply and cloud write calls.
- ac6-1: The generated CI files and layer-check configs for each topology.
- ac6-2: A web spec with the 500 KB default, a spec with a changed budget, and the CI step that fails above it.
- ac6-3: The generated fitness-functions file in each fixture run.
- ac6-4: The fixture test in framework CI.
- ac7-1: A new-fork transcript that selects start a new project and shows the recommended /scaffold offer.
- ac7-2: The registry validation output for the new entry.
- ac7-3: The skill text, and the `/walking-skeleton` defaults in a fixture run.
- ac7-4: An approved new-product PRD and a transcript that offers /scaffold and asks only for missing answers.
- ac7-5: Accept and decline transcripts after /write-spec, with a file comparison that shows no writes after a no.
- ac7-6: An /onboard transcript that skips recorded answers, plus accept and decline runs with no files after a no.
- ac7-7: An ORBIT slice handoff needing a repository, its derived spec and a transcript that skips recorded answers.
- ac7-8: Accept and decline ORBIT handoff transcripts, with a file comparison that shows no writes after a no.
- ac8-1: A fixture review finding traces to a generation rule or the interview. Its scaffold diff adds a rule fix, a question or a floor check.
- ac8-2: A lessons-loop change adds a changelog line that names the finding class. A check confirms that the line contains no project name.
- ac9-1: The generated README gives one command to install, migrate, seed and start. A fixture runs it from a clean clone and tests one-command reset.
- ac9-2: A transcript with one required tool missing names that tool and its install step.
- ac9-3: A run transcript shows the start command output. For a web shape, it shows the local address and a passing health check.
- ac9-4: A fixture with a seeded start fault shows the fault message and no remote offer.
- ac10-1: A hook test blocks each outward gh or git call without an approval marker. Transcripts show one confirm for each outward action, with what it changes.
- ac10-2: A recorded live run: the new remote is private, has a README-only default branch, and has the generated setup open as the first PR.
- ac10-3: Transcripts for a demo and a production spec show the proposed environments. The repository settings show only the confirmed environments.
- ac10-4: `check-secrets.sh` output on the first PR, and a transcript that names each secret and guides the owner's own secret-store step.
- ac10-5: A recorded live run on a repository with an existing rule set shows that rule set unchanged and the new rule added. A decline transcript shows unchanged settings.
- ac10-6: The first CI run on the first PR is green in a recorded live run. A fixture with a seeded fault shows the failed check and a proposed fix.
- ac10-7: A hook test blocks an outward call to any repository other than the one this run created.

## Order

Revision 5 order, 2026-10-19:

1. o1 is achieved.
2. The next slice is o2. Its steps run in this order (CEO decision 5):
   1. Prove the floor verifier contract against the starter as a test fixture (ac2-21 to ac2-23, ac2-11).
   2. Add the live version lookup with the 7-day age gate and the supply-chain rules (ac2-4, ac2-17, ac2-25 to ac2-27).
   3. Generate from the answers. The generated project passes the verifier, with a recorded run (ac2-18, ac2-20, ac2-22).
   4. Move the starter to the test fixture path last (ac2-19).
3. Then o9 adds the local run in the flow. It needs a generated project from o2.
4. Then o10 adds the guided pipeline and environments. It needs a project that passes the floor checks and runs locally. Hakim challenges o10 before its slice is cut.
5. o3 follows o10, because gap-fill brings an existing repository to the same DevOps base. o4 follows o3.
6. o6 adds fitness functions. Its TypeScript part waits for harness o5.
7. o7 follows, because the entry points start the full flow and read its spec fields.
8. o8 runs after the first generated project gets a review.

Revision 4 order, for the record: o1 and o2 first, then o3, o4, o5, o6, o7 and o8. The first slice was `slice-scaffold-o1-interview`.

## Dependencies

- Harness golden-path initiative o5 (`slice-harness-o5-ddd-boundaries`) for ac6-1 on TypeScript.
- Harness golden-path initiative o6 for the Logger port in a generated TypeScript backend.
- AgDR-0048 (topology bundles). Revision 5 removes the starter directory again. The next o2 slice records the change in one new AgDR for generation from answers and live versions.
- AgDR-0240 (scaffold starter local store). It chose the local store for the starter. The next o2 slice marks it superseded when it removes the starter.
- AgDR-0042 (harnessability dimensions), AgDR-0011 (bootstrap exemption), AgDR-0077 (walking skeleton).
- AgDR-0226 (Initiative terminology, proposed). This record migrates with the others when that AgDR is built.
- #1673 for the records branch rule in owner decision 4.

## Open questions for the owner

1. **Starter source: replaced in revision 5.** No starter remains. Each version comes from a live registry lookup, with an exact pin and an audit (ac2-4, ac2-7). Revision 4 used a starter directory with audited exact pins.
2. **Boundary tools for Python and Go.** Proposal: import-linter for Python and depguard inside golangci-lint for Go. Each needs a framework decision before o6.
3. **Ticket for the first PR.** The new repository has no tracker issue before the scaffold PR. Proposal: after the owner's yes, the skill files one Task in the new repository through `tracker_create`. The PR names that Task. Answer before o10.
4. **Registry status.** `/onboard` writes `active` and `/handover` writes `handover`. Which status does a scaffolded project get? Answer before o7.
5. **Composition: closed in revision 5.** o5 is dropped. A web plus pipeline shape stays out of scope, as AgDR-0048 says.
6. **Question sets by scale.** What are the exact question sets for demo, small product and production? Answer before the o1 slice build (ac1-1).
7. **Version record.** Where does the setup record the source and date of each version: the spec, the AgDR or a separate file? Answer before the o2 slice build (ac2-4).
8. **Live-run proof.** Framework CI cannot create a remote or read a first CI run. Proposal: ac10-2 and ac10-6 use a recorded live run on a throwaway repository. Answer before the o9 slice build.

Resolved: the cost estimate source (owner decision 2), the hosts for revision 1 (owner decision 2) and the timing (owner decision 3).

## Upstream gaps

- The initiative record schema has no proof field (me2resh/apexyard#1618).
- me2resh/orbit-spec#21: one revision of each initiative record per record root. Superseded revisions go to `docs/orbit/history/`.
- AgDR-0226 adds an optional `dependsOn` list to outcomes. Until then, the order above lives in these notes.

## Checks

Each check that changes no status adds one line here: date, commit, result (AgDR-0225).

- 2026-10-13: the floor slice merged in #1716 and moves to docs/orbit/history/. Its partly met criteria (ac2-5, ac2-6, ac2-16) continue in `slice-scaffold-o2-starter`, the one open o2 slice (C6). The owner chose this slice on 2026-10-13. Naqid returned proceed-with-changes. The record has all three changes. The real proof runs in framework CI. An AgDR chooses the local database and ORM. Four exclusions are added.
- 2026-10-19, cee2d23: revision 5 cycle. `slice-scaffold-o2-starter` merged in #1722 and moves to docs/orbit/history/. No o2 slice is open now, so the next o2 slice can be cut (C7).
