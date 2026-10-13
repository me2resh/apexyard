---
name: scaffold
description: Interview the owner, sized to the project's scale, and generate the project floor from a validated scaffold spec
argument-hint: "<name> [PRD path]"
allowed-tools: Bash, Read, Write, AskUserQuestion
---

Writing: read docs/skills/shared/writing-rule.md before you write a durable artifact.

# /scaffold

Choose a host first. Ask a short interview and write a validated scaffold spec.
A spec records answers, sources, and open questions. This run generates the project floor.

A golden path is a tested starter. A pipeline runs checks for each change.
OIDC gives cloud access without stored keys. PRD means product requirements document.

## Mark the bootstrap session

Write the marker before the interview, as AgDR-0011 requires:

```bash
mkdir -p .claude/session
printf 'scaffold\n' > .claude/session/active-bootstrap
```

Use the exemption only for the bootstrap scope below.
Remove the marker and temporary inputs on every exit, including a No answer or a fault.
SessionStart also clears an interrupted marker.
Keep temporary inputs in one directory from `mktemp -d`.

## Read known values

1. Ask for a project directory name. Use letters, digits, underscores, and hyphens only.
2. Resolve the company setup through the portfolio helper:

   ```bash
   source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-read-config.sh"
   source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-portfolio-paths.sh"
   onboarding=$(portfolio_onboarding_path)
   ```

3. Read the resolved company setup when it exists. Read the owner's PRD when supplied.
4. Read `questions.json`, `rules.json`, and `spec.schema.json` beside this skill.
5. Read an existing target spec when resuming. List old fields under `unusedFields` as “no longer used”.
6. Extract only explicit PRD hints for `shape`, `scale`, and `dataSensitivity` into a temporary JSON object.
   The helper also maps explicit `PRD.data` to `dataSensitivity`.
7. Run `lib/next-questions.sh --mapped` with available input files.
   The optional inputs are `--spec`, `--onboarding`, `--prd-answers`, and `--run-answers`.
   Each answers file contains JSON. Each answer has `value` and `source`.

The closed key map reads hosting, cloud, and database from the company setup.
These keys can occur under `onboarding` or the existing `tech_stack` block.
Only AWS, GCP, Google Cloud, and Azure name a company cloud.
Only Netlify, Vercel, Render, Fly.io, Heroku, and Amplify name a hosting service.
Keep a named hosting service in `hostService` with source `onboarding` or `owner`.
Use that name in the setup sentence and manual steps. Default to Netlify when no service is named.
Unknown hosting values leave the host question open. Cloud names use the same exact cloud table.
Database fills storage only. Language and CI system appear only as summary notes or clashes.
No onboarding key fills data sensitivity, compliance, or sign-in.

Prefer this run, then the existing spec, then PRD, then company setup, then recommendations or defaults.
Show both values when sources clash. Let the owner choose one.
Keep the other value, its source, and the field in `openQuestions`.

## Confirm and ask

1. Show mapped values and their sources before the host question.
   Ask `reuseConfirm` only when mapped values exist.
   Offer Use these, Change one, and Ignore them and ask me.
2. Record `reuseConfirm` with source `owner`.
   Use these skips only mapped questions. No other choice permits a skip.
   Change one asks only the selected question before another confirm screen.
   Ignore them and ask me asks all applicable questions.
3. Run `lib/next-questions.sh` after each answer.
   Supply the current scale with `--scale` when known.
   Supply this run's answers through `--run-answers`.
4. Ask one returned question at a time through `AskUserQuestion`.
   Ask host, its cloud follow-up when needed, shape, then scale.
   Demo stops there. Small adds data sensitivity. Production also adds release check.
   The counts are 3, 4, and 5. A cloud follow-up adds one. A reuse confirm adds one.
5. Show at most three presets from the bank.
   Place the recommended preset first with `(Recommended)`.
   Put its plain reason in the description.
   Add `Not sure, recommend for me (picks <shown preset>)`.
   Not sure selects that preset with source `recommendation` and its reason.
   `AskUserQuestion` supplies Other. Other selects the minimal custom setup.
6. Use confirmed company cloud as the host recommendation when available.
   Its reason is “Your company already runs and secures this cloud.”
   Use confirmed PRD hints for shape, scale, and data sensitivity when available.
   Keep each recommendation in the displayed presets.
7. Record an explicit answer with source `owner`.
   Translate the displayed label to the canonical schema value.
   Host uses `hostKind`: `hosting service`, `company cloud`, or `server or container`.
   Shape uses `web app`, `API service`, or `data pipeline`.
   Scale uses `small`, `demo`, or `production` in preset order.
   Data uses `personal`, `none`, or `payment` in preset order.
   Release check uses `teammate`, `checks`, or `window` in preset order.

Never ask about cost, budget, currency, tests, coverage, language, database, sign-in, design, region, compliance, or uptime.

## Show the setup

1. Run `lib/next-questions.sh --derive` with the same inputs.
   The first matching rules row determines the setup.
2. Show the setup as a short message before the final screen, not inside the question.
   Start with the plain sentence on its own line, for example “This will run as a website on Netlify.”
   Then use short labelled lines, one fact per item: You chose, Defaults, Checks and pipeline, You do by hand, Not set up yet.
   Show technical names after the plain words.
3. Show each answer and its source.
   Display `owner` as “you”, `recommendation` as “recommended”, and `onboarding` as “company setup”.
   Display `prd` as “PRD”. Keep `default` and `derived` visible.
4. Show applied defaults and recommendation reasons.
   Coverage defaults to 80%. Web pages default to 500 KB.
   Demo uses no personal details, one environment, and live on merge when deploy exists.
   When a confirmed PRD names personal or payment details, keep the demo default and show the PRD conflict in `openQuestions`.
   Show the questions that Demo skipped. Explain that the owner can rerun `/scaffold` at a higher scale.
5. Show the pipeline, manual steps, and future infrastructure draft.
   Name cloud role creation, secret references, and repo environment reviewers when applicable.
   Reviewers require a repo setting. Files cannot configure that setting.
   Name language clashes and any CI system other than GitHub Actions.
   Show storage as an infrastructure input. Keep unresolved storage as an open question.
6. Show the hosting-service container limit from row 2.
   Let the owner choose whether to keep the host or change it.
7. Show “Deploy is not set up yet. This run sets up checks only.”
   Production release check also shows “Takes effect when deploy is set up.”
8. Ask one final summary screen. Keep its question short: the plain sentence and “Use this setup?”.
   Put no setup details in the question. Use these options:
   - Use this setup (Recommended).
   - Change one answer.
   - Start with a minimal custom setup.
9. Change one answer asks only the selected question.
   Recompute dependent values and show the summary again.
   Retain other answers. Clear a dependent answer only after the owner confirms the change.
10. A custom start selects rules row 7.
    Show “No golden path fits yet. You get the basic checks only.”
    When language clashes, show “No golden path for your language yet.”
    Explain that its placeholder test passes and reports that it is a placeholder.
    Keep “Choose a host before launch.” as an open question.
    Show the language clash in the custom option description when one exists.
11. Record the final choice under `setupChoice`.
    Write the confirmed spec to a temporary file outside the target.
    Include `specVersion: "0.1"`, scale, answers, open questions, unused fields, and `createdAt`.
    Keep an explicit custom stack under `customStack`, with its value and source.
    Keep an explicit coverage override under `coverage`, with its value and source.
12. Run `lib/validate-spec.sh <spec.json>`.
    Correct each reported fault before completing the interview.

## Rules

- Never push.
- Never write secrets.
- Never apply infrastructure or deploy.
- Use secret names only.
- Use `main` as the future deploy branch.
- Use no project names in framework text or records.

## Generate the floor

1. Validate the temporary spec with `lib/validate-spec.sh`.
2. Resolve the workspace directory with the portfolio helper:

   ```bash
   source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-read-config.sh"
   source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-portfolio-paths.sh"
   workspace_dir=$(portfolio_workspace_dir)
   target="$workspace_dir/$name"
   ```

3. Show the resolved target path and the file list from the bootstrap scope below.
   Include the bundle version and each placeholder.
   For typescript-nextjs, say that the starter source tree is copied.
   For every other bundle, say that no source tree is included.
4. Ask one `AskUserQuestion`: "Generate these files at this path?" Offer Yes and No.
   No ends the skill after cleanup. Yes permits generation.
5. Run `lib/generate.sh --spec "$spec" --name "$name"` beside this skill.
   The script builds the target from the workspace directory and the name.
   Pass `--target` only to override that path.
   The override must end in the name.
   The target must be absent or empty. Stop on any fault.
6. Remove `.claude/session/active-bootstrap` on completion or failure.
   SessionStart also clears an interrupted marker. See AgDR-0011.
   Remove all temporary inputs.

## Bootstrap scope

The exemption covers only these write targets:

- `.claude/session/active-bootstrap`: the session marker.
- Temporary `spec.json`, `prd-answers.json`, and `run-answers.json` files: the interview inputs and confirmed answers.
- `workspace/<name>/.github/workflows/ci.yml`: the floor pipeline.
- `workspace/<name>/scripts/ci/{lint,typecheck,test,build,audit,coverage-gate,audit-gate}.sh`: the gate scripts.
- `workspace/<name>/handbooks/general/`: the general handbook copies.
- `workspace/<name>/handbooks/architecture/`: the architecture handbook copies.
- `workspace/<name>/.apexyard/topology`: the bundle anchor.
- `workspace/<name>/docs/agdr/AgDR-0001-scaffold-choices.md`: the proposed decision record.
- `workspace/<name>/docs/scaffold/spec.json`: the confirmed spec copy.
- `workspace/<name>/docs/scaffold/notes.md`: the open questions and coverage format.
- `workspace/<name>/docs/scaffold/notes.md` for a custom stack: the security baseline notes.
- `workspace/<name>/scripts/exact-pins.sh` for a custom stack: the exact-pin check.
- `workspace/<name>/` for typescript-nextjs: the copied starter source tree.
- `workspace/<name>/docs/scaffold/golden-path-request.md`: the custom stack request draft.

Resolve `workspace/` with `portfolio_workspace_dir`. These paths do not authorize other project edits or registry writes.
Hakim must review this scope before merge. Keep all review and merge gates.

Never push. Never write secrets. Never apply infrastructure.
