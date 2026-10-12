# Notes for the scaffold initiative (current: revision 1)

These notes sit beside the initiative record. The ORBIT v0.1 schema for that record type has no fields for constraints, decisions, dependencies or proof. The initiative record stays valid ORBIT. The record type and the file names keep the `plan-` prefix (AgDR-0226).

## Where the initiative comes from

Owner intent, 2026-10-12: a new skill scaffolds a new project. It reads the golden-path directory, finds a template and pipelines, and customises the project after an interview. The interview covers best practices, fitness functions, quality gates, technology, IaC, cost and scale.

Evidence read on upstream/dev at 2854837, and checked again at 0eda785:

- `topologies/README.md` and the three bundles (`typescript-nextjs`, `python-fastapi`, `go-data-pipeline`). Each bundle holds handbooks, one CI file and one AgDR template. No bundle holds starter source code or tool configuration. ac1-6 and ac2-3 add a starter directory for this reason.
- Only `/handover` step 1.5 and step 5.5 pick and copy a bundle today. A new project has no path to a bundle except through `/handover` on an empty repository.
- `golden-paths/` holds only `pipelines/`. `golden-paths/typescript/` does not exist yet. The harness golden-path initiative o5 creates it.
- `golden-paths/pipelines/terraform-ci.yml` runs `terraform apply -auto-approve` on push to `main`. A copied file would apply on the first merge. ac4-4 keeps the apply job off.
- `golden-paths/pipelines/code-quality.yml` and `topologies/typescript-nextjs/golden-paths/nextjs-ci.yml` have no coverage floor. The FastAPI and Go CI files fail below 80 percent. The Next.js bundle-size check only warns.
- `/handover` step 4.5 scores harnessability on five dimensions (AgDR-0042). Its framework-opinionation table rates FastAPI and Go Gin or Echo as moderate. Only typescript-nextjs can score high on all five dimensions (ac1-10, ac2-6).
- `.claude/skills/handover/tests/test_harnessability_scoring.sh` greps SKILL.md and runs no scoring. ac2-6 adds an executable scoring script for this reason.
- `/onboard` step 4b registers a new project with no assessment and no bundle. ac5-1 makes `/scaffold` the recommended path there.
- `/walking-skeleton` asks for the layers and the deploy target. The spec already holds both, so ac5-3 passes them as defaults.
- `bootstrap_skills` in `.claude/project-config.defaults.json` lists setup, handover, update, split-portfolio, onboard and tutorial. ac1-12 adds scaffold.
- No Terraform module template and no price table exist in the repository. o4 has the agent write the infrastructure draft from the spec, not from a template library.
- The initiative record schema (orbit-spec `schema/plan.schema.json`) has no proof field. Each criterion holds only the condition, and its proof is in the table below (direction of me2resh/apexyard#1618).

## Owner decisions

Owner decisions, 2026-10-12:

1. **Slice 1 is a thin end-to-end slice for typescript-nextjs only.** It includes four interview questions: service shape, language, host and coverage floor. It selects a topology and generates a working project with CI and gates. Other stacks and the full interview come in later slices. o1 holds this slice.
2. **Infra and cost stay in this initiative as a later outcome (o4).** Also when no starter template exists for a stack, the agent recommends best-practice infrastructure and a cost estimate. The estimate matches the project's scale and budget. The agent writes both as a draft and never applies them. The estimate uses a static price table with a price date and a "not a quote" statement (ac4-6). Generated Terraform strings get an ASCII-only check (ac4-3).
3. **Build starts after the 6 Nov scope freeze.** The records can merge now. No build ticket opens before 6 Nov.
4. **Records PRs use an `orbit/<initiative>-<slug>` branch with no ticket (#1673).** Only the next slice gets a ticket, after its slice record merges.

5. **/scaffold has four entry points.** Each entry point offers /scaffold and starts nothing without the owner's yes. A no leaves no files.
   - After /write-spec produces an approved PRD for a new product, it offers /scaffold. The interview reuses PRD answers and asks only for gaps.
   - For a new fork, /onboard recommends /scaffold when the owner selects start a new project. The interview reuses recorded answers.
   - An ORBIT slice handoff offers /scaffold when it needs a new repository. The spec uses initiative outcomes and constraints without repeating recorded questions.
   - For an existing repository, /handover offers retrofit mode against the closest golden path. It proposes missing CI pipelines, quality gates and fitness functions.
   - Retrofit changes use a branch and PR. No existing file is overwritten without the owner's yes. The report records harnessability before and after.
   - Retrofit mode is the later outcome o6.

## Challenge disposition

Naqid (The Contrarian) returned "proceed-with-changes" with 16 changes on the first draft. This revision applies 15 and rejects 1.

| Naqid change | Disposition |
|--------------|-------------|
| 1. Harnessability high for typescript-nextjs only | Applied: ac1-10 and ac2-6. |
| 2. The scoring test runs no scoring | Applied: ac2-6 adds an executable scoring script. Slice 1 records a /handover step 4.5 run as its proof. |
| 3. ac3-2 shared code against C9 | Applied: the /handover refactor is accepted with a regression test (ac2-5). C9 now says so. |
| 4. Slice 1 as a thin vertical | Applied: owner decision 1, outcome o1. |
| 5. Cut the interview to four questions | Applied: ac1-1. Each later question moves to the outcome that uses its answer (ac2-1, ac3-2, ac4-1). |
| 6. A rule table, not a ranking script | Applied: ac1-4 and ac2-1. |
| 7. Remove latency and cost CI budgets | Applied: ac3-2 keeps the bundle-size budget only. |
| 8. Move IaC and cost to another initiative | Rejected: owner decision 2 keeps them here as o4. The agent writes the draft from the spec, so no Terraform library is needed first. |
| 9. ASCII-only check on .tf strings | Applied: ac4-3. |
| 10. Static price table, price date, not a quote | Applied: ac4-6, with the 6-month CI check. |
| 11. One AgDR for the scaffold | Applied: ac1-11. |
| 12. Bootstrap scope review | Applied: ac1-12 requires a Hakim review. Open question 5 stays open until o5, because o1 creates no remote. |
| 13. Limit the fixture toolchains, record CI time | Applied: ac1-9 and ac2-4. |
| 14. Starter maintenance | Applied: exact pinned versions (ac1-6, ac2-3). The ac1-9 fixture test proves that the starter still builds. |
| 15. Settle the timing before slice 1 | Applied: owner decision 3. |
| 16. Name the cheaper alternative | Applied: see "Baseline to beat". |

## Baseline to beat

The cheaper alternative is this: `/onboard` step 4b calls `/handover` step 1.5 and step 5.5 on the empty repository. Starter directories and a coverage floor in `nextjs-ci.yml` complete it. Slice 1 must deliver more than that path does. The difference is the spec file, the rule table with stated reasons, the seeded-fault proof and the bootstrap scope with no ticket first.

## Constraints

- **C1. No secrets in generated files.** Generated CI names a secret only by reference, for example `secrets.AWS_CI_ROLE_ARN`. An env example file holds placeholders only. The generated tree passes `check-secrets.sh` (ac1-7).
- **C2. No remote action without the owner's yes.** The skill writes only local files. It runs `gh repo create`, `git push` or a tracker write only after an explicit yes for that step (ac5-2).
- **C3. The scaffold goes through review.** After the owner's yes, the remote starts with a README-only default branch. The scaffold goes up on a branch as the first PR, with Rex and the other merge gates. The skill never pushes the scaffold to the default branch.
- **C4. IaC is never applied by the skill.** The skill runs no `terraform apply`, no `terramate run` that applies, and no cloud write call. It needs no cloud credentials (ac4-7). Generated Terraform CI keeps its apply job off until the owner turns it on (ac4-4).
- **C5. The skill writes in ASD-STE100.** It reads `.claude/rules/writing-standard.md` before it writes a durable file. Each generated Markdown file passes `bin/check-writing-profile.sh` (ac1-13).
- **C6. ApexYard governance wins.** No slice bypasses tickets, reviews, review markers or merges. The bootstrap exemption covers only the paths that ac1-12 names.
- **C7. One slice, one ticket, one PR.** Each outcome has one open slice at a time. A fault found inside a slice is a step in that slice.
- **C8. Reuse, do not fork.** Bundle copy logic lives in one script (ac1-7), and `/handover` calls it from o2 on (ac2-5). Between o1 and o2, `/handover` step 5.5 keeps its prose steps. Pipelines come from `golden-paths/pipelines/` and the bundles.
- **C9. Opt-in for adopters.** Each entry point needs the owner's yes before /scaffold starts. `/onboard` keeps its light registration (ac5-1). `/handover` keeps its default behaviour, and the ac2-5 regression test proves it. Retrofit mode needs a separate yes (o6).
- **C10. Every price is dated and is not a quote.** The price table carries a price date. Each generated estimate shows that date and says that the figures are not a quote (ac4-6).

## Overlaps

### Harness golden-path initiative (revision 3)

- **o5 (DDD boundaries).** It owns the dependency-cruiser config in `golden-paths/typescript/` and the step in `code-quality.yml`. This initiative reuses that config for TypeScript projects (ac3-1) and does not rebuild it. This initiative adds the layer check for Python and Go only.
- **o6 (logging standard).** It owns the logging rule, `handbooks/general/logging.md` and the Logger port example. A generated TypeScript backend copies that port when o6 has shipped. This initiative sets no logging criterion of its own.
- **o2 and o3 (Cursor and Codex gates).** No overlap. `/scaffold` runs in any harness that runs the other skills.
- **o1 (fail-closed gates).** No overlap. The bootstrap exemption in ac1-12 uses the existing marker and the ticket-first gate as they are.

### Skills

- **`/handover`.** It adopts an existing repository. `/scaffold` starts a new one. Both pick a bundle and copy it, so they share the copy script from o2 on (C8). The harnessability assessment is the acceptance test (ac1-10, ac2-6).
- **`/onboard` step 4b.** It registers a new project with no bundle. ac5-1 adds `/scaffold` as the recommended option.
- **`/walking-skeleton`.** It files the first kept slice. `/scaffold` makes the repository that slice lands in, and it stops before any feature code. The hand-off is ac5-3.
- **`/setup`.** It records the company stack in `onboarding.yaml`. `/scaffold` reads it and does not ask again (ac1-2).
- **`/validate-idea`, `/write-spec` and `/tech-vision`.** They own the product case, the PRD and the target architecture. `/scaffold` reads a PRD when one exists (ac1-2). It asks product questions only to size the stack, not to write a PRD.
- **Token-efficiency initiative.** No overlap. The new skill body follows the lean-skill rules of its o6.

## Outcomes

| Outcome | Result | Criteria |
|---------|--------|----------|
| o1-nextjs-thin-path | /scaffold asks four questions, picks the typescript-nextjs bundle and generates a working local project whose CI enforces the gates. | 13 |
| o2-more-stacks | /scaffold generates python-fastapi and go-data-pipeline projects, names each gap that no bundle covers, and shares its copy script with /handover. | 6 |
| o3-fitness-functions | Generated CI checks layer boundaries and the bundle-size budget, and one file lists each gate and the spec answer that set it. | 4 |
| o4-infra-and-cost | /scaffold writes a draft infrastructure recommendation and a monthly cost estimate matched to scale and budget, and never applies the infrastructure. | 7 |
| o5-entry-and-handoff | /write-spec, /onboard and ORBIT handoffs offer /scaffold with reused answers. The scaffold reaches a remote through a PR and offers /walking-skeleton. | 8 |
| o6-retrofit-mode | /handover offers /scaffold retrofit mode for existing repositories. It proposes missing CI pipelines, quality gates and fitness functions through a PR. | 5 |

## Proof for each criterion

The initiative record schema has no proof field, so the proof for each criterion is here (direction of me2resh/apexyard#1618).

| Criterion | Shown by |
|-----------|----------|
| ac1-1 | The skill text, and a fixture transcript with one question per turn and an unknown answer. |
| ac1-2 | A fixture with a filled tech_stack block, where the transcript skips those questions. |
| ac1-3 | The schema file, and a test that validates a good and a bad spec. |
| ac1-4 | The rule table, and a test that a non-Next.js spec stops with a named gap. |
| ac1-5 | The skill text, and a spec written after an override. |
| ac1-6 | The starter directory, its lock file and the VERSION diff. |
| ac1-7 | The copy script, and `check-secrets.sh` output on the generated tree. |
| ac1-8 | The generated CI file, and the ac1-9 fixture. |
| ac1-9 | The fixture test in framework CI, and the CI time before and after in the PR. |
| ac1-10 | A recorded `/handover` step 4.5 run on the generated fixture project, in the PR. |
| ac1-11 | The generated AgDR file in the fixture run. |
| ac1-12 | `bootstrap_skills` in the defaults file, the bootstrap scope section, a hook test and the Hakim review on the PR. |
| ac1-13 | `bin/check-writing-profile.sh` output, and the docs diff with the skill counts. |
| ac2-1 | The rule table, and a fixture transcript with language unknown. |
| ac2-2 | A fixture spec with a web plus pipeline shape, and a fixture spec that fits no bundle. |
| ac2-3 | The starter directories, their lock files and each VERSION diff. |
| ac2-4 | The generated CI files, the fixture test, and the CI time in the PR. |
| ac2-5 | `/handover` calling the script, and the regression test. |
| ac2-6 | The scoring script, and its output on each generated fixture project. |
| ac3-1 | The generated CI files and layer-check configs for each topology. |
| ac3-2 | A fixture spec with a bundle-size budget, and the CI step that fails above it. |
| ac3-3 | The generated fitness-functions file in each fixture run. |
| ac3-4 | The fixture test in framework CI. |
| ac4-1 | The skill text, and a fixture transcript with unknown answers. |
| ac4-2 | The draft recommendation for an AWS spec and for a host with no IaC template. |
| ac4-3 | `terraform validate`, `tflint` and ASCII check output in framework CI, and a seeded non-ASCII fault. |
| ac4-4 | The generated CI file, and a test that no apply job runs by default. |
| ac4-5 | The generated cost file for a spec under budget and a spec over budget. |
| ac4-6 | The price table, the "not a quote" line in each cost file, and the price-date CI check. |
| ac4-7 | A grep test over the skill text and scripts for apply and cloud write calls. |
| ac5-1 | A new-fork transcript that selects start a new project and shows the recommended /scaffold offer. |
| ac5-2 | The registry validation output, and a test that the skill text gates each remote call on a yes. |
| ac5-3 | The skill text, and the `/walking-skeleton` defaults in a fixture run. |
| ac5-4 | An approved new-product PRD and a transcript that offers /scaffold and asks only for missing answers. |
| ac5-5 | Accept and decline transcripts after /write-spec, with a file comparison that shows no writes after a no. |
| ac5-6 | An /onboard transcript that skips recorded answers, plus accept and decline runs with no files after a no. |
| ac5-7 | An ORBIT slice handoff needing a repository, its derived spec and a transcript that skips recorded answers. |
| ac5-8 | Accept and decline ORBIT handoff transcripts, with a file comparison that shows no writes after a no. |
| ac6-1 | Accept and decline /handover retrofit transcripts, with a file comparison that shows no writes after a no. |
| ac6-2 | A fixture gap report naming the closest topology and each missing pipeline, gate and fitness function. |
| ac6-3 | The proposed branch diff and PR from an accepted retrofit fixture. |
| ac6-4 | A fixture with existing files, explicit file approvals and a diff proving unapproved files were not overwritten. |
| ac6-5 | The fixture report with before and after scores for all five harnessability dimensions. |

## Order

o1 first. It gives one working path for typescript-nextjs. Then o2 for the other two bundles. o3 follows o2, and its TypeScript part waits for harness o5. o4 follows o1 and can run beside o2 and o3. o5 follows those outcomes because the handoff reads their spec fields. o6 comes last and adds retrofit mode for existing repositories. Build starts after the 6 Nov scope freeze (owner decision 3).

## Dependencies

- Harness golden-path initiative o5 (`slice-harness-o5-ddd-boundaries`) for ac3-1 on TypeScript.
- Harness golden-path initiative o6 for the Logger port in a generated TypeScript backend.
- AgDR-0048 (topology bundles). Starter directories and a second entry point change its scope, so the o1 slice records an evolution entry or a new AgDR.
- AgDR-0042 (harnessability dimensions), AgDR-0011 (bootstrap exemption), AgDR-0077 (walking skeleton).
- AgDR-0226 (Initiative terminology, proposed). This record migrates with the others when that AgDR is built.
- #1673 for the records branch rule in owner decision 4.

## Open questions for the owner

1. **Starter source.** Proposal: a starter directory in each bundle (ac1-6). The other choice is each stack's own generator, for example `create-next-app`. A generator needs the network and changes over time. Answer before the slice 1 build.
2. **Boundary tools for Python and Go.** Proposal: import-linter for Python and depguard inside golangci-lint for Go. Each needs a framework decision before o3.
3. **Ticket for the first PR.** The new repository has no tracker issue before the scaffold PR. Proposal: after the owner's yes, the skill files one Task in the new repository through `tracker_create`, and the PR names it. Answer before o5.
4. **Registry status.** `/onboard` writes `active` and `/handover` writes `handover`. Which status does a scaffolded project get? Answer before o5.
5. **Composition.** AgDR-0048 leaves a web plus pipeline shape out of scope. Proposal: `/scaffold` lists it as a gap only (ac2-2) and does not generate two modules.

Resolved: the cost estimate source (owner decision 2), the hosts for revision 1 (owner decision 2) and the timing (owner decision 3).

## Upstream gaps

- The initiative record schema has no proof field (me2resh/apexyard#1618).
- me2resh/orbit-spec#21: one revision of each initiative record per record root. Superseded revisions go to `docs/orbit/history/`.
- AgDR-0226 adds an optional `dependsOn` list to outcomes. Until then, the order above lives in these notes.

## Checks

Each check that changes no status adds one line here: date, commit, result (AgDR-0225).
