# First-Class Multi-Repo Registry Project

> In the context of the ApexYard portfolio registry (`apexyard.projects.yaml`) modelling a project as exactly one repo, facing a real disclosure gap where a multi-repo product's non-primary repos were invisible to leak protection, I decided to add a plural `repos:` (+ optional `primary:`) schema — backwards-compatible with singular `repo:` — and make every registry consumer read a list, to close the leak-scrub gap and let a genuinely multi-repo product register as ONE governed project, accepting that portfolio-view aggregation (`/projects`, `/inbox`, `/tasks`, `/status`, `/handover`) stays deferred ergonomics rather than landing in this same change.

## Context

`apexyard.projects.yaml` entries carried a singular `repo: owner/name` field, and every consumer assumed exactly one repo per project. That breaks down for a common real shape: one product split across several repos (a backend, a gateway, N workers) that deploy together and are governed as one thing. Before this change, adopters had two options, both wrong:

- **Register N separate projects** — N repeated assessments, N registry rows, a `/projects` view implying N independent products where there is one.
- **Register one project naming the "primary" repo** — the other repos become invisible to every registry-driven mechanism.

The second option is the dangerous one, not merely cosmetic. `block-private-refs-in-public-repos.sh` — the hook that scrubs registered private project identifiers out of anything written to a public framework repo (`me2resh/apexyard`) — built its scrub list by reading one `name:`/`repo:`/`workspace:` triple per project entry. A project registered under one of its four repos left the other three repo slugs completely unscrubbed. The whole point of that hook is that an agent has the private repo names right in front of it while filing an upstream bug report and must actively suppress them; naming a system's other repos in a bug report ("also reproduces in the gateway repo") is exactly the natural thing to write. That is a real, mechanical disclosure gap, not a hypothetical one — see me2resh/apexyard#1123 for the handover session that surfaced it (a four-repo system where choosing the single-entry registration route would have silently dropped three of the four repo slugs from the scrub list).

The same singular assumption showed up in `_lib-tracker.sh` (per-project tracker override resolution keyed only on `.repo ==`) and `_lib-multi-repo-trace.sh` (the `/dfd` / `/process` cross-repo trace registry parser, which only ever emitted one repo per project line). `_lib-project-board.sh` was investigated too and turned out **not** to carry the assumption — GitHub Projects v2 boards are already an org-level construct spanning multiple repos, and `board_move_card` operates purely on a configured `owner`/`board_number` plus an issue/PR number, never on a per-project `repo:` lookup. No change was needed there; that's a finding, not an oversight.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| **Register N separate projects for one product** (the pre-existing workaround) | No schema change; works today | N repeated assessments/docs; `/projects` shows N rows for one product; no shared per-product framing |
| **Register one project under its "primary" repo only** (the pre-existing, dangerous workaround) | Unified docs; no schema change | Non-primary repos invisible to leak-scrub, tracker resolution, and cross-repo trace — the disclosure gap this AgDR exists to close |
| **N entries pointing at the SAME `docs:` directory** (the workaround noted in the originating issue) | Leak protection, tracker resolution, and board mapping all work correctly per-repo since each repo gets its own registry entry; docs stay unified | Only fixes the storage/consumer layer by brute force — `/projects` still renders N rows for one product; doesn't create a genuine single-project identity |
| **First-class plural `repos:` (+ optional `primary:`), singular `repo:` kept fully valid** (chosen) | One project, one row, ALL repos visible to every consumer that reads the list; zero behaviour change for the ~100% of adopters still on singular `repo:` | Every registry consumer must be updated to read a list instead of a scalar — real but bounded surface area; portfolio-view skill aggregation (rendering one row per project across repos) is a separate, larger piece of work than the schema + security fix |

## Decision

Chosen: **first-class plural `repos:` schema**, because it is the only option that makes a multi-repo product a genuine single registry entry (not N entries wearing a shared-docs bandage) while making the security fix — every consumer reads the full list, not the first entry — a natural consequence of the schema change rather than a separate patch bolted onto the old singular field.

**Schema contract:**

```yaml
- name: some-platform
  repos:                          # plural; singular `repo:` stays fully valid
    - owner/backend
    - owner/gateway
    - owner/worker-a
    - owner/worker-b
  primary: owner/backend          # optional — which repo tracker/board default to
  workspace: workspace/some-platform
  docs: projects/some-platform
```

- `repo: X` is **defined to behave identically** to `repos: [X]` with no explicit `primary:` — every registry consumer treats the two forms the same. This is verified directly, not assumed: `.claude/hooks/tests/test_multi_repo_registry.sh` asserts a one-element `repos:` project produces byte-identical leak-scrub and tracker-resolution behaviour to an equivalent singular-`repo:` project.
- `primary:` is optional; when omitted, `primary` defaults to the first entry of `repos:`.
- **Leak protection deliberately ignores `primary:` entirely** — every repo in a project's `repos:` list is scrubbed on the same footing; the security control must not privilege one repo over the others, because all of them are private identifiers.
- A project should use ONE of `repo:` / `repos:`, not both — if both are present (a misconfiguration), `repos:` wins as the authoritative repo set and `repo:` is used only as a `primary:` fallback hint. This is a documented degrade for a malformed entry, not a supported shape.

**What changed, per consumer:**

| Consumer | Change |
|----------|--------|
| `apexyard.projects.yaml.example` | Documents `repos:`/`primary:`, adds a worked multi-repo example (Example 5) |
| `block-private-refs-in-public-repos.sh` | Step 7's registry-scrub awk parser now walks a `repos:` block list (or flow list) alongside singular `repo:`, emitting one `REPO=` line per repo — the security core of this change |
| `_lib-tracker.sh` (`_tracker_project_value`) | Per-project tracker override selector now matches `.repo == <target>` **OR** `<target>` is a member of `.repos[]` — a caller passing any of a multi-repo project's repos finds the same override |
| `_lib-multi-repo-trace.sh` (`_mrt_parse_registry` + consumers) | Registry parse line gains an `<all_repos>` field; `mrt_resolve_target`'s tier-4 URL/slug match now checks every repo in the list, not only the (now explicitly primary) field 2; two new public helpers, `mrt_primary_repo_for` and `mrt_repos_for` |
| `_lib-project-board.sh` | No change — investigated, does not carry the singular-repo assumption (see Context) |
| `/projects`, `/inbox`, `/tasks`, `/status`, `/handover` aggregation (rendering one row per project, not one per repo) | **Deferred.** See Consequences |

## Consequences

- Leak protection now scrubs every repo of a multi-repo project. `.claude/hooks/tests/test_multi_repo_registry.sh` asserts this directly: a non-primary repo slug (and a third repo, to prove the fix covers the whole list, not just "first two") is blocked with the same `project repo: <slug>` message the primary repo already got.
- Every existing single-repo fork sees **zero behaviour change** — `repo:` is untouched as a schema, and the added `repos[]` OR-arm in each consumer's matching logic never fires when a project has no `repos:` field. The full existing 74-case `test_block_private_refs.sh` suite and the existing `test_per_project_tracker.sh` suite pass unmodified against this change.
- `_lib-tracker.sh`'s yq expression uses `contains([...])` for membership testing, not `index(...)` — verified directly against the installed mikefarah yq v4.53.3, whose lexer rejects `index()` outright ("invalid input text"). This was caught by re-running the existing per-project-tracker regression suite after the first draft of the fix, which silently regressed to global-default resolution because the yq error was swallowed by the existing `2>/dev/null` and the python3+PyYAML fallback isn't installed in this environment either. Recorded here so a future contributor extending this selector doesn't reach for `index()` and reintroduce the same silent failure.
- **Deferred**: `/projects`, `/inbox`, `/tasks`, `/status`, and `/handover` still render one row per **registry entry**, not one row per **project** — a multi-repo project registered under this new schema shows as a single entry (correct), but none of these skills yet aggregate PR/issue counts, CI status, or harnessability findings across all of a project's repos into that one row. The originating issue (#1123) explicitly deprioritises this: "the others are ergonomics, this one [leak-scrub] is a disclosure boundary." Doing the skill-side aggregation properly means touching five markdown-defined skill flows, each with its own rendering logic — a materially larger, separate piece of work from the schema + security-consumer fix in this PR. Filed as an explicit follow-up rather than silently left undiscovered; see the PR body's "Deferred" section for the concrete next step.
- `_lib-project-board.sh` needed no change. Recording this explicitly (rather than silently skipping it) because the originating issue named it as a suspected singular-assumption site; the actual mechanism (GitHub Projects v2 board, addressed by `owner`/`board_number` + item number, no per-project repo lookup) turned out to already be repo-agnostic.

## Artifacts

- me2resh/apexyard#1123 (originating issue)
- `.claude/hooks/block-private-refs-in-public-repos.sh` (step 7 — scrub-list extraction)
- `.claude/hooks/_lib-tracker.sh` (`_tracker_project_value`)
- `.claude/hooks/_lib-multi-repo-trace.sh` (`_mrt_parse_registry`, `mrt_resolve_target`, `mrt_primary_repo_for`, `mrt_repos_for`)
- `apexyard.projects.yaml.example` (schema docs + Example 5)
- `.claude/hooks/tests/test_multi_repo_registry.sh` (new — the security AC, backwards-compat, one-element equivalence, and tracker/trace resolution cases)
