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
