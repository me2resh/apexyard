# Portfolio harness adapter management

The portfolio registry controls which harness adapters each managed project
receives. Add an `adapters` list to a project entry, for example:

```yaml
- name: example
  repo: owner/example
  workspace: workspace/example
  docs: projects/example
  status: active
  adapters: [codex, pi, opencode]
```

Run `bash bin/manage-portfolio-adapters.sh --install` after onboarding or an
ApexYard update. The command invokes the existing generators and installers;
`.claude/hooks/*.sh` remains the only enforcement source.

Use `--check` for a read-only drift report. It reports missing workspaces,
missing adapter files, unsupported declarations, and stale Codex output with a
non-zero exit status. Cursor remains partial by design; its documented
fail-closed limitation is unchanged.

Supported declarations are `claude`, `codex`, `pi`, `opencode`, and `cursor`.
An omitted `adapters` field means the project is not managed by this command.
