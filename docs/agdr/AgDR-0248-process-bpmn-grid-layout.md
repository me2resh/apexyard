---
id: AgDR-0248
timestamp: 2026-10-19T00:00:00Z
agent: platform-engineer
model: claude-opus-5-5
session: 01APKsGE9ibyBP9TNeeAZi7y
trigger: user-prompt
status: executed
category: tooling
---

# AgDR-0248: Lay out `/process` BPMN with a Python grid script

> Issue 1726 shows that `bpmn-auto-layout` cannot lay out a laned BPMN model.
> The `/process` skill now uses a standard-library Python 3 grid layout.
> Python 3.9 or later is a prerequisite for the layout step.

## Context

AgDR-0025 section 2 chose the `bpmn-auto-layout` npm package for the `<bpmndi>` block. It rejected a hand-written layout as "a multi-week ticket with worse results".

Issue 1726 found two defects in that choice.

- The package has no CLI. `npx bpmn-auto-layout` fails with "could not determine executable to run". The skill never produced a layout.
- The package ignores lanes and pools. Even through a wrapper, every lane would be flattened.

The judgement that a hand-written layout is a multi-week ticket no longer holds. The shipped script `layout-bpmn.py` has about 170 lines and a regression test. It needs only the Python standard library. It places each node in a column by longest path, with back edges removed. It places each node in a row by lane. It routes each backward flow through a corridor at the top of its lane.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Keep `bpmn-auto-layout` as a library, called from a Node wrapper | Keeps the earlier choice | Still ignores lanes and pools. Adds a wrapper to maintain. |
| Use `elkjs` or another Node layout library | Better edge routing | New dependency. Needs lane handling written on top. More code than the grid. |
| Python 3 grid layout (standard library) | Draws lanes and pools. Same output for the same input. No download. Small. | New runtime. Plain grid, not a general graph layout. |
| User places shapes by hand | No code | Defeats the share-and-review workflow. Repeats on every run. |

## Decision

Chosen: **Python 3 grid layout**, because it is the only option that draws pools and lanes with no new package.

- `python3` 3.9 or later is a prerequisite for the layout step. `ET.indent` needs 3.9.
- `--skip-layout` needs no Python.
- Node is still needed for `bpmnlint` only.
- The skill drops flow names on flows that do not leave a branching gateway. This matches the ticket and keeps labels readable. The name stays in the process-source file.

## Consequences

- The skill has a second runtime. The prerequisite table in `SKILL.md` and `docs/multi-project.md` list it.
- Fallback: the earlier Node fallback emitted bare BPMN with a warning. The first version of the change exited 2 without Python. That change was not intended. `generate-bpmn.sh` now keeps the earlier behaviour. When `python3` 3.9 or later is missing, it warns and writes bare BPMN. An invalid model still exits non-zero with one message that names the missing node.
- Known debt: a forward flow that skips a column can cross a shape in a middle column. Its vertical leg is in the source column gap and its horizontal leg is at the target row. Loop flows do not have this problem. The advisory stays until a ticket asks for routing around shapes.
- `bpmn-auto-layout` is no longer used by the skill.

## Artifacts

- Issue 1726. PR 1764.
- `.claude/skills/process/layout-bpmn.py`
- `.claude/skills/process/generate-bpmn.sh`
- `.claude/skills/process/tests/test_process_bpmn.sh`
- Supersedes AgDR-0025 section 2 (layout strategy).
