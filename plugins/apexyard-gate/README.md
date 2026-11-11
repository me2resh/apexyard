# apexyard-gate

An optional Claude Code plugin for an ApexYard ops fork. It adds an approval pane. The pane lists the PRs that wait for your merge approval. You approve one PR at a time with your own key presses.

The plugin is off until you install it. When it is off or missing, every gate behaves as before.

## What the pane shows

Run `/gate-approve` to open the **ApexYard approvals** pane. Each row shows:

- The repo and the PR number, for example `me2resh/apexyard#1683`.
- The full 40-character head SHA.
- The CI state: `pass`, `fail`, `pending`, `no checks` or `unknown`.
- The Rex verdict: approved at a SHA, or reviewed at an older SHA.
- An **Approve** button and a **Not yet** button.

A row lists a PR when a Rex marker exists, no CEO marker exists, and GitHub reports the PR as open. Press `r` to read the list again.

## How an approval works

An approval needs two key presses from you.

1. Press **Approve** on a row.
2. The pane reads the PR from GitHub again.
3. The pane refuses when the head SHA changed after the pane showed it. Press `r`, check the row again, and press **Approve** again.
4. The pane also refuses a closed PR, a red CI state, and a head that Rex did not approve.
5. The Claude Code question menu opens with `Approve and merge <owner>/<repo>#<pr> at <sha>?`.
6. Select **Approve and merge** in the menu.
7. The ApexYard menu hook writes the approval record for that exact SHA (AgDR-0234).
8. The pane reads the record and tells you the result.

Then ask Claude to merge. The merge gate checks the record against the live head SHA.

**Not yet** in the pane hides the row in this session until the head changes. **Not yet** in the menu, a closed menu, or free text records nothing.

## Rules

- The plugin never writes a file. The menu hook in `.claude/hooks/` writes the record.
- The plugin never merges. It never registers a tool hook or a settings hook.
- Only the Claude Code question menu returns your answer. Claude Code does not let a plugin fill in the answer.
- In a `claude -p` run, nobody can answer the menu, so the pane records nothing.
- Network calls are read only: `gh pr view <N> --repo <owner/repo> --json state,headRefOid,title,statusCheckRollup`. Each call has a 5-second time limit.
- The plugin reads the review markers in `<ops-root>/.claude/session/reviews/`.
- The plugin is a guardrail, not a security boundary (AgDR-0104). The gates in `.claude/hooks/` are the control.

## Install

Run these two commands from the ops-fork root:

```bash
claude plugin marketplace add ./ --scope local
claude plugin install apexyard-gate@apexyard --scope local
```

`local` scope writes only to `.claude/settings.local.json`, which git ignores. The pane is on only for you, on this machine.

To remove the pane, run `claude plugin uninstall apexyard-gate@apexyard --scope local`.

Install `apexyard-status` too if you want the band above the prompt. The band shows the active ticket, the CI state, the reviewer lock and the waiting PRs.

## Check it once after install

Do this check once in an interactive session:

1. Open the pane with `/gate-approve`.
2. Press **Approve** on a PR you want to merge.
3. Select **Approve and merge** in the menu.
4. Make sure the pane says "The menu hook recorded your approval".

If the pane says "The menu hook wrote no record", use `/approve-merge`. Report the Claude Code version in a framework bug.

## Settings

| Setting | Default | Meaning |
|---------|---------|---------|
| `waiting_window_days` | `3` | A Rex marker older than this number of days does not get a row. |

## Tests

```bash
claude plugin validate --strict plugins/apexyard-gate
claude plugin test plugins/apexyard-gate
bash .claude/hooks/tests/test_gate_plugin_off.sh
```

## Glossary

- **Head SHA**: the commit ID at the tip of the PR branch.
- **Rex marker**: the file that the code reviewer writes after an approval, `<owner>__<repo>__<pr>-rex.approved`.
- **Menu hook**: the PostToolUse hook that records the answer to the question menu (AgDR-0234).

See AgDR-0296 for the split between the hooks, this plugin and the Cockpit.
