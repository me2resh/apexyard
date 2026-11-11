# Status band

The `apexyard-status` plugin draws one line above the Claude Code prompt. The
line shows the active ticket, the PRs that wait for your `/approve-merge`, and
the reviewer lock of the session. The plugin only reads data. It checks open
PRs with one cached, read-only `gh pr list` call for each repo. It does not
replace a hook or a gate.

`/setup` asks if you want the band. If you skipped that question, run these two
commands from the ops-fork root:

```bash
claude plugin marketplace add ./ --scope local
claude plugin install apexyard-status@apexyard --scope local
```

The band is on only for you, on this machine. After `/update`, run
`/reload-plugins` to load the new version.

Full settings and behaviour: [`plugins/apexyard-status/README.md`](../plugins/apexyard-status/README.md).

The band also shows the CI state of the PR for the current branch. Each waiting PR shows its CI state.

## Approval pane

The optional `apexyard-gate` plugin adds an approval pane. Run `/gate-approve`
to open it. Each row shows the repo, the PR, the head SHA, the CI state and the
Rex verdict. **Approve** opens the Claude Code question menu for that exact
head SHA. Your choice in the menu records the approval through the menu hook
(AgDR-0234). The pane never writes a record and never merges.

Install it from the ops-fork root:

```bash
claude plugin install apexyard-gate@apexyard --scope local
```

Without the pane, every gate behaves as before. Full behaviour:
[`plugins/apexyard-gate/README.md`](../plugins/apexyard-gate/README.md).
AgDR-0296 records the split between the hooks, the plugins and the Cockpit.
