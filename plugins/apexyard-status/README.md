# apexyard-status

An optional Claude Code plugin for an ApexYard ops fork. It draws one line above the prompt:

```text
ApexYard apexyard#1541 Optional status band · 1 waiting for your /approve-merge: me2resh/apexyard#12 · review lock: me2resh/apexyard#13 (rex)
```

The line shows:

- The active ticket of the working tree, as `repo#N` and a short title.
- The open PRs that Rex approved at their current head and that have no human-approval marker.
- The open PRs whose head moved after the Rex review ("needs re-review").
- The reviewer lock of this session, when it is set.
- The number of running build processes, when you set a build-process pattern.

The plugin shows a toast when a new Rex marker appears and when a build process ends. It refreshes after each turn and every 30 seconds.

## ORBIT initiatives

Run `/orbit-progress` to open the **ORBIT initiatives** pane.
Each row shows the initiative title from the Plan record.
Expand a row to see its Plan ID, revision, outcomes, criteria, evidence, and slices.
Press 1–9 or select a row to expand it.

Each row also shows open slice tickets, linked open PRs, approval counts, and the last activity time.
The plugin matches exact slice IDs in issue bodies.
It matches ticket references in PR titles or bodies.
Counts exclude closed tickets and PRs. Duplicate tickets and PRs count once per initiative.
Approval counts use GitHub's review decision. Ready counts require a clean merge state and a non-draft PR.
These counts describe GitHub status. ApexYard merge gates still apply.
The activity time is the latest returned issue or PR update time.
Failed GitHub queries show `(offline)` instead of zero counts.

The expanded row shows the reconciled date and the last no-change check date together.
The check date comes from `## Checks` in `docs/orbit/plans/<plan-id>.notes.md`.

The pane reads records from existing local `origin/main` and `origin/dev` refs every two minutes.
It does not fetch or change Git refs. Fetch the project clones separately to update their records.
It reads the registry at `apexyard.projects.yaml`, or the `portfolio.registry` path in `.claude/project-config.json`.
Relative workspace paths resolve from the registry directory.

## Rules

- Display only. The plugin reads files. It runs read-only commands only: the ticket resolver, cached GitHub queries, Git record reads, and `ps` when you set a pattern. It never writes a file. It never replaces a shell hook. All gates stay in `.claude/hooks/`.
- Band network call, read only: `gh pr list --repo <owner/repo> --state open --json number,headRefOid --limit 200`. The plugin runs it only for a repo that has a candidate PR, at most once every 120 seconds for each repo, with a 5-second time limit. It keeps the result in memory only. It never calls a write endpoint.
- If `gh` is missing, is not signed in, fails or is too slow, the band counts from the markers only and shows `(offline)` next to the count.
- Pane network calls use `gh search issues` and `gh pr list`. Each query is cached in memory for 120 seconds, including failures. Each call has a 5-second timeout and a 20-result limit. Counts describe those returned results. Expanding a slice reuses the same cache.
- Fork only. Outside an ops fork, the plugin draws nothing.

## Install

Run these two commands from the ops-fork root. `/setup` runs them for you when you answer "y" to the status-band question.

```bash
claude plugin marketplace add ./ --scope local
claude plugin install apexyard-status@apexyard --scope local
```

`local` scope writes only to `.claude/settings.local.json`, which git ignores. The band is on only for you, on this machine. The committed `.claude/settings.json` does not enable it.

To remove the band, run `claude plugin uninstall apexyard-status@apexyard --scope local`.

## Update

Claude Code reads the plugin from the fork folder. After `/update`, run `/reload-plugins`. You do not need to reinstall.

## Settings

Set these in `/plugin configure apexyard-status@apexyard`, or with `--config KEY=VALUE` at install.

| Setting | Default | Meaning |
|---------|---------|---------|
| `build_process_pattern` | empty (off) | A regular expression. The plugin counts the running processes whose command line matches it. Example: `codex exec\|cursor-agent`. |
| `waiting_window_days` | `3` | A Rex marker older than this number of days does not count as waiting. |

## Where the data comes from

| Item | Source |
|------|--------|
| Ops fork | The session pin `~/.claude/apexyard/ops-root-<session>` (or `$APEXYARD_OPS_PIN_DIR`). `APEXYARD_OPS_DISABLE_PIN=1` ignores the pin, as in the hooks. If the pin is missing or stale, a walk up from the working directory to a `.apexyard-fork` file, or to `onboarding.yaml` and `apexyard.projects.yaml` together. |
| Active ticket | The framework ticket-marker resolver, `.claude/hooks/_lib-active-ticket.sh` (AgDR-0222). The plugin runs `active_ticket_lookup` for the working directory and shows the marker that the resolver returns. The resolver applies the location rules, so the band shows the same ticket that the hooks use. |
| Waiting PRs | Candidates: `.claude/session/reviews/<owner>__<repo>__<pr>-rex.approved` (AgDR-0060 names) with no matching `-ceo.approved` file, inside the waiting window. A candidate waits for `/approve-merge` only if the PR is open and its head is the SHA in the Rex marker. An open PR with another head needs re-review. A merged or closed PR is dropped. A marker stays after a PR merges outside `/approve-merge`, so the markers alone show stale requests. |
| Reviewer lock | One file per review in `.claude/session/active-reviewers/<session>/` (`active_reviewer_marker_path`). The band lists every review. The plugin also reads the legacy `.claude/session/active-reviewer.<session>` file during the transition. |
| Build count | `ps -axo command=`, only when `build_process_pattern` is set. |

## Tests

```bash
claude plugin validate --strict plugins/apexyard-status
claude plugin test plugins/apexyard-status
```

## Risk

The Claude Code plugin hook API is early access. A Claude Code release can change it. If it breaks, the band disappears. No gate is affected.

See AgDR-0227 for where fork-only plugins live.
