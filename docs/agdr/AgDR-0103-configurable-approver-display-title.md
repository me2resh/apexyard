# Configurable human merge-approver display title

> In the context of the merge gate hardcoding "CEO" as the human per-PR
> approver's name in every printed message, facing team adopters whose actual
> approver is a maintainer or dev lead rather than a CEO, I decided to add a
> single DISPLAY-ONLY config key (`review_markers.human_approver_title`,
> default `"CEO"`) that the hooks and `/approve-merge` substitute into prose
> while leaving the marker filename, structured fields, and gate logic
> untouched, to achieve consistent adopter vocabulary without a fork-wide
> rename, accepting that this is a narrow, deliberately-scoped precedent for
> display-only config and not a template for making every hardcoded string in
> the framework configurable.

## Context

- `me2resh/apexyard#957` — the framework names the human merge-approval gate
  "CEO" everywhere user-facing (`CLAUDE.md`, `.claude/rules/pr-workflow.md`,
  `/approve-merge`, `block-unreviewed-merge.sh`, `warn-review-marker-write.sh`,
  the `<pr>-ceo.approved` marker filename). Accurate for solo-founder
  adopters; wrong vocabulary for team adopters, who route this approval to a
  maintainer or lead engineer instead.
- The word "CEO" appears in roughly 290 places across ~30 framework-owned
  files. A fork-wide rename would create permanent merge conflicts on every
  future `/update` and would touch the load-bearing marker filename and
  structured-field parsing that the merge gate depends on — high blast
  radius for a purely cosmetic complaint.
- The gate's actual mechanism (`block-unreviewed-merge.sh` in
  `.claude/hooks/`) reads a marker file and validates structured key/value
  fields (`sha=`, `approved_by=user`, `skill_version=`) — none of that
  content is display text; it's a machine contract other hooks and tests
  depend on byte-for-byte.
- `.claude/project-config.defaults.json` already ships a shallow-merge
  config layer (`config_get` / `config_get_or` in `_lib-read-config.sh`)
  used for adopter-facing behavioural knobs like `review_markers.on_stale`,
  `ui_paths_exclude`, and `.pr.title_pattern` — precedent for a config key,
  but every existing key in that file changes *behaviour* (what gets
  scanned, what gets deleted, what regex validates a title). This is the
  first key that changes *nothing but printed text*.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Fork-wide find/replace of "CEO" → adopter's word | Fully consistent vocabulary everywhere | ~290-site edit; permanent `/update` merge conflicts forever; touches the marker filename and structured fields the gate parses — mixes a display concern with the mechanical contract |
| Rename the marker filename too (`<pr>-<title-slug>.approved`) | "More honest" filename | Breaks every existing session marker, test fixture, and gate regex that greps for `-ceo.approved`; the filename is a machine contract, not prose — renaming it for a display reason conflates the two concerns #957 explicitly asked to keep separate |
| New DISPLAY-ONLY config key, substituted only into printed prose | Zero-behaviour-change default; ~5 files touched; marker filename/fields/gate logic untouched; adopters get consistent vocabulary in one config line | Coverage is necessarily partial — only the hook messages and skill prose enumerated in scope are updated, not every one of the ~290 sites (out of scope: CHANGELOG, historical AgDRs, PRDs, and the generic "CEO = the human operator" usage in `loop-mode.md` / `parallel-work.md` / `plan-mode.md` / `ticket-vocabulary.md`) |
| Do nothing; document "read CEO as X" in adopter's own fork | Zero engineering cost | The exact status quo the ticket complains about — framework's own output keeps contradicting the adopter's fork-level note |

## Decision

Chosen: **new DISPLAY-ONLY config key**, because it fixes the adopter-facing
symptom (inconsistent vocabulary between what the adopter calls the role and
what the framework prints) at the lowest possible blast radius, and keeps the
mechanical contract (marker filename, structured fields, gate SHA-matching)
completely untouched — the two concerns #957 explicitly separates.

`review_markers.human_approver_title` (default `"CEO"`) is read via the
existing `config_get_or` helper in `block-unreviewed-merge.sh`,
`warn-review-marker-write.sh`, and documented as a SOFT (prose-level, not
mechanically enforced) convention for `/approve-merge` to follow when
addressing the user. `CLAUDE.md` and `.claude/rules/pr-workflow.md` each gain
one clarifying sentence pointing at the key — the ~290-site "CEO" occurrences
across CHANGELOG.md, historical AgDRs, PRDs, and the generic-operator usage in
`loop-mode.md` / `parallel-work.md` / `plan-mode.md` / `ticket-vocabulary.md`
are explicitly untouched, per the PM-scoped boundary for this ticket.

## Consequences

- Adopters who route merge approval to a maintainer/lead can set one config
  line and get consistent vocabulary in every BLOCKED/OK hook message and in
  `/approve-merge`'s prose, without a fork-wide edit or merge-conflict risk
  on `/update`.
- The marker filename stays `<owner>__<repo>__<pr>-ceo.approved` and the
  structured fields (`sha=`, `approved_by=user`, `skill_version=`) are
  byte-identical regardless of the configured title — every existing test
  that asserts the literal default string "CEO" continues to pass unmodified
  (verified: `test_block_unreviewed_merge.sh`, 34/34 passing after this
  change, including a new case that proves a custom title flows through to
  the BLOCKED message).
- This is a **narrow precedent, not a general pattern**. It does not imply
  every other hardcoded string in the framework (e.g. "Rex", "Tariq", "Hakim"
  persona names, or skill names) should grow a similar display-only config
  key. Future requests of this shape should be evaluated on their own
  cost/benefit, not treated as pre-approved by this AgDR.
- `/approve-merge`'s use of the configured title in its confirmation
  questions is **self-discipline only** — no hook can verify that the
  agent actually used the configured word instead of "CEO" in a
  conversational question, the same enforcement-gap shape documented for
  other prose-only rules (`reporting-style.md`, `plan-mode.md`).

## Artifacts

- `.claude/project-config.defaults.json` — new `review_markers.human_approver_title` key (default `"CEO"`)
- `.claude/hooks/block-unreviewed-merge.sh` — reads the title, substitutes into BLOCKED/OK prose, notes the marker filename is unaffected
- `.claude/hooks/warn-review-marker-write.sh` — same substitution in the advisory CEO-marker banner
- `.claude/skills/approve-merge/SKILL.md` — new step 0 documenting the SOFT prose-level convention
- `.claude/rules/pr-workflow.md`, `CLAUDE.md` — one clarifying sentence each
- `.claude/hooks/tests/test_block_unreviewed_merge.sh` — new case proving a custom title flows through; existing literal-"CEO" assertions verified unmodified and passing
- me2resh/apexyard#957 (ticket), this PR
