# Check document text

The lint checks sentence length, passive voice, banned words, and em dashes.
Numbered steps have a limit of 20 words per sentence.
Other text has a limit of 25 words per sentence.
The lint ignores code blocks and inline code.

`docs/docs-lint-rules.json` holds the shared rules.
The site lint reads this rules file first when its release cache contains it.
`docs/docs-lint-scope.json` selects files with glob patterns.
The default scan uses files that Git tracks.
For skills, the scan checks only frontmatter titles and descriptions.

Run a report from the repo root:

```sh
node bin/docs-lint.mjs --summary
node bin/docs-lint.mjs docs/docs-lint.md
```

Run a full strict check from the repo root:

```sh
node bin/docs-lint.mjs --strict
```

Optionally, check only lines that a branch changes:

```sh
node bin/docs-lint.mjs --base origin/dev --strict
```

Each finding shows `file:line: rule: detail`.
Use the file and line to find the text.
Use the rule and detail to select a change.
Report mode returns exit code 0 for findings.
Strict mode returns exit code 1 for any finding in the selected lines.
Input errors return exit code 2.

The continuous integration (CI) job runs `node bin/docs-lint.mjs --strict` on every pull request.
It checks every published document in scope and fails on any finding.
The job can serve as a required check.

The optional `--base` check selects changed lines.
A finding can span several lines.
The check counts a finding if a changed line occurs in that span.

The passive check uses a heuristic, or approximate test.
It checks a form of "be", an optional adverb, and a past participle.
It can flag adjectives and miss passive forms without "be".
Review each finding before you change text.

The rollout has three steps:

1. Report only.
2. Apply strict mode to added lines.
3. Apply strict mode to the full scope. This step is the current state.
