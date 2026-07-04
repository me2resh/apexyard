# Framework-filing skills are exempt from the project ticket schema

> In the context of `validate-issue-structure.sh` enforcing the project's
> `required_sections` schema on every `[Feature]`/`[Bug]` `gh issue create`,
> facing `/request-apexyard-feature` filing upstream with a deliberately
> different body template, I decided to exempt the configured framework-filing
> skills (detected via the `active-issue-skill` marker) from the schema check,
> to achieve conformance-by-construction for those skills, accepting that their
> bodies are no longer structurally validated locally.

## Context

`validate-issue-structure.sh` keys its required-section schema purely on the
bracketed title prefix (`[Feature]` → User Story + Acceptance Criteria; `[Bug]`
→ Given/When/Then + Repro). Two skills emit `[Feature]`/`[Bug]` titles with a
**different** body template — `/request-apexyard-feature` (Problem / Proposed /
Why) and `/report-apexyard-bug` (Affected / Given-When-Then / Repro). The
feature one collides: same prefix, different required body.

Result (me2resh/apexyard#712): the framework-feature skill's own canonical
output is **blocked** by the validator unless the operator hand-adds the
`<!-- validate-issue-structure: skip -->` marker — which contradicts the hook's
own promise that *"the matching interactive skill produces a body that satisfies
this check by construction."* True for `/feature`; false for
`/request-apexyard-feature`.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| (a) Skill emits skip marker by construction | Smallest; no hook change | A visible marker in every framework issue; skips **all** validation; per-skill duplication |
| (b) Validator exempts framework-filing skills via the `active-issue-skill` marker | Centralised; clean issue bodies; config-driven; narrow | Small hook regression surface; skips schema for those skills |
| (c) Distinct title prefix / framework-`[Feature]` schema variant | Most principled | Biggest change; a new prefix alters UX everywhere, or a schema variant still needs context to disambiguate (collapses into (b)) |

## Decision

Chosen: **(b)**. The validator reads the **same** `active-issue-skill` marker
that `require-skill-for-issue-create.sh` already relies on; if it names a skill
in `.ticket.schema_exempt_skills` (default: `request-apexyard-feature`,
`report-apexyard-bug`), the schema check is skipped. Config-driven with an inline
fallback, mirroring the hook's existing `PREFIX_WHITELIST` / `SKIP_MARKER`
pattern, and resolving the marker via the shared `resolve_ops_root` helper so the
two hooks agree on its location.

## Consequences

- Framework feature/bug requests file cleanly with no manual skip marker; the
  hook's "conformant by construction" promise now holds for them too.
- The exemption is **narrow**: a project `/feature` or `/bug` writes its own name
  to the marker and is still enforced. Spoofing requires deliberately writing a
  framework-skill name to the marker — the same trust class as adding the skip
  marker, and a visible, auditable act.
- Those skills' bodies are no longer structurally validated locally — acceptable
  because each produces its body by construction and files to an external repo.
- New config key `.ticket.schema_exempt_skills`; adopters can extend it for
  custom framework-filing skills.

## Artifacts

- Closes me2resh/apexyard#712
- `.claude/hooks/validate-issue-structure.sh` — exemption block + `EXEMPT_SKILLS` read
- `.claude/project-config.defaults.json` — `ticket.schema_exempt_skills`
- `.claude/hooks/tests/test_validate_issue_structure.sh` — 4 exemption cases (exempt × 2, still-blocks × 2)
