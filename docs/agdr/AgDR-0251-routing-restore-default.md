# AgDR-0251: Restore the framework model when a routing override is removed

> `apply-agent-routing.sh` rewrites an agent `model:` line from `agent-routing.yaml`.
> It stores the framework model in `.framework-defaults.json`.
> The next run used to build that file from the current overrides only.
> A removed override left the old model in the agent file and removed the drift baseline.
> The hook now reads the previous file and writes that model into each agent that has no override now.
> A missing or unreadable file restores nothing.

## Context

The SessionStart hook applies each `model` override to `.claude/agents/<name>.md`.
It records the framework model for that agent in `.claude/agents/.framework-defaults.json`.
That file is the drift baseline for `block-agent-routing-drift.sh`.

The apply loop visits only agents in the current routing file.
The hook then replaces the baseline with that same set.
An agent that left the routing file keeps the override model.
The same run omits that agent from the baseline.
The drift guard then has no stored model for the stale line.

Issue: me2resh/apexyard#1763.

## Glossary

| Term | Meaning |
|------|---------|
| Override | A `model` entry in `agent-routing.yaml` for one agent |
| Baseline | `.framework-defaults.json`, the map of agent name to framework model |

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Read `git show dev` for every agent file and reset any model that is not an override | Uses the committed framework model | Also changes an agent the hook never rewrote |
| Keep the stale model and keep the old baseline key | The drift guard can still compare | The agent keeps the wrong model |
| Read the previous baseline. Write its model only for an agent that was in it and has no override now. Omit that key. | Restores the line the hook wrote. Leaves every other agent file unchanged. A bad baseline does not invent a model. | A deleted routing file still exits on the zero-config path and does not restore |

## Decision

Chosen: **restore from the previous baseline**.

The hook reads `.framework-defaults.json` before it writes the new baseline.
Each key is an agent the hook rewrote on an earlier run.
The value is the framework model it saved.
If that agent has no `model` override on this run, the hook writes the saved model on the frontmatter `model:` line.
It does not change any other line.
It then omits that key from the new baseline.

These inputs are not a baseline. The hook restores nothing and exits 0.

- The file is missing.
- The file is not readable.
- The file is not a flat map of agent name to model string.

An agent that is not in the previous baseline is unchanged.

After a restore, the agent file has the framework model.
The drift guard reports no drift.
A staged file that still has an override still blocks.

## Consequences

- Remove an override and start a session. That agent returns to the saved framework model.
- The baseline no longer lists that agent.
- A corrupt baseline does not change agent files.
- Delete `agent-routing.yaml` and the hook still exits before restore. That path stays the zero-config path.

## Known limits

- The hook does not restore when `agent-routing.yaml` is absent. The zero-config exit stays in front of restore.
- A routing file that parses as no agents restores every agent in a valid baseline. A syntax error parses as an empty agent map.
- The hook replaces an existing frontmatter `model:` line. It does not insert a line that is absent.
- The hook reads the framework model from `dev`, then `upstream/main`, then `HEAD`. It uses a saved baseline value before it reads the working-tree file.

## Architecture evolution

### Before

The hook visited only agents in the current routing file.
It replaced `.framework-defaults.json` with that same set.
A removed override left the old `model:` line in the agent file.
The drift baseline lost that agent.

### After

The hook reads the previous baseline first.
It writes the saved model into each listed agent that has no model override now.
It omits that key from the new baseline.
An agent the hook never rewrote stays as it is.
A missing or unreadable baseline restores nothing and does not fail the session.
The drift guard still blocks a staged override.
A restored file matches the framework model, so the guard reports no drift.

The hook reads that model from `dev`, then `upstream/main`, then `HEAD`.
It uses a saved baseline value before it reads the working-tree file.
A fork with no local `dev` branch keeps the committed model in the baseline.

## Artifacts

- Issue: https://github.com/me2resh/apexyard/issues/1763
- Hook: `.claude/hooks/apply-agent-routing.sh`
- Guard: `.claude/hooks/block-agent-routing-drift.sh`
- Tests: `.claude/hooks/tests/test_agent_routing_sync_and_drift.sh`
- Related: [AgDR-0050](AgDR-0050-agent-runtime-overhaul.md)
