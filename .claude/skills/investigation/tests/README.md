# /investigation smoke test

Standalone bash script that verifies the **shape contracts** the
`/investigation` skill depends on. The skill itself runs inside Claude
Code (interactive interview, `gh issue create`, file writes); this script
exists so a human or CI job can confirm the load-bearing contracts haven't
drifted.

## What it checks

1. **Template required-section coverage** — `templates/investigation.md`
   contains every section the SKILL.md interview promises to fill in
   (`Trigger`, `Hypothesis being tested`, `Method`, `Findings`,
   `Conclusion`, `Follow-up actions`).
2. **AgDR-style opener** — the template starts with the
   `> In the context of …` form, matching the framework's AgDR
   convention so readers parse intent in one line.
3. **Sibling-skill naming** — the when-to-use comparison block names
   `/spike`, `/bug`, and `/decide` so operators landing on the template
   from a search hit see the boundaries spelled out.
4. **`portfolio_resolve_template` override semantics** — builds a synthetic
   ops-fork + sibling private-repo fixture, drops a marker custom-template
   at `<sibling>/custom-templates/investigation.md`, and asserts the
   resolver picks the override over the framework default. Closes the
   contract with the `_lib-portfolio-paths.sh` helper (#244).
5. **project-config / template alignment** —
   `.ticket.required_sections.Investigation` in
   `.claude/project-config.defaults.json` matches the sections actually in
   the template, AND `.ticket.prefix_whitelist` contains `Investigation`
   (so `validate-issue-structure.sh` doesn't reject the new prefix).
6. **SKILL.md frontmatter sanity** — `name`, `argument-hint`, and
   `allowed-tools` keys are present.

## Run

From the apexyard fork root:

```bash
bash .claude/skills/investigation/tests/smoke.sh
```

Builds the override-test fixture in `$TMPDIR/investigation-fixture-*`,
runs the checks, and removes the fixture on exit (success or failure).

Exit code: `0` on success, `1` if any contract check fails.

## What it does NOT check

- The interactive interview flow (lives inside Claude Code; not bash-testable).
- The `gh issue create` call (would need a live GitHub repo).
- The live-doc file-write step (would need a mocked `Write` tool).

Those run end-to-end every time an operator invokes `/investigation`; if
they break, the failure surfaces in the next real invocation.
