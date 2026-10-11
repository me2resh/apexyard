# apexyard-status

An optional Claude Code plugin for an ApexYard ops fork. It draws one line above the prompt:

```text
ApexYard apexyard#1541 Optional status band · 1 waiting for your /approve-merge: me2resh/apexyard#12 · review lock: me2resh/apexyard#13 (rex)
```

The line shows:

- The active ticket of the working tree, as `repo#N` and a short title.
- The PRs that have a Rex marker and no human-approval marker.
- The reviewer lock of this session, when it is set.
- The number of running build processes, when you set a build-process pattern.

The plugin shows a toast when a new Rex marker appears and when a build process ends. It refreshes after each turn and every 30 seconds.

## Rules

- Display only. The plugin reads files. It never writes a file. It never replaces a shell hook. All gates stay in `.claude/hooks/`.
- No network calls.
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
| Ops fork | The session pin `~/.claude/apexyard/ops-root-<session>` (or `$APEXYARD_OPS_PIN_DIR`). If the pin is missing or stale, a walk up from the working directory to a `.apexyard-fork` file, or to `onboarding.yaml` and `apexyard.projects.yaml` together. |
| Active ticket | The marker in the git dir of the working tree (`apexyard-ticket`, AgDR-0222). If none, the newest old-layout marker under `.claude/session/` (`current-ticket`, `tickets/**`). |
| Waiting PRs | `.claude/session/reviews/<owner>__<repo>__<pr>-rex.approved` with no matching `-ceo.approved` file (AgDR-0060 names). |
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
