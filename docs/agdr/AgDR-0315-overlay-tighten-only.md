# AgDR-0315: Limit the tightening guard to the sibling overlay

Date: 2026-11-22
Status: Implemented
Ticket: [#2127](https://github.com/me2resh/apexyard/issues/2127)

## Context

The owner decided on 22 November 2026 that the guard applies only to a new
sibling overlay layer. The repo's own project configuration must keep its
existing behavior. A guard on every project read removed valid exclusions
and the `off` and `observe` modes.

## Decision

Read the optional file `<overlay root>/.claude/project-config.json`.
Use the same private portfolio repo as `portfolio_resolve_template`: the
parent of `portfolio_registry`. This repo also holds custom skills and templates.
An in-fork registry does not create an overlay. Single-fork behavior stays intact.

Resolve defaults and project configuration with the existing readers first.
Then use `config_guard` to compare each scoped overlay value with that resolved
value. Do not compare with the shipped default.

| Setting | Accepted overlay change |
| --- | --- |
| `design_paths` | A superset of the resolved design path entries. |
| `design_paths_exclude` | A subset of the resolved design exclusions. |
| `ui_paths` | A superset of the resolved UI path entries. |
| `ui_paths_exclude` | A subset of the resolved UI exclusions. |
| `gates.<name>.mode` | An equal or higher mode rank. |

Compare literal entries. Rank modes as `off`, `observe`, then `enforce`.
Reject a loosening or invalid value in full. Keep the resolved project value.
Print one stderr line that names the setting and the overlay file.
A missing overlay value keeps the project value without a warning.
All other keys ignore the overlay layer in this ticket.
No production gate joins the mode allowlist.
The architecture design path setting remains `design_paths`.

## PR-base protection

Keep #2108 behavior. If a PR changes the project config, read the base-branch
config for the gate. Head path lists can still add coverage. Apply the overlay
to that resolved value. Read the overlay from disk because it is outside the
PR repo. Do not fetch an overlay copy from the PR base.

## Consequences

Project configuration can still replace path lists, add exclusions, and select
registered gate modes. The sibling overlay can extend coverage, remove project
exclusions, or raise enforcement. It cannot undo project coverage.
The shared config reader and unrelated settings do not change.

## Verification

`test_config_tighten_only.sh` builds separate project and overlay configs.
It checks rejected loosening values, accepted tightening values, project
loosening values, missing overlays, and base-branch reads. It checks warning
counts and file names. Its `--without-overlay` option runs the same cases with
pre-layer readers to show the new assertions fail before the layer exists.
The five restored regression tests retain their original assertions.
Run the targeted gate, UI path, architecture, and design test families and
ShellCheck on changed shell files.

## Glossary

- Overlay: optional configuration in the sibling private portfolio repo.
- Resolved project value: the value from the existing default and project readers.
- Tightening: added path coverage, fewer exclusions, or a higher mode rank.
