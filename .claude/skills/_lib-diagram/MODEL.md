# Diagram model v1

Schema `apexyard.diagram/v1` is provisional until PR 3 for the diagram library merges.
This library has no skill callers yet. It requires Python 3.9 or later and uses only the standard library.
The model contains one repository. It contains no layout positions or absolute clone path.

## Commands

Run `python3 .claude/skills/_lib-diagram/diagram.py <command> <path> [--repo-dir <clone>]`.

| Command | Input | Output |
| --- | --- | --- |
| `validate` | Model JSON | Diagnostics on stderr |
| `mermaid` | Model JSON | Mermaid text on stdout, without a fence |
| `layout` | Model JSON | Canonical JSON positions on stdout |
| `html` | Model JSON | Self-contained ASCII HTML on stdout |
| `check` | Markdown | Drift diagnostics on stderr |

Every command returns 0 on success, 1 on validation or drift failure, and 2 on unreadable input or incorrect arguments.
Warnings do not change the return code. Failed validation produces no Mermaid, layout or HTML output.
`--repo-dir` is required for a non-null commit. It never becomes part of the model.

## Fields

Unknown fields fail with `E_SCHEMA` at every object level.
All fields below are required unless marked optional. An optional field remains absent during normalisation.

| Object | Fields |
| --- | --- |
| Root | `schema`, `diagram`, `generated`, `repo`, `groups`, `nodes`, `edges` |
| `diagram` | `type`, `title`, `project`, `direction` (`LR` or `TB`) |
| `generated` | `by`, `date`, both strings |
| `repo` | `name` string, `web_url` string or null, `commit` string or null |
| Group | `id`, `kind`, `label`. Optional: `parent` string or null, `description` |
| Node | `id`, `kind`, `label`. Optional: `technology`, `description`, `group` string or null, `tags`, `sources`, `attrs` |
| Edge | `from`, `to`. Optional: `id`, `label`, `technology`, `tags`, `sources`, `attrs` |
| Source | `path` string. Optional: `line` integer |

Labels, descriptions, technology, title and project are printable text, at most 200 characters.
Control characters, including literal newlines, fail validation. `attrs` is a map of strings on nodes and edges only.
Tags are arrays of lowercase words. Sources are arrays of source objects.
An absent group or parent means null. Absent tags and sources mean empty lists to consumers.

Ids match `^[A-Za-z][A-Za-z0-9_]{0,63}$`.
Nodes and groups share one id namespace. Edges have a separate namespace with unique ids.
Mermaid keywords are reserved case-insensitively. Ids ending in `_empty` are reserved for generated feature placeholders.
Self-loops are valid. The emitter preserves them, and layout routes them as back edges.

| Type | Node kinds | Group kinds | Group endpoints |
| --- | --- | --- | --- |
| `c4-context` | `person`, `system`, `external_system` | None | No |
| `c4-container` | `person`, `container`, `store`, `external_system` | `system_boundary` | No |
| `dfd` | `actor`, `external_service`, `process`, `store` | `trust_zone` | No |
| `feature` | `screen`, `route`, `model`, `job` | `layer` | Yes |

Groups nest to depth two. A root group has depth one.
An empty feature leaf group receives a `<group>_empty` Mermaid placeholder. The placeholder never enters the model or layout.

## Normalisation and hash

Normalisation copies the input. It removes exactly one leading `./` from each source path.
For an edge without an id, it hashes `from`, `to` and `label`, joined with newline characters, as UTF-8.
An absent label supplies the empty string. The id is `e_` plus the first ten SHA-256 hex characters.
Later duplicates receive `_2`, `_3` and subsequent suffixes in input order.
An automatic id that collides with an explicit id fails with `E_ID`.

The model hash excludes `generated` from the normalised model.
JSON serialisation uses `sort_keys=True`, `separators=(',', ':')` and `ensure_ascii=True`.
SHA-256 hashes the resulting ASCII bytes. Whitespace, key order and generation metadata therefore do not affect the hash.
Array order remains significant. Layout positions never enter the hash.

The markdown marker immediately precedes its Mermaid fence:

```text
<!-- diagram-model: sample.diagram.json sha256=<first 12 hex characters> -->
```

`check` accepts a basename in the markdown directory, including after symlink resolution.
It compares the marker hash and regenerated Mermaid text. It normalises markdown line endings.
If `sample.html` exists, it also checks its full `model_sha256` hash.
That hash must occur in exactly one `script` data block with type `application/json` and id `ay-diagram-data`.
This PR checks existing HTML data. It does not generate HTML.

## Repository evidence

A commit is 40 hex characters present in the supplied clone. A null commit requires empty source lists.
Source paths are repository-relative and at most 512 characters after normalisation.
Absolute paths, backslashes, empty segments, dot segments and control characters fail validation.
The validator lists the pinned tree with one `git ls-tree -r -z <commit>` call.
Only blob entries qualify. Gitlinks and directories do not qualify.
Cited line numbers are at least one. The validator reads cited blobs through one `git cat-file --batch` call.
Only UTF-8 blobs without NUL bytes support line numbers. Binary blobs can have path-only sources.
An empty text blob has zero lines. An unterminated final line counts as one line.
A dirty clone produces `W_DIRTY`. Evidence checks use committed blobs rather than working files.

`repo.web_url` matches `^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~-]+)+$`.
Credentials, queries, fragments and other schemes fail with `E_URL`.
`derive_web_url` converts SCP-style Git and `ssh://git@` remotes to HTTPS. It removes SSH ports and HTTPS credentials.
It removes a trailing slash and `.git`. An unsafe result returns null and a warning without the remote value.

## Mermaid escaping

Emission sorts groups, nodes and edges by id. Each group contains its direct nodes and child groups.
C4 uses `C4Context`, `C4Container`, `System_Boundary`, node macros and `Rel`.
DFD and feature diagrams use `flowchart` with labelled arrows.

All flowchart node, group and nonempty edge labels are double quoted, including pipe labels
(`-->|"Calls (HTTPS)"|`). Embedded double quotes use `#quot;`.
Ampersands, pipes, square brackets, angle brackets, backslashes, hashes, backticks and braces
use decimal Mermaid entities. Parentheses, commas, colons and slashes remain literal.

C4 node labels, technology, descriptions and boundary labels preserve punctuation literally
inside double quoted macro arguments. Embedded double quotes become ASCII apostrophes:
C4 node text does not decode entities, including `#quot;`.
C4 `Rel` labels and technology, and the title, use the flowchart entity rules because
those renderer fields decode entities. Thus they preserve double quotes as `#quot;`.

Validation rejects literal CR and LF before emission. Defensively, flowchart labels and
C4 relationships/title encode them as `#13;` and `#10;`; C4 node/boundary arguments
replace them with spaces.
No Mermaid CLI runs during automated tests. All four golden fixtures include parentheses,
commas, colons, ampersands, slashes, hashes, square brackets and embedded double quotes.
C4 fixtures also cover descriptions, container/store technology, relationships and boundaries.

## Layout contract

`layout` returns `nodes`, `groups`, `edges`, `width` and `height`.
Node and group maps contain boxes with integer `x`, `y`, `width` and `height` values.
Each edge contains four integer cubic-curve points, a `back` flag and a parallel-edge `offset`.
The committed model contains none of these positions.

1. Sorted-id depth-first traversal removes back edges, including self-loops, for ranking.
2. Longest paths through the remaining graph assign columns.
3. Top-level groups occupy separate horizontal bands, ordered by members' mean column, then group id.
4. Ungrouped nodes at or before the mean group column occupy the upper band. Other ungrouped nodes occupy the lower band.
5. Without groups, column-zero ungrouped nodes occupy the upper band. Later columns occupy the lower band.
6. Four alternating sweeps order each band's column by mean neighbour position, with id as the tie-breaker.
7. Each nested group occupies its own sub-band after its parent's direct nodes. Child groups follow sorted id order.
8. Group frames contain direct nodes and child frames, with padding. Sibling frames never overlap.
9. Feature root groups occupy separate columns ranked by edges. Disconnected ties use Screens, Routes, Jobs, Models, then id.
10. Feature members inherit their root column. Nested feature groups use separate vertical sub-bands within that column.
11. Edges connect the source's right side to the target's left side. Back edges arc above their bands.
12. Parallel edges receive increasing offsets in edge-id order. `TB` rotates all boxes and curve points.

Node boxes measure 220 by 88 pixels. Columns advance 400 pixels. Rows advance 128 pixels.
Layout uses no set iteration. Coordinates remain integers. Different Python hash seeds produce identical CLI output bytes.
Edges can cross boxes. Crossings are reduced, without a minimum-crossing guarantee.

## Diagnostics and fixtures

Diagnostics contain a stable code, JSON pointer and corrective hint. Messages omit unsafe field values.
Invalid fixtures use `tests/fixtures/invalid-<code>.diagram.json`, with numbered variants for URL failures.
Tests replace the illustrative pinned commit with a temporary repository commit for source fixtures.

| Code | Example fixture or test input |
| --- | --- |
| `E_SCHEMA` | Unknown root key in `invalid-E_SCHEMA.diagram.json` |
| `E_ID` | Reserved `end` id in `invalid-E_ID.diagram.json` |
| `E_KIND` | DFD container in `invalid-E_KIND.diagram.json` |
| `E_EDGE_UNKNOWN_NODE` | Missing endpoint in `invalid-E_EDGE_UNKNOWN_NODE.diagram.json` |
| `E_GROUP` | Parent cycle in `invalid-E_GROUP.diagram.json` |
| `E_SOURCE_PATH` | Parent traversal in `invalid-E_SOURCE_PATH.diagram.json` |
| `E_SOURCE_OUTSIDE` | Absent blob in `invalid-E_SOURCE_OUTSIDE.diagram.json` |
| `E_SOURCE_LINE` | Line nine of a two-line blob in `invalid-E_SOURCE_LINE.diagram.json` |
| `E_COMMIT` | Malformed commit in `invalid-E_COMMIT.diagram.json` |
| `E_URL` | Credentials in `invalid-E_URL-1.diagram.json`. Variants cover query, fragment, HTTP and JavaScript schemes |
| `E_LIMIT` | 201-character label in `invalid-E_LIMIT.diagram.json` |
| `E_DRIFT` | Edited Mermaid label in `test_check_changed_block` |
| `E_INPUT` | Unreadable or malformed JSON in `test_cli_exit_codes` |
| `W_DIRTY` | Changed working file in `test_warning_dirty` |

## Verification

Run each `tests/test_diagram_*.sh` wrapper or use Python unittest discovery in `tests/`.
The wrappers require Python 3.9 or later and disable bytecode writes.
Tests require no network, Mermaid CLI or third-party packages.
`stress-300.diagram.json` exercises 300 nodes, six bands and a cycle. The layout target is under two seconds.

## Glossary

- Model: the JSON source for generated diagram views.
- Normalisation: automatic edge ids and source-path prefix removal.
- Band: a horizontal region that separates groups or ungrouped nodes.
- Back edge: an edge removed during ranking because it returns to an active traversal ancestor.
- Drift: disagreement between the model and a generated view.
