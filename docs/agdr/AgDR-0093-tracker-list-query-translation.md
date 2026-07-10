---
id: AgDR-0093
timestamp: 2026-07-03T09:00:00Z
agent: claude
model: claude-opus-4-8[1m]
trigger: user-prompt
status: proposed
---

# `tracker_list` + cross-tracker query-translation model

> In the context of read-side skills (`/inbox`, `/tasks`, `/stakeholder-update`) that hardcode `gh issue list` with GitHub-native search syntax and therefore return **nothing** on a GitLab-tracked project, facing the fact that the `_lib-tracker.sh` abstraction exposes `tracker_view` / `tracker_create` but **no list primitive at all** and that several GitHub search qualifiers (`commenter:>@me`, `mentions:@me`) have no 1:1 GitLab equivalent, I decided to add a **`tracker_list`** primitive driven by a small **generic filter vocabulary** (`state` / `assignee` / `author` / `labels` / `search` / `since`) that each per-kind adapter renders into its own CLI flags — **not** by parsing GitHub's search string — with no-equivalent qualifiers handled **client-side** (the precedent `/inbox` already sets), to achieve tracker-agnostic triage/listing for the issue axis, accepting that the forge axis (`gh pr list` → #711) stays `gh`-coupled and that a few exotic filters degrade to empty on non-GitHub trackers.

## Context

- **Read-side skills are blind on non-GitHub trackers.** `/inbox`, `/tasks`, `/stakeholder-update` call `gh issue list --search "…"` / `gh search issues "…"` directly. On a project whose `tracker.kind` is `glab` (GitLab), these silently return nothing — the exact failure #710's parent stack (#670) exists to close for the issue axis.
- **The tracker abstraction has no `list`.** `_lib-tracker.sh` (AgDR-0033, AgDR-0072) dispatches `tracker_view` (one issue) and `tracker_create` (create) by `tracker.kind` with per-kind adapters (gh / glab / linear / jira / asana / custom). There is nothing to list a *set* of issues. Unlike the creators — which were wired to an existing `tracker_create` — the read-side conversion must build a new primitive first.
- **The query filters don't map 1:1.** GitHub search is a rich string DSL (`author:@me commenter:>@me is:open`); GitLab's `glab issue list` is flag-based (`--assignee`, `--author`, `--label`, `--search`, `--opened`/`--closed`). Some GitHub qualifiers (`commenter:`, `mentions:`) have no GitLab CLI equivalent. So a design call is required — what is the cross-tracker query model? — which is why #710 is AgDR-worthy and asymmetric in effort with the creator sweep (#709).
- **Not all seven "read-side" skills are the same work.** Auditing the actual calls:

  | Tier | Skills | Issue-axis calls today | #710 disposition |
  |------|--------|------------------------|------------------|
  | **A — need `tracker_list`** | `/inbox`, `/tasks`, `/stakeholder-update` | `gh issue list` / `gh search issues` with search filters | **Converted** |
  | **B — single `gh issue view`** | `/status`, `/plan-initiative`, `/spike-close`, `/prototype-close` | a single `gh issue view` (NOT `gh issue list`) | **Deferred** — see below |

  **Issue-statement discrepancy (found during scoping).** #710's Problem statement lists the four Tier-B skills as hardcoding `gh issue list`. They don't — they each make a single **`gh issue view`** call, which is the *view* primitive (`tracker_view`, #671), not the *list* primitive this ticket adds. So #710's stated scope (`gh issue list` → `tracker_list`) does not, strictly, touch them.

  **Why Tier B can't be a clean `tracker_view` swap.** `tracker_view` returns exactly `{state,title,url,labels}`. The Tier-B call sites need more: `/status` reads `assignees` (+ `number`, already derived from the branch); `/plan-initiative` reads `body` (a race-safe re-fetch before splicing cross-refs); `/spike-close` + `/prototype-close` read `body` (consumed for the DISCARD memo's hypothesis/direction text). The discriminating test — *after converting, does the skill still hard-depend on a gh-only call?* — is **yes for all four** (`assignees` / `body` are not in `tracker_view`'s schema). A partial conversion would add a round-trip and still break on GitLab. Extending `tracker_view`'s schema (`body`/`assignees`) is a **separate design call** — it changes a shipped contract, every view consumer, and every adopter `view_command` template — so it is **deferred to a follow-up** (`/task`), not silently expanded here. Tier B is therefore out of #710's shippable scope.

- **The forge axis is out of scope (#711).** `/inbox`, `/tasks`, `/status`, `/stakeholder-update` are *dominated* by `gh pr list` calls (PRs awaiting review, approved-and-ready, failing CI, merged-since). Those are the PR/MR forge axis handled by #711. #710 therefore leaves these skills **partially converted** — issue-axis tracker-agnostic, forge-axis still `gh`-coupled. This must be stated in the PR body so the next reader does not assume `/inbox` became fully tracker-agnostic.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| **A. Translate GitHub's search string** — parse `author:@me is:open …` and rewrite per tracker | Callers keep writing familiar GH syntax | Brittle DSL parsing pointed the wrong way; every new qualifier is a parser change; no-equivalent qualifiers (`commenter:`) have nowhere to go; couples the model to GitHub's syntax forever |
| **B. Generic filter vocabulary → adapters render native** — callers pass `state`/`assignee`/`author`/`labels`/`search`; each kind renders its own flags; no-equivalent qualifiers handled client-side | Tractable, closed model; mirrors `tracker_create`'s function-with-args shape; new tracker = one adapter; GH-only qualifiers isolated to the skills that want them | A small filter vocabulary can't express every GH qualifier natively; some filters degrade (documented) |
| **C. Per-skill glab special-casing** — add `if kind == glab` branches inside each skill | No new primitive | Duplicates dispatch logic across 3+ skills; every new tracker touches every skill; abandons the abstraction the rest of the lib established |

## Decision

Chosen: **Option B — a `tracker_list` primitive over a generic filter vocabulary, adapters render generic → native.**

Concrete shape:

1. **`tracker_list <owner/repo> [key=value …]`** added to `_lib-tracker.sh`, mirroring `tracker_view`'s per-project resolution (the target repo selects the project's `tracker:` override, else the global block — never cwd, never a session marker; AgDR-0072 §3). Filters are passed as `key=value` positional args parsed via a `case` statement into plain locals — **bash 3.2-safe** (no `declare -A`, matching the lib's existing POSIX-param-expansion constraint).

2. **Generic filter vocabulary** (the source of truth; every filter optional):

   | Filter | Values | gh render | glab render |
   |--------|--------|-----------|-------------|
   | `state` | `open` (default) / `closed` / `all` | `--state open\|closed\|all` | `--opened` / `--closed` / `--all` |
   | `assignee` | `@me` / `none` / `<user>` | `--assignee @me\|<user>` (`none` → `--search "no:assignee"`) | `--assignee=@me\|<user>` (`none` → **client-side / degrade** — no clean glab flag) |
   | `author` | `@me` / `<user>` | `--author <user>` (`@me` resolved) | `--author <user>` |
   | `labels` | csv | `--label a,b` | `--label a --label b` (repeated) |
   | `search` | free text | `--search "<text>"` | `--search "<text>" --in title,description` |
   | `since` | ISO date | `--search "closed:>=<date>"` (or `updated:>=`) | **client-side** filter on `updatedAt` |

   Label semantics are preserved per-adapter as-is (GitHub `--label a,b` and GitLab repeated `--label` are both **AND**); the pre-existing `/tasks` intent of "high OR critical" is a GitHub-search limitation carried over unchanged, not introduced here — noted, not fixed in #710.

3. **No-equivalent GitHub qualifiers stay out of the generic model.** `commenter:>@me` and `mentions:@me` (cross-repo) have no GitLab CLI equivalent and must not force `tracker_list`'s shape. They are handled by the **existing client-side precedent**: `/inbox` already filters "new comments since last seen" client-side on `updatedAt`. Skills that want `mentions:` keep a **gh-only** path that returns empty on non-gh trackers, documented inline. Cross-repo `gh search issues` is a *different operation* than a repo-scoped list — it is **not** part of `tracker_list`.

4. **Normalised list-item schema** — a JSON **array**, each element mirroring `tracker_view`'s `{state,title,url,labels}` plus the two fields listing needs:

   ```json
   [{ "ref": "42", "number": 42, "state": "open", "title": "…",
      "url": "https://…", "labels": ["blocked"], "updatedAt": "2026-07-01T…" }]
   ```

   `ref` is the tracker reference **as a string** (callers must not do arithmetic — a future tracker may key `LIN-42`); `number` is the numeric convenience for gh/glab. PR-only fields (`mergeable`, `statusCheckRollup`, `reviewDecision`) are **explicitly excluded** — forge axis, #711. On failure (CLI missing/errored, `kind=none`) `tracker_list` emits `[]` and exits non-zero, so callers treat empty output as "nothing / unavailable" without special-casing.

5. **Built-in adapters `gh` + `glab`; `custom` reserved for the trusted template.** Same trust model as `tracker_create`: built-in adapters build `--flag "$val"` argv arrays (never string-eval untrusted filter values); the `list_command` template is reserved for the operator-authored `custom` kind. `linear`/`jira`/`asana` list adapters are **out of scope** for #710 (parent stack targets GitHub↔GitLab); until a follow-up adds them, unknown kinds fall through to the **gh best-effort default** — the same phasing `tracker_create` / `tracker_view` use for unrecognised kinds (a project on one of those trackers gets gh-shaped results, not silently `[]`).

6. **Tier B is deferred, not done here.** The four `gh issue view` single-reads (`/status`, `/plan-initiative`, `/spike-close`, `/prototype-close`) need fields `tracker_view` doesn't return (`assignees` / `body`), so converting them requires a `tracker_view` **schema extension** — a separate design call filed as a follow-up `/task`. #710 ships the `tracker_list` primitive + Tier A only.

Because Option A points the design the wrong way (parsing GitHub's DSL) and Option C abandons the abstraction, only B gives a closed, extensible model consistent with the `tracker_view` / `tracker_create` pattern the lib already validated.

## Consequences

- **Backward-compatible.** A github-kind fork sees byte-for-byte the same `gh issue list` results (the gh adapter renders the same flags). The default-config regression suite locks this in.
- **Skills are partially converted by design.** Issue-axis tracker-agnostic; forge-axis (`gh pr list`) still `gh`-coupled until #711. Stated in every #710 PR body to prevent a false "it's fully abstracted" read.
- **Some filters degrade on non-GitHub trackers** (`assignee=none`, `since`, `mentions:`, `commenter:`) — documented per-filter. Degradation is "empty / client-side," never a crash. The client-side `since` filter (glab / custom) **keeps** items with no `updatedAt` rather than dropping them — recency is unknowable for such items, and silently hiding one is worse than surfacing it.
- **`tracker_list` is a read, not a create** — it is **not** added to `ticket.create_command_patterns` (that guard is for creation). Listing needs no skill gate.
- **glab list adapter is written against the real CLI**, not recall — `glab issue list --help` confirms `--assignee=@me`, `--author`, `--label` (repeatable), `--search`+`--in`, `-O json`, `--opened`/`--closed`/`--all`. The one gap (`assignee=none`) is a known degradation.
- **Per-project resolution needs a YAML parser** (`yq` / `python3`+PyYAML), inheriting AgDR-0072's known edge: with no parser, a per-project `tracker:` block is silently ignored and the global tracker is used. Tests SKIP (not fail) when no parser is present, mirroring the `jq` guard.
- **Follow-up surface** — linear/jira/asana list adapters and the forge axis (#711) are explicitly deferred, not forgotten.

## Delivery

Single PR against `dev`: the `tracker_list` primitive + `test_tracker_list.sh` + this AgDR + Tier A conversions (`/inbox`, `/tasks`, `/stakeholder-update`). Tier B is **not** in this PR (deferred — see Decision §6). PR body: `Closes #710`, with two caveats called out — (a) the forge axis (`gh pr list`) stays gh-coupled until #711, and (b) the four `gh issue view` skills are deferred to a `tracker_view`-schema-extension follow-up — plus `Refs #670` for the parent stack.

**Follow-up to file:** a `/task` to extend `tracker_view`'s schema (`body` + `assignees`) and route the four single-view reads through it, so the skills #710's Problem statement named are not silently dropped.

## Artifacts

- #710 — the feature request this implements
- #670 / AgDR-0072 — per-project tracker config + `tracker_create` (the pattern this mirrors)
- AgDR-0033 — the original verification-abstraction pattern
- #709 — the creator-conversion sweep (sibling, issue-creation axis)
- #711 — PR/MR forge abstraction (the out-of-scope forge axis)
- `.claude/hooks/_lib-tracker.sh` — where `tracker_list` lands
- `.claude/hooks/tests/test_tracker_list.sh` — new test surface
