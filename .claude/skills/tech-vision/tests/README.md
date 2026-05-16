# /tech-vision smoke test

Standalone bash script that validates the three load-bearing contracts of the
`/tech-vision` skill without spinning up an interactive Claude Code session:

1. **Template structure** — every section heading SKILL.md's interview drives
   from must exist as a `##` heading in `templates/architecture/vision.md`. If
   either side drifts, the interview prompts for sections the template doesn't
   support, or skips sections the template does.
2. **Custom-template resolver** — `portfolio_resolve_template architecture/vision.md`
   returns a usable framework default in single-fork mode, and a fake
   `<private_repo>/custom-templates/architecture/vision.md` is correctly
   structured to be picked up by the resolver in split-portfolio mode.
3. **Output validity** — a populated vision built from the template's section
   list (mimicking what the skill would write after a successful interview)
   contains every required `##` heading, has at least one anti-scope item with
   a "reconsider when" rationale (load-bearing per the template note), has a
   non-trivial migration-path table, has a non-trivial current-vs-target
   table, has the skill footer signature, and embeds a Mermaid C4 block for
   the target state.

The skill itself runs inside Claude Code with the interactive interview flow —
operator answers prompts section by section, model assembles the file. This
script verifies the structural contract the interview produces; it cannot
exercise the interactive layer itself.

## Run

From the apexyard fork root:

```bash
bash .claude/skills/tech-vision/tests/smoke.sh
```

Exits `0` on success, `1` if any contract check fails.

## What this does NOT test

- **The interactive interview UX** — per-section confirm, anti-scope warning
  on skip, refresh-mode existing-content defaults. These run inside Claude
  Code and the model's response loop; they're verified by hand-walking the
  skill in a real session.
- **The skill's prompt phrasing** — the smoke test asserts structural
  contracts, not prose quality. Drift in prompt wording shows up in human
  review of SKILL.md.
- **Cross-skill chaining** — the v1 skill does NOT auto-call `/c4`; if a v1.x
  follow-up adds chaining, this test gains a "Mermaid block came from `/c4`"
  contract check.

## Adding a new template section

If the framework template adds a section (or an adopter's custom template
adds one), update:

1. `REQUIRED_HEADINGS` array in `smoke.sh` — add the new heading text
2. The case statement in the "populated vision" builder — add a synthetic
   body for the new section
3. SKILL.md's interview-section table — document the prompt shape for the
   new section

The skill itself drives off `^##` heading discovery at runtime; it does NOT
hardcode the section list. So adding a section to the template
automatically extends the interview without code changes to the skill — but
the smoke test does need updating since it asserts the framework default's
exact section list.
