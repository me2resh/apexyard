# Notes for the scaffold initiative (current: revision 4)

These notes sit beside the initiative record. The ORBIT v0.1 schema for that record type has no fields for constraints, decisions, dependencies or proof. The initiative record stays valid ORBIT. The record type and the file names keep the `plan-` prefix (AgDR-0226).

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

The cheaper alternative is this: `/onboard` step 4b calls `/handover` step 1.5 and step 5.5 on the empty repository. Starter directories and a coverage floor in `nextjs-ci.yml` complete it. Slice 1 must deliver more than that path does. The path adds a spec file, a rule table with reasons and seeded-fault proof. It also adds bootstrap scope without a ticket first.

## Constraints

- **C1. No secrets in generated files.** Generated CI names a secret only by reference, for example `secrets.AWS_CI_ROLE_ARN`. An env example file holds placeholders only. The generated tree passes `check-secrets.sh` (ac2-5).
- **C2. No remote action without the owner's yes.** The skill writes only local files. It runs `gh repo create`, `git push` or a tracker write only after an explicit yes for that step (ac7-2).
- **C3. The scaffold goes through review.** After the owner's yes, the remote starts with a README-only default branch. The skill proposes the scaffold on a branch as the first PR, with Rex and the other merge gates. The skill never pushes the scaffold to the default branch.
- **C4. IaC is never applied by the skill.** The skill runs no `terraform apply`, no `terramate run` that applies, and no cloud write call. It needs no cloud credentials (ac4-7). Generated Terraform CI keeps its apply job off until the owner turns it on (ac4-4).
- **C5. The skill writes in ASD-STE100.** It reads `.claude/rules/writing-standard.md` before it writes a durable file. Each generated Markdown file passes `bin/check-writing-profile.sh` (ac2-15).
- **C6. Framework governance wins.** No slice bypasses tickets, reviews, review markers or merges. The bootstrap exemption covers only the paths that ac2-14 names.
- **C7. One slice, one ticket, one PR.** Each outcome has one open slice at a time. A fault found inside a slice is a step in that slice.
- **C8. Reuse, do not fork.** Bundle copy logic lives in one script (ac2-5), and `/handover` calls it from o5 on (ac5-5). Between o2 and o5, `/handover` step 5.5 keeps its prose steps. Pipelines come from `golden-paths/pipelines/` and the bundles.
- **C9. Opt-in for adopters.** Each entry point needs the owner's yes before /scaffold starts. `/onboard` keeps its light registration (ac7-1). `/handover` keeps its default behaviour, and the ac5-5 regression test proves it. Retrofit mode needs a separate yes (o3).
- **C10. Every price is dated and is not a quote.** The price table carries a price date. Each generated estimate shows that date and says that the figures are not a quote (ac4-6).
- **C11. No project names.** Framework text and records use no project names. Use "a recent project" or "a reference project" when needed.
- **C12. Plain-language recommendations.** Each recommendation gives a plain reason that a non-engineer can understand (ac1-2).
- **C13. No overwrite without a per-file yes.** Handover gap-fill needs the owner's explicit yes for each existing file before it overwrites that file (ac3-4).

## Overlaps

### Harness golden-path initiative (revision 3)

- **o5 (DDD boundaries).** It owns the dependency-cruiser config in `golden-paths/typescript/` and the step in `code-quality.yml`. This initiative reuses that config for TypeScript projects (ac6-1) and does not rebuild it. This initiative adds the layer check for Python and Go only.
- **o6 (logging standard).** It owns the logging rule, `handbooks/general/logging.md` and the Logger port example. A generated TypeScript backend copies that port when o6 has shipped. This initiative sets no logging criterion of its own.
- **o2 and o3 (Cursor and Codex gates).** No overlap. `/scaffold` runs in any harness that runs the other skills.
- **o1 (fail-closed gates).** No overlap. The bootstrap exemption in ac2-14 uses the existing marker and the ticket-first gate as they are.

### Skills

- **`/handover`.** It adopts an existing repository. `/scaffold` starts a new one. Both pick a bundle and copy it, so they share the copy script from o5 on (C8). The harnessability assessment is the acceptance test (ac2-12, ac5-6).
- **`/onboard` step 4b.** It registers a new project with no bundle. ac7-1 adds `/scaffold` as the recommended option.
- **`/walking-skeleton`.** It files the first kept slice. `/scaffold` makes the repository that slice lands in, and it stops before any feature code. The hand-off is ac7-3.
- **`/setup`.** It records the company stack in `onboarding.yaml`. `/scaffold` reads it and does not ask again (ac1-4).
- **`/validate-idea`, `/write-spec` and `/tech-vision`.** They own the product case, the PRD and the target architecture. `/scaffold` reads a PRD when one exists (ac1-4). It asks product questions only to size the stack, not to write a PRD.
- **Token-efficiency initiative.** No overlap. The new skill body follows the lean-skill rules of its o6.

## Outcomes

| Outcome | Result | Criteria |
|---------|--------|----------|
| o1-interview-sized-to-scale | The interview matches project scale and recommends an answer for each question. | 5 |
| o2-floor-and-recommended-path | The skill recommends a stack. Every project gets the stack-agnostic floor, and a golden-path stack also gets its tested starter. | 16 |
| o3-handover-gap-fill | Handover gap-fill adds missing foundations through a PR, with gap sizes from project scale. | 6 |
| o4-infra-and-cost | The skill writes an infrastructure draft and a monthly cost estimate. It never applies infrastructure. | 7 |
| o5-more-stacks | The skill adds python-fastapi and go-data-pipeline starters and shares the copy script with /handover. | 6 |
| o6-fitness-functions | Generated CI checks layer boundaries and bundle size. A fitness-functions file lists the gates and their source answers. | 4 |
| o7-entry-points | Entry points reuse answers and offer /scaffold. The scaffold uses a PR and offers /walking-skeleton. | 8 |
| o8-lessons-loop | Review findings produce scaffold changes and anonymous changelog lines. | 2 |

## Proof for each criterion

The initiative record schema has no proof field, so the proof for each criterion is here (direction of me2resh/apexyard#1618).

| Criterion | Shown by |
|-----------|----------|
| ac1-1 | Fixture runs ask the host first. The question counts are 3, 4 and 5 for demo, small and production. |
| ac1-2 | A fixture transcript shows the recommended answer first for each question, with one plain sentence that gives its reason. |
| ac1-3 | A fixture transcript selects 'Not sure, recommend for me'. The spec records the recommended value, its reason and the recommended mark. |
| ac1-4 | A fixture with a filled tech_stack block, where the transcript skips those questions. |
| ac1-5 | The schema file, and a test that validates a good and a bad spec. The valid spec includes the default and derived sources. |
| ac2-1 | The rules table, a --derive test for each of the seven rows, and the summary text that shows the defaults. A none-yet host writes an open question. |
| ac2-2 | The rule table, and a test that a spec no golden path fits takes the custom start of ac2-16. |
| ac2-3 | The skill text, and a spec written after an override. |
| ac2-4 | The starter directory, its lock file and the VERSION diff. An audit fixture checks generator versions before pinning. A manifest check confirms exact versions for production dependencies and development tools. |
| ac2-5 | The copy script, and `check-secrets.sh` output on the generated tree. |
| ac2-6 | The generated CI file, and the ac2-11 fixture. |
| ac2-7 | A fixture with a seeded vulnerable production pin fails the audit for high and critical advisories. A clean fixture passes. |
| ac2-8 | Build-environment fixtures block install scripts and network access. Each AgDR records the failed check and the selected fallback. |
| ac2-9 | Generated starter tests check HttpOnly, SameSite and the Secure rule for session cookies. Route tests enforce JSON-only state changes and problem+json errors with stable codes. |
| ac2-10 | The README gives one command to migrate, seed and start. A fixture runs that command and tests one-command reset to seed data. |
| ac2-11 | The fixture test in framework CI, and the CI time before and after in the PR. |
| ac2-12 | A recorded `/handover` step 4.5 run on the generated fixture project, in the PR. |
| ac2-13 | The generated AgDR file in the fixture run. |
| ac2-14 | `bootstrap_skills` in the defaults file, the bootstrap scope section, a hook test and the Hakim review on the PR. |
| ac2-15 | `bin/check-writing-profile.sh` output, and the docs diff with the skill counts. |
| ac2-16 | A fixture spec for a stack with no golden path. The generated tree has the floor gates, and the transcript shows the custom mark and the drafted golden-path request. |
| ac3-1 | Accept and decline /handover retrofit transcripts, with a file comparison that shows no writes after a no. |
| ac3-2 | A fixture gap report naming the closest topology and each missing pipeline, gate and fitness function. |
| ac3-3 | The proposed branch diff and PR from an accepted retrofit fixture. |
| ac3-4 | A fixture with existing files, explicit file approvals and a diff proving unapproved files were not overwritten. |
| ac3-5 | The fixture report with before and after scores for all five harnessability dimensions. |
| ac3-6 | A gap report assigns must, should or later from scale. A fixture transcript asks only about gaps and recommends each answer. |
| ac4-1 | The question bank and a test that no question asks about cost, budget or currency. |
| ac4-2 | The draft recommendation for an AWS spec, for a host with no IaC template, and the open question for a none-yet host. |
| ac4-3 | `terraform validate`, `tflint` and ASCII check output in framework CI, and a seeded non-ASCII fault. |
| ac4-4 | The generated CI file, and a test that no apply job runs by default. |
| ac4-5 | The generated cost range for a small and a production spec, with drivers and assumptions and no budget comparison. |
| ac4-6 | The price table, the not-a-quote line in each cost range, and the price-date CI check. |
| ac4-7 | A grep test over the skill text and scripts for apply and cloud write calls. |
| ac5-1 | The rule table, and a summary that shows a language clash with onboarding. |
| ac5-2 | A fixture spec with a web plus pipeline shape, and a fixture spec that fits no bundle. |
| ac5-3 | The starter directories, their lock files and each VERSION diff. |
| ac5-4 | The generated CI files, the fixture test, and the CI time in the PR. |
| ac5-5 | `/handover` calling the script, and the regression test. |
| ac5-6 | The scoring script, and its output on each generated fixture project. |
| ac6-1 | The generated CI files and layer-check configs for each topology. |
| ac6-2 | A web spec with the 500 KB default, a spec with a changed budget, and the CI step that fails above it. |
| ac6-3 | The generated fitness-functions file in each fixture run. |
| ac6-4 | The fixture test in framework CI. |
| ac7-1 | A new-fork transcript that selects start a new project and shows the recommended /scaffold offer. |
| ac7-2 | The registry validation output, and a test that the skill text gates each remote call on a yes. |
| ac7-3 | The skill text, and the `/walking-skeleton` defaults in a fixture run. |
| ac7-4 | An approved new-product PRD and a transcript that offers /scaffold and asks only for missing answers. |
| ac7-5 | Accept and decline transcripts after /write-spec, with a file comparison that shows no writes after a no. |
| ac7-6 | An /onboard transcript that skips recorded answers, plus accept and decline runs with no files after a no. |
| ac7-7 | An ORBIT slice handoff needing a repository, its derived spec and a transcript that skips recorded answers. |
| ac7-8 | Accept and decline ORBIT handoff transcripts, with a file comparison that shows no writes after a no. |
| ac8-1 | A fixture review finding traces to the starter or interview. Its scaffold diff adds a starter fix, question or check. |
| ac8-2 | A lessons-loop change adds a changelog line that names the finding class. A check confirms that the line contains no project name. |

## Order

o1 and o2 come first. Within the first slices, o1 precedes o2. Then o3 adds handover gap-fill. o4 follows o3. Then o5 adds more stacks, and o6 adds fitness functions. The TypeScript part of o6 waits for harness o5. o7 follows those outcomes because the handoff reads their spec fields. o8 runs after the first generated project gets a review. Build starts when the records merge. On 2026-10-13 the owner replaced owner decision 3. The first slice is `slice-scaffold-o1-interview`.

## Dependencies

- Harness golden-path initiative o5 (`slice-harness-o5-ddd-boundaries`) for ac6-1 on TypeScript.
- Harness golden-path initiative o6 for the Logger port in a generated TypeScript backend.
- AgDR-0048 (topology bundles). Starter directories and a second entry point change its scope, so the o2 slice records an evolution entry or a new AgDR.
- AgDR-0042 (harnessability dimensions), AgDR-0011 (bootstrap exemption), AgDR-0077 (walking skeleton).
- AgDR-0226 (Initiative terminology, proposed). This record migrates with the others when that AgDR is built.
- #1673 for the records branch rule in owner decision 4.

## Open questions for the owner

1. **Starter source: resolved.** Use a starter directory with audited exact pins (ac2-4, ac2-7). A generator pinned a vulnerable version, so the starter must use audited versions.
2. **Boundary tools for Python and Go.** Proposal: import-linter for Python and depguard inside golangci-lint for Go. Each needs a framework decision before o6.
3. **Ticket for the first PR.** The new repository has no tracker issue before the scaffold PR. Proposal: after the owner's yes, the skill files one Task in the new repository through `tracker_create`. The PR names that Task. Answer before o7.
4. **Registry status.** `/onboard` writes `active` and `/handover` writes `handover`. Which status does a scaffolded project get? Answer before o7.
5. **Composition.** AgDR-0048 leaves a web plus pipeline shape out of scope. Proposal: `/scaffold` lists it as a gap only (ac5-2) and does not generate two modules.
6. **Question sets by scale.** What are the exact question sets for demo, small product and production? Answer before the o1 slice build (ac1-1).

Resolved: the cost estimate source (owner decision 2), the hosts for revision 1 (owner decision 2) and the timing (owner decision 3).

## Upstream gaps

- The initiative record schema has no proof field (me2resh/apexyard#1618).
- me2resh/orbit-spec#21: one revision of each initiative record per record root. Superseded revisions go to `docs/orbit/history/`.
- AgDR-0226 adds an optional `dependsOn` list to outcomes. Until then, the order above lives in these notes.

## Checks

Each check that changes no status adds one line here: date, commit, result (AgDR-0225).

- 2026-10-13: the floor slice merged in #1716 and moves to docs/orbit/history/. Its partly met criteria (ac2-5, ac2-6, ac2-16) continue in `slice-scaffold-o2-starter`, the one open o2 slice (C6). The owner chose this slice on 2026-10-13. Naqid returned proceed-with-changes. The record has all three changes. The real proof runs in framework CI. An AgDR chooses the local database and ORM. Four exclusions are added.
