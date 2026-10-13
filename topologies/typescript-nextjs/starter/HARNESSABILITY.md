# Harnessability

This file records the handover harnessability score for the generated project.
The score is high.
The high verdict needs every dimension in its top bucket.

Type safety uses strong, partial, or none.
Module boundaries use strong, partial, or flat.
Framework opinionation uses strong, moderate, or weak.
The test coverage signal uses present or absent.
The lint baseline uses present or absent.

## Type safety

Score: strong.
Evidence: `tsconfig.json` sets `strict` to true.

## Module boundaries

Score: strong.
Evidence: `src/domain`, `src/application`, and `src/infrastructure` are present.

## Framework opinionation

Score: strong.
Evidence: `package.json` depends on `next`.

## Test coverage signal

Score: present.
Evidence: `vitest.config.mts` sets `coverage.thresholds.lines` to 80.

## Lint baseline

Score: present.
Evidence: `eslint.config.mjs` is the ESLint config.
