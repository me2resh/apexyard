---
id: AgDR-0180
timestamp: 2026-09-28T00:00:00Z
agent: platform-engineer
model: claude-sonnet-5
session: session_01KGvb2ba4gyT3TN8L2uMLTn
trigger: user-prompt
status: executed
category: security
---

<!-- Uses the controlled technical writing profile in .claude/rules/writing-standard.md. -->

# Add an optional `public: true` registry field as a scoped leak-control exemption

> In the context of the leak hooks (`check-private-refs-staged.sh`,
> `check-private-refs-runtime.sh`, `block-private-refs-in-public-repos.sh`)
> treating every registered project as private, facing a real false
> positive — a registered project whose repo is public, such as a
> marketing site, blocked every commit that touched a file naming it,
> `CHANGELOG.md` included — I decided to add an optional `public: true`
> registry field, read once by a new shared parser
> (`_lib-registry-parser.sh`) that all three hooks source, to achieve a
> per-entry exemption from the leak scrub, accepting that the parser
> becomes a new single point of failure the hooks must fail closed
> against, and that the field is a self-service escape hatch an agent
> with registry-write access could also reach for on a private project.

## Context

`apexyard.projects.yaml` models every registered project as a private
identifier. The three leak hooks scrub each entry's `name`, `repo`/`repos`,
and `workspace` out of anything staged, resolved from a tracker-wrapper
call, or written to a public framework repo. That is correct for the
common case — a registered project is normally the adopter's own private
work — but it has no way to represent the uncommon, legitimate case: a
registered project whose repo is ALREADY public, such as a marketing site
governed under the same portfolio as everything else. me2resh/apexyard#1455
reported the concrete failure: `CHANGELOG.md` already named a public
registered repo in an old incident note, so every commit touching
`CHANGELOG.md` — including release commits — was blocked by a hook meant to
catch a genuine disclosure, not a repo that was never secret.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| **Hardcode an exemption list per hook** (e.g. an env var or a second small YAML file of "known public repos") | No registry schema change | A second source of truth to keep in sync with the registry; drifts the moment a project's visibility changes and nobody updates both files |
| **Drop the entry from the registry entirely for leak purposes, keep it for `/projects` etc.** | No new field | Loses the disclosure-scrub property for repo/workspace tokens that legitimately need scrubbing elsewhere (e.g. an internal doc path under the same public repo); also silently changes what "registered" means for every other consumer |
| **Optional `public: true` field on the registry entry itself, read by one shared parser all three hooks use** (chosen) | Single source of truth (the registry the adopter already maintains); the exemption travels with the entry it describes; one parser means one place to get the entry-boundary and fail-closed contract right, instead of three independent risks | The parser becomes a new component the hooks depend on — its own failure mode (missing, or its parse failing) must be handled explicitly, not left to "no output means nothing registered" |

## Decision

Chosen: **optional `public: true` field, parsed once by a new shared
library**, because it keeps the registry as the single source of truth for
a project's visibility and turns "every leak hook must agree on this flag"
into a property of one parser, not three independently-written awk state
machines that could quietly drift from each other (as they already had,
before this change, for the `repos:` block-list handling in the runtime
hook specifically).

**Schema contract:**

```yaml
- name: marketing-site
  repo: your-org/marketing-site
  public: true
```

- A missing `public:` field, or any value other than exactly `true`
  (`"true"`, `True`, `yes`, `public:true` with no space, a value inside a
  block scalar or a nested map), means **private** — the hooks fail closed
  by default. This is deliberate: an ambiguous parse must never read as an
  exemption.
- The flag is scoped to its **own registry entry only**. It is read at the
  entry's own top-level key column — the column established by that
  entry's opening `- <key>:` list item, whichever key opens it (`name:`,
  `repo:`, `workspace:`, ...; not only `name:` first). A `public: true`
  nested inside a sub-map (e.g. under a `deploy:` key), inside a block
  scalar's prose body, or belonging to a NEIGHBOURING entry or a top-level
  key such as `defaults:`, is never read as this entry's flag.
- Every leak hook fails closed — blocks with a clear message — if the
  shared parser (`_lib-registry-parser.sh`) is not defined after the
  `source` step, or if `registry_parse_entries` itself returns non-zero.
  Before this change, a missing inline-awk copy could not exist as a
  failure mode at all (the parse was inline in each hook); factoring it out
  into a shared file makes "the file is missing" a real, distinct way to
  fail, and it must fail the same direction the hooks already fail on every
  other ambiguity — closed.

**What changed, per consumer:**

| Consumer | Change |
|----------|--------|
| `apexyard.projects.yaml.example` | Documents `public:`, Example 3 (marketing site) now shows it set |
| `.claude/rules/leak-protection.md` | New "Public registry entries — `public: true`" section |
| `.claude/hooks/_lib-registry-parser.sh` (new) | One awk parser, entry-boundary-scoped by the opening list item's indent column; emits a `PUBLIC=0\|1` line ahead of each entry's `NAME=`/`REPO=`/`WORKSPACE=` lines |
| `check-private-refs-staged.sh` | Sources the shared parser; tracks a per-token public flag in parallel arrays (`names_public[]`/`repos_public[]`/`workspaces_public[]`); skips a token whose entry is public; blocks if the parser is undefined or its parse fails |
| `check-private-refs-runtime.sh` | Same field, tracked via a running `current_public` flag against the streamed `PUBLIC=`/`NAME=`/`REPO=`/`WORKSPACE=` lines; same fail-closed gate |
| `block-private-refs-in-public-repos.sh` | Same field; converted its token sets from space-joined strings to indexed arrays (`NAMES_PUBLIC[i]` paired by position with `NAMES[i]`, etc.) so this hook's skip logic matches the staged/runtime hooks' per-entry pairing exactly, rather than a looser membership check; same fail-closed gate |

## Consequences

- A registered project marked `public: true` is no longer blocked by any
  of the three leak hooks — the acceptance criterion `#1455` exists to
  satisfy. An entry with no field, or a malformed one, stays blocked
  exactly as before: the default is private, unconditionally.
- The parser is now a dependency each hook actively checks for, not an
  assumption. `declare -F registry_parse_entries` gates every hook run
  after the registry is confirmed to exist; a missing or failing parser
  blocks with a diagnostic instead of silently scanning nothing. Tested
  directly: `.claude/hooks/tests/test_leak_hooks_parser_missing.sh` removes
  the library from a sandbox copy of each hook and asserts exit 2.
  Empirically, the previous "checked at first review round" version fell
  through to exit 0 on `registry_parse_entries: command not found` in this
  exact scenario, before the fail-closed check was added.
- The flag's scope is provably per-entry, not "wherever the string
  `public: true` appears in the file". Nine distinct mis-scoping shapes are
  covered directly in `.claude/hooks/tests/test_check_private_refs_staged.sh`
  and `.claude/hooks/tests/test_block_private_refs_public_entry.sh`: a
  neighbouring entry opened by `repo:` or `workspace:` instead of `name:`
  (two directions), a nested map, a top-level `defaults:` block after the
  last entry, a block scalar containing the literal text as prose, a nested
  `- name:` list item, a missing space after the colon, and CRLF line
  endings (both a private entry that must still block and a public one that
  must still pass).
- `block-private-refs-in-public-repos.sh`'s scrub-token tracking changed
  from three space-joined strings plus a membership-only public check to
  six indexed arrays. This is a wider diff than strictly required to close
  the false positive, accepted because it removes a real (if unlikely)
  disagreement case: a token shared by a public entry and a private entry
  used to read as public in this hook (membership-only) while still
  blocking in the other two (index-paired) — the three hooks now agree by
  construction.
- The staged hook's `name_repo_pairs` (the #1431 upstream-name exemption's
  name-to-repo pairing) now pairs a name with EVERY repo of its entry,
  including each item of a plural `repos:` list — a side effect of reading
  the registry entry-by-entry instead of resetting the pairing at any
  `repos:` header. This is a deliberate, tested behaviour change from the
  pre-existing #1431 pairing (which paired only the first singular `repo:`):
  the upstream bare-name exemption now also fires correctly when the
  upstream repo is listed as one of several repos in a `repos:` block, a
  real association the old pairing missed.
- A side effect, not the goal: the runtime hook's inline `repos:` block-list
  parsing had a `current_list` reset that fired on every line, so it never
  actually scrubbed a block-list `repos:` item — only the flow-list form
  worked. The shared parser fixes this uniformly for all three hooks.
- An agent with write access to the registry can set `public: true` on a
  project that is not actually public, and unscrub it. This is not a new
  class of self-bypass — the same agent could already delete the entry, or
  its `name` field, for the same effect, and `.claude/rules/leak-protection.md`
  already documents removal as a mitigation path. The flag is quieter and
  looks more legitimate than an outright deletion, which is a real but
  accepted cost of the feature; it is not mitigated further here.
- **Rounds 4-7 correction (me2resh/apexyard#1457).** Rounds 4-6 tried
  fixing the false positive by rewriting the private-token scan as a new,
  hand-written "greedy" pass meant to be a strict superset of the hooks'
  original extraction, then patching that rewrite as each round's review
  found a fresh valid YAML shape where it silently dropped a private
  token: a `projects:` anchor guess in round 4, an exemption compared
  by occurrence count instead of line number in round 5, and a one-key
  `- repo:`/`- workspace:` list item closing an open `repos:` list
  early in round 6. Round 7 (Hakim HIGH-8: an entry whose first key is `- repos:`
  swallowed every entry after it) stopped patching the rewrite and
  removed it instead: the **private set is now exactly what each hook's
  original, dev (commit `9ac9d9e`) extraction produces**, run unchanged
  and wrapped only to carry each token's line number, so it can never
  again produce a token count smaller than dev's own code did on the
  same registry. The **public set must still be proven**, unchanged
  since round 6 — a value is exempt only when every line dev's
  extraction finds it on is also a line the structural pass attributes
  to a confirmed `public: true` entry under the file's real top-level
  `projects` key. An ambiguous file (a duplicate top-level `projects:`
  key, two YAML documents, or a tab in the indentation) empties the
  public set for the whole file instead, with one line to stderr naming
  the cause. `.claude/hooks/tests/test_registry_parser_differential.sh`
  (new) makes this mechanical: it re-derives dev's original two
  extraction programs and asserts, for every registry fixture in the
  suite, that no value they find is ever absent from the new parser's
  output — only ever reclassified from private to proven-public.
- **Round 8 correction (me2resh/apexyard#1457, Hakim).** `_registry_correlate`
  now also checks each individual word of a multi-word dev value (restoring
  a per-word check dev's own hook body had, which round 2's move to indexed
  arrays lost — HIGH-9), splits a "value\tline" pair at the last tab and
  distrusts a proven-public value that still contains one after that split
  (closing a forged-line-number path — MEDIUM), and runs dev's private
  extraction against a carriage-return-stripped copy of the registry so a
  CRLF entry's tokens match plain text (LOW-1).
- **Round 9 correction (me2resh/apexyard#1457, Rex).** Round 8's word-split
  strips a trailing YAML comment and drops any resulting word that is only
  a YAML key shape before splitting, so a commented `repos:` list item no
  longer turns `#` and the comment's own words into private tokens (B8);
  `registry_parse_entries` also now checks the CR-strip's own exit status
  instead of assuming success.

## Artifacts

- me2resh/apexyard#1455 (originating issue)
- me2resh/apexyard#1457 (PR)
- `.claude/hooks/_lib-registry-parser.sh` (new)
- `.claude/hooks/check-private-refs-staged.sh`
- `.claude/hooks/check-private-refs-runtime.sh`
- `.claude/hooks/block-private-refs-in-public-repos.sh`
- `apexyard.projects.yaml.example`
- `.claude/rules/leak-protection.md`
- `.claude/hooks/tests/test_check_private_refs_staged.sh`
- `.claude/hooks/tests/test_block_private_refs_public_entry.sh` (new)
- `.claude/hooks/tests/test_leak_hooks_parser_missing.sh` (new)
- `.claude/hooks/tests/test_registry_parser_differential.sh` (new)
