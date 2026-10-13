---
name: scaffold
description: Interview the owner, sized to the project's scale, and write a validated scaffold spec (project generation comes later)
argument-hint: "[target directory] [PRD path]"
allowed-tools: Bash, Read, Write, AskUserQuestion
---

Writing: read docs/skills/shared/writing-rule.md before you write a durable artifact.

# /scaffold

Interview the owner and write a scaffold spec. A scaffold spec records choices, answer sources, and open questions.

The owner approved `questions.json` on 2026-10-13. Demo, small, and production tiers contain 5, 10, and 15 questions respectively.
Each tier includes the preceding tiers. Only a web app receives q15.

## Steps

1. Use the target directory that the operator names. Default to the current project directory.
2. Resolve onboarding through the portfolio helper:

   ```bash
   source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-read-config.sh"
   source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-portfolio-paths.sh"
   onboarding=$(portfolio_onboarding_path)
   ```

3. Read the resolved onboarding file when it exists. Read a product requirements document (PRD) if the operator names one.
4. Read `questions.json` and `spec.schema.json` beside this skill. Preserve existing spec answers when resuming an interview.
5. Record known answers as `{value, source}` under their `specField`. Use `onboarding` or `prd` for their source.
   Map `tech_stack.language` to `language`, `hosting` to `deployTarget`, `cloud` to `cloud`, and `database` to `data`.
   Preserve conflicting values as open questions instead of selecting silently.
   Prefer existing spec answers, then onboarding, then PRD. Store extracted PRD answers in a temporary JSON object keyed by `specField`.
6. Ask q01 first through `AskUserQuestion`. Map its choices to `demo`, `small`, or `production` for the spec scale.
   Record the scale answer under `answers.scale` with its source.
7. Run `lib/next-questions.sh --scale <tier>` beside this skill. Supply `--spec`, `--onboarding`, and `--prd-answers` for available files.
   Supply `--shape` when known. Omit missing files from the command.
8. Ask each returned question through `AskUserQuestion`, one at a time. Wait for the answer before asking another question.
   Show the recommended answer first with the label `(Recommended)`. Put its reason in the option description.
   Always offer `Not sure, recommend for me`. Keep that option visible when the menu limits preset choices.
   Accept other choices through free text. For q02, accept `other` through free text.
9. Adjust q05's plain recommendation to the shape before asking it:
   - Web app: TypeScript/Next.js. These tools support pages and server features in one product.
   - API service: Python/FastAPI. These tools help your team build a service that other software can use.
   - Data pipeline: Go. Go supports tools that process data with predictable resource use.
   - CLI tool: the team's main language. Familiar tools help your team maintain a command-line tool.
   - Other: the team's main language. Familiar tools give your team a practical starting point.

   Move that value to the first option. Use the matching reason for the recommendation.
10. Record explicit choices with source `owner`. For `Not sure, recommend for me`, record the recommended value, source `recommendation`, and reason.
    Never record a silent guess. Keep unknown user counts and budgets as `unknown`.
    Require an amount and currency for a specific budget. Collect account and region as free text for a specific cloud choice.
    Never collect credentials. Explain that personal data means privacy rules apply.
11. Add an open question when design or deploy target is `none yet`, including reused answers.
    Run the selector again after recording shape. This includes q15 for a production web app.
12. Write `docs/scaffold/spec.json` within the target directory. Include `specVersion: "0.1"`, scale, answers, openQuestions, and a date-time `createdAt`.
13. Run `lib/validate-spec.sh <spec.json>`. Correct each reported fault before continuing.
14. Show the scale, answers, sources, recommendation reasons, and open questions. State that project generation comes in a later release.

## Rules

- Never push.
- Never write a secret.
- Ask one question at a time.
- Use plain language for non-engineers.
- Use no project names in framework text or records.
- Write only the scaffold spec in the target project.
