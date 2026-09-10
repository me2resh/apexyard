# Build-time handbook discovery

Build-class agents must consult adopter-authored standards before changing code. This is the proactive counterpart to Rex's review-time handbook pass: the same handbook is authoritative during Build and Review, so avoidable violations are caught before a review round trip.

## Required discovery floor

Before implementation, determine the ticket's expected file scope, then load relevant handbooks from both layers:

1. Public: `<ops-root>/handbooks/`
2. Private: the directory returned by `portfolio_custom_handbooks_dir` from `<ops-root>/.claude/hooks/_lib-portfolio-paths.sh`, when configured and present

Apply the same path convention independently to each layer:

- `architecture/*.md` and `general/*.md`: always load.
- `language/<lang>/*.md`: load when the expected or actual implementation scope contains that language (`typescript` for `.ts`/`.tsx`, `python` for `.py`, `go` for `.go`, `rust` for `.rs`, and the equivalent direct extension mapping for other language buckets).
- `domain/<area>/*.md`: parse the optional YAML-frontmatter `paths:` list and load when any expected or actual implementation path matches a listed glob. A domain handbook with no `paths:` field, or an empty list, always loads.

Resolve the ops root and private layer with the portfolio helpers; do not assume the current repository is the ops fork:

```bash
source "<ops-root>/.claude/hooks/_lib-portfolio-paths.sh"
private_handbooks=$(portfolio_custom_handbooks_dir 2>/dev/null || true)
```

Read every selected handbook in full before editing. Re-run language/domain selection if the implementation expands into files outside the expected scope.

## Optional semantic supplement

When `mcp__apexyard-search__search_docs` is available, make one additive semantic query using the ticket goal and expected implementation paths. Keep only results under `handbooks/` or `custom-handbooks/`, take at most the top five chunks, group by file, and read each unique handbook in full. De-duplicate files already loaded by path convention.

Semantic discovery is fail-soft: if the tool is unavailable, errors, or returns no handbook chunks, continue silently with the deterministic path-convention set. It must never replace or shrink the required discovery floor.

## Build-time semantics

Handbook rules are implementation guidance during Build. Follow both advisory and blocking rules while writing code, but do not issue a review verdict or write approval markers. If a handbook conflicts with the ticket, another handbook, or a framework rule, stop and surface the exact paths and conflicting statements to the orchestrator; do not silently choose one. Cite the handbook paths applied in the build handoff so Rex can verify the same standards independently.
