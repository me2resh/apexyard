---
name: inbox
description: Show every item across managed projects needing the user's attention — PRs, assigned issues, comments, blockers.
allowed-tools: Bash, Read, Grep, Glob
---

# /inbox — Items Needing Your Attention

Aggregates everything that's currently waiting on **you** across the projects ApexYard manages. Designed to be the first thing you run in a session.

## Path resolution

Read the registry path via `portfolio_registry`, the per-project docs dir via `portfolio_projects_dir`, and the ideas backlog via `portfolio_ideas_backlog` — all from `.claude/hooks/_lib-portfolio-paths.sh`. Source the helper at the top of any bash block that touches those paths:

```bash
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-read-config.sh"
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-portfolio-paths.sh"
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-tracker.sh"
registry=$(portfolio_registry)
```

Defaults match today's single-fork layout (`./apexyard.projects.yaml`, `./projects`, `./projects/ideas-backlog.md`). Adopters in split-portfolio mode override the `portfolio.{registry, projects_dir, ideas_backlog}` keys in `.claude/project-config.json`. Don't hardcode literal `apexyard.projects.yaml` or `projects/` paths in bash blocks — the helper resolves whichever mode the adopter is in. See `docs/multi-project.md`.

## Tracker-agnostic issue listing (#710 / AgDR-0093)

The **issue** sections below (assigned to you, your issues with new comments, blocked items) call `tracker_list` from `_lib-tracker.sh` instead of hardcoding `gh issue list`, so they work on a project whose `tracker.kind` is `glab` (GitLab) too. Pass the project's `repo:` (from the registry) as the first argument — the tracker is resolved per-project — plus generic filters:

```bash
# tracker_list <owner/repo> [state=…] [assignee=@me|none|<user>] [author=…] [labels=csv] [search=…] [since=ISO] [limit=N]
# → emits a JSON array: [{ref,number,state,title,url,labels,updatedAt}, …]  ([] on empty/unavailable)
tracker_list "$repo" state=open assignee=@me limit=50 2>/dev/null
```

> **Scope caveat (forge axis, #711).** The **PR** sections still call `gh pr list` directly. The PR/MR forge abstraction is a separate ticket (#711); until it lands, `/inbox`'s PR sections are GitHub-only. `/inbox` is therefore *issue-axis* tracker-agnostic, not fully tracker-agnostic. Filters GitHub expresses but GitLab can't (`mentions:`, `commenter:`) stay on a gh-only path, documented at the section that uses them.

## Usage

```
/inbox
/inbox --me octocat
/inbox --since 24h
```

## Scope

`/inbox` iterates every project in `apexyard.projects.yaml` at the root of your ops repo (your fork of apexyard). If the registry doesn't exist, print a clear error pointing at `docs/multi-project.md`.

## What goes in the inbox

The inbox is grouped by section. Empty sections are omitted.

### 1. PRs awaiting your review

> Forge axis (#711) — GitHub-only until the PR/MR abstraction lands.

```bash
gh pr list \
  --search "is:open is:pr review-requested:@me" \
  --json number,title,url,headRepository,updatedAt,author \
  --limit 50
```

Run this per `repo:` from the registry (or use `--search "user:your-org"` if you have an org).

### 2. PRs you authored that have changes requested

```bash
gh pr list \
  --search "is:open is:pr author:@me review:changes_requested" \
  --json number,title,url
```

These are blocking **you**, not your reviewers — they're your inbox.

### 3. PRs you authored that are approved and ready to merge

```bash
gh pr list \
  --search "is:open is:pr author:@me review:approved" \
  --json number,title,url,mergeable,mergeStateStatus
```

Filter to ones where `mergeStateStatus` is `CLEAN` — those are ready to merge right now.

### 4. Issues assigned to you

Issue axis — tracker-agnostic via `tracker_list` (run per `repo:` from the registry):

```bash
tracker_list "$repo" state=open assignee=@me limit=50
# → [{ref,number,state,title,url,labels,updatedAt}, …]
```

### 5. Issues you opened that have new comments since you last looked

The "new comments since last looked" part is a GitHub-only search qualifier (`commenter:>@me`) with no GitLab equivalent, so `tracker_list` fetches your open-authored issues and the comment recency is filtered **client-side** (the established degradation for no-equivalent filters):

```bash
tracker_list "$repo" state=open author=@me
# Then filter client-side on `updatedAt` against a stored "last seen" timestamp
# if available, otherwise show everything from the last 7 days.
```

### 6. Mentions in comments

`mentions:@me` is a cross-repo GitHub-search capability (a *different operation* than a repo-scoped list) with no GitLab CLI equivalent, so this section stays on a **gh-only path** — it returns nothing on non-GitHub trackers, and `--no-mentions` hides it entirely:

```bash
# gh-only (degrades to empty on glab / other trackers):
if [ "$(tracker_kind "$repo")" = "gh" ]; then
  gh search issues "mentions:@me is:open" \
    --json number,title,url,repository,updatedAt
fi
```

### 7. PRs failing CI on a branch you authored

> Forge axis (#711) — GitHub-only until the PR/MR abstraction lands.

```bash
gh pr list \
  --search "is:open is:pr author:@me" \
  --json number,title,url,statusCheckRollup
```

Filter client-side to those where any check is `FAILURE`.

### 8. Blocking labels across managed projects

Issue axis — tracker-agnostic via `tracker_list` (run per project from the registry):

```bash
tracker_list "$repo" state=open labels=blocked
```

### 9. Reconcile — open issues that already have a merged PR (#923)

> Forge axis (#711) — GitHub-only until the PR/MR abstraction lands.

The sibling of the reconcile-before-build rule: that rule stops NEW drift at the spawn boundary; this section surfaces EXISTING drift that already happened. The signature is cheap and mechanical — an issue that is still `OPEN` but a merged PR already references it (`Closes #N` that didn't fire because the PR merged to `dev`, not the release branch; or `Refs #N` left open on purpose for a QA gate).

Fetch **once per repo**, not once per open issue — a batched query is the whole point, both for `gh` rate limits and for wall-clock time across a portfolio:

```bash
# 1. Open issue numbers for this repo (one call).
open_issues=$(gh issue list --repo "$repo" --state open --json number --jq '.[].number')

# 2. Merged PRs for this repo, bounded so the scan stays cheap (one call).
#    --limit 200 is a reasonable default; tighten it further with --search
#    "merged:>=<since-date>" on a very active repo, or when --since is passed.
gh pr list --repo "$repo" --state merged \
  --json number,title,body,url,mergedAt --limit 200
```

Then, for each merged PR's title + body, extract issue references and classify them:

- **Closing keywords** — `close[sd]?`, `fix(e[sd])?`, `resolve[sd]?` immediately followed by `#N` (case-insensitive). A match here against an issue still open is very likely a **release-cut artifact** — the PR's `Closes #N` didn't auto-fire because it merged to a non-default branch.
- **Referencing keywords** — `refs?`, `references?`, `related to` immediately followed by `#N`. A match here is likely an **intentional QA gate** — the ticket is deliberately held open pending verification (see `workflows/sdlc.md` Phase 5) — surface it as lower-urgency than a closing-keyword match.

**Conservative by construction**: only count a reference when a closing/referencing keyword sits directly next to the `#N` (not any bare number appearing anywhere in a PR body) AND `N` is in the `open_issues` set fetched in step 1. A PR that happens to mention an unrelated number, or a `#N` for an issue that's already closed, produces no flag. This is what keeps the section from ever flagging a genuinely-open or gated ticket.

**Graceful degradation**: if either `gh` call fails for a repo (rate limit, auth, network), skip that repo's contribution to this section and continue — same as Rule 5 below. If a repo produces zero matches, the section is simply absent for it (Rule 4).

## Output format

Group everything under headings, project-prefixed:

```
INBOX — 2026-04-06 09:14
=========================

🔴 PRs awaiting your review (3)
  · example-app#42  Add export to CSV         updated 1h ago   https://…
  · billing-api#8   Fix invoice rounding      updated 3h ago   https://…
  · marketing#12    Hero copy refresh         updated 1d ago   https://…

🟡 Your PRs with changes requested (1)
  · example-app#39  Refactor session store    Code Reviewer requested changes   https://…

🟢 Your PRs ready to merge (1)
  · example-app#41  Add health endpoint       2 approvals · CI green            https://…

📬 Issues assigned to you (4)
  · example-app#117 [Bug] Login fails on Safari       priority-high   https://…
  · billing-api#22  [Feature] Multi-currency support  priority-medium https://…
  · …

💬 New comments on issues you opened (2)
  · example-app#98   3 new comments since yesterday    https://…
  · marketing#5      Designer left a comment           https://…

🚨 PRs with failing CI (1)
  · example-app#42   lint job failed                    https://…

🛑 Blocked items (1)
  · billing-api#19   Waiting on API key from vendor     https://…

🔁 Reconcile — open issues with a merged PR (2)
  · example-app#88   Closes-but-open · merged PR #101 (release-cut?)   https://…
  · billing-api#31   Refs-open · merged PR #64 (QA gate?)              https://…

Summary: 12 items · 3 PRs to review · 1 ready to merge · 1 blocking CI failure · 2 to reconcile
```

If everything is empty:

```
✨ Inbox zero. Nothing waiting on you across {N} projects.
```

## Filters

| Flag | Effect |
|------|--------|
| `--me <user>` | Run as if `<user>` is the current user (default: `@me`) |
| `--since <duration>` | Only items updated in the window (e.g. `24h`, `7d`) |
| `--project <name>` | Limit to one project from the registry |
| `--no-mentions` | Hide the mentions section |
| `--no-reconcile` | Hide the Reconcile section (#923) |

## Rules

1. **Read-only** — never close, comment, or assign anything from this skill
2. **Always sort by recency within each section** — newest updates first
3. **Registry-scoped** — only projects listed in `apexyard.projects.yaml` count; never shell out to "all repos in the org"
4. **Skip empty sections** — don't print headers with `(0)`
5. **Never error on a single project** — if one repo is unreachable, mark it `?` and continue
6. **Always include URLs** — every row needs a clickable link
7. **No noise** — items where you have no possible action shouldn't appear (e.g. PRs you've already approved)
8. **Reconcile is a passive surface, not an action** — flag drift, never close/re-tag the issue or comment on the PR from this skill; the operator decides what to do with each flagged item

## Related skills

- `/tasks` — same data but flattened into a single ordered TODO list
- `/status` — current project's git/CI snapshot
- `/projects` — portfolio-level health snapshot

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*
