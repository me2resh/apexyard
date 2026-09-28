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
- **Round 4 correction (me2resh/apexyard#1457).** Three review rounds of
  entry-boundary special cases (scoping `public:` to its own entry;
  anchoring on the `projects:` key; accepting compact lists and bare-dash
  entries) kept finding a fresh valid YAML shape that made the structural
  parser lose track of the real `projects:` key and silently drop private
  tokens. The parser is inverted instead of patched again: the **private
  set is greedy** — every `name:`, `repo:`, `repos:` item and `workspace:`
  value anywhere in the file is private by default, independent of
  whether the structural parse can find or trust a `projects:` key at
  all — and the **public set must be proven**, meaning a value is exempt
  only when every one of its occurrences in that greedy scan is also
  accounted for by a structurally-confirmed `public: true` entry under
  the file's real top-level `projects` key. For valid YAML input, a
  structural-parser bug can now only fail to grant an exemption a
  project deserves (safe) or be refused by the correlation step anyway;
  it can no longer make a real private token disappear from the scrub
  list. A file the parser cannot make sense of at all is a different
  case: an ambiguous shape (a duplicate top-level `projects:` key, two
  YAML documents, or a tab in the indentation) does not silently drop
  anything either — it empties the public set for the whole file
  instead, so every entry, including the one that should have been
  exempt, is treated as private, and the parser writes one line to
  stderr naming the cause.
- **Round 5 correction (me2resh/apexyard#1457).** The round-4 exemption
  rule compared per-value OCCURRENCE COUNTS between the greedy (private)
  pass and the structural (public) pass, on the assumption that both end
  a `repos:` block list on the same line. They did not: the greedy pass
  ends the list at any key-shaped line (including a list item that is
  itself a map, `- primary: ...`), while the structural pass only ends
  it at the entry's own field column. A public entry whose `repos:` list
  had such an item before a slug it shared with a private entry could
  then have equal counts (1 each), exempting a token that was genuinely
  private elsewhere. Fixed by comparing LINE NUMBERS instead of counts:
  a token is exempt only when every line the greedy pass found it on is
  also a line the structural pass attributes to a proven public entry.
  Also tightened in the same round: an entry is public only when it has
  EXACTLY ONE `public:` key and that key's value is exactly `true` — a
  second `public:` key, even a second `true`, now makes the entry
  private, closing a path where a malformed or duplicated key could have
  been read charitably.
- **Round 6 correction (me2resh/apexyard#1457).** The greedy pass's own
  `repo:`/`workspace:`/`name:` checks matched a one-key `- repo: x` or
  `- workspace: x` list item before its generic repos-item fallback ran,
  closing an open `repos:` list and dropping every plain item after it
  — a valid-YAML shape that made the "can never disappear" claim above
  false again. Fixed by keeping the list open across every dash item at
  or deeper than the `repos:` key's own column, recording each item's
  value (and, for a multi-key map item, the value of every one of its
  keys), and closing it only on a line at or left of that column. Also
  hardened: a second `name:`, `repo:`, `repos:` or `workspace:` key in
  one entry — most often a missing leading dash typo — now makes the
  entry private too, the same as a duplicate `public:` key.

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
