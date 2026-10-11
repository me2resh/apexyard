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

## Rules

- Display only. The plugin reads files. It runs read-only commands only: the ticket resolver, one open-PR list per repo, and `ps` when you set a pattern. It never writes a file. It never replaces a shell hook. All gates stay in `.claude/hooks/`.
- One network call, read only: `gh pr list --repo <owner/repo> --state open --json number,headRefOid --limit 200`. The plugin runs it only for a repo that has a candidate PR, at most once every 120 seconds for each repo, with a 5-second time limit. It keeps the result in memory only. It never calls a write endpoint.
- If `gh` is missing, is not signed in, fails or is too slow, the band counts from the markers only and shows `(offline)` next to the count.
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
| Reviewer lock | `.claude/session/active-reviewer.<session>` (`active_reviewer_marker_path`). |
| Build count | `ps -axo command=`, only when `build_process_pattern` is set. |

## Tests

```bash
claude plugin validate plugins/apexyard-status
claude plugin test plugins/apexyard-status
```

## Risk

The Claude Code plugin hook API is early access. A Claude Code release can change it. If it breaks, the band disappears. No gate is affected.

See AgDR-0227 for where fork-only plugins live.
