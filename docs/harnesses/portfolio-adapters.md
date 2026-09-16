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

In split-portfolio mode, installation also creates a `.apexyard-fork` anchor
and relative links for `.claude/hooks` and `.claude/settings.json` in the
private portfolio root. Managed workspaces can then resolve the canonical
framework hooks without a machine-specific absolute path or a harness-specific
environment variable.

Use `--check` for a read-only drift report. It reports missing workspaces,
missing adapter files, unsupported declarations, and stale Codex output with a
non-zero exit status. Cursor remains partial by design; its documented
fail-closed limitation is unchanged.

Supported declarations are `claude`, `codex`, `pi`, `opencode`, and `cursor`.
An explicit `adapters: []` field opts a project out of adapter management.

When `adapters` is omitted, the framework default is all four supported
third-party adapters. Set `adapters: []` only when a project intentionally
opts out; use a list to select a smaller set.
