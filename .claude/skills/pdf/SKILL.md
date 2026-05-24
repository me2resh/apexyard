---
name: pdf
description: Convert markdown/HTML/BPMN to PDF (pandoc/md-to-pdf/wkhtmltopdf/bpmn-to-image), destination-prompted; graceful-degrades.
argument-hint: "<input-file> [--no-prompt] [--converter=pandoc|md-to-pdf|wkhtmltopdf] [--destination=workspace|projects|keep|<path>] [--project=<name>]"
allowed-tools: Bash, Read, Write
---

# /pdf — Export Any Doc to PDF

Convert a framework-generated document (markdown, HTML, BPMN) to PDF for sharing with non-technical stakeholders, board members, customers, or auditors.

Sits alongside `/c4` (Mermaid markdown), `/dfd` (Mermaid markdown), `/tech-vision` (markdown), `/write-spec` (PRD markdown), `/journey` (self-contained HTML), `/process` (BPMN XML), and the audit family (`/threat-model`, `/launch-check`, etc., all of which write dated markdown audits). Those skills emit a single source-of-truth artefact in its native format; `/pdf` is the dedicated bridge to PDF for the moments when prose isn't enough.

## The destination question

A PDF can land in one of two places, and the answer depends on whether the doc should **travel with the code** if the project spun out tomorrow. This mirrors the existing rule in `docs/multi-project.md`:

| If YES (travels with the code) | If NO (ApexYard's view) |
|---|---|
| Project's own repo: `workspace/<name>/docs/` | Ops fork: `projects/<name>/pdfs/` |
| Examples: API spec, deployment runbook, internal sequence | Examples: handover assessment, stakeholder update, launch-check verdict |

The skill **asks**, doesn't guess. The 4-option prompt below covers every common case.

## Usage

```
/pdf projects/curios-dog/architecture/vision.md
/pdf workspace/curios-dog/docs/architecture/context.md
/pdf projects/curios-dog/audits/security/2026-05-19.md
/pdf projects/curios-dog/journeys/checkout-v2.html
/pdf projects/curios-dog/processes/onboarding.bpmn
/pdf <input> --no-prompt                  # use default_destination from config
/pdf <input> --converter=pandoc           # force a specific converter
/pdf <input> --destination=workspace      # skip the prompt, write to workspace/<name>/docs/
/pdf <input> --destination=projects       # skip the prompt, write to projects/<name>/pdfs/
/pdf <input> --destination=keep           # skip the prompt, keep next to source
/pdf <input> --destination=/absolute/path/out.pdf  # explicit path
/pdf <input> --project=curios-dog         # override auto-detected project name
```

## Path resolution

Read `workspace_dir` and `projects_dir` from `.claude/hooks/_lib-portfolio-paths.sh` so split-portfolio adopters resolve to the sibling private repo transparently:

```bash
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-read-config.sh"
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-portfolio-paths.sh"
projects_dir=$(portfolio_projects_dir)
workspace_dir=$(portfolio_workspace_dir)
```

Defaults to single-fork (`./projects`, `./workspace`). Don't hardcode literal `projects/` or `workspace/` paths in the bash blocks below — let the helper resolve whichever mode the adopter is in.

## Process

### 1. Resolve the input file

```bash
INPUT="$1"
if [ ! -f "$INPUT" ]; then
  echo "/pdf: input file not found: $INPUT" >&2
  exit 2
fi
# Absolute path for downstream resolution
ABS_INPUT=$(cd "$(dirname "$INPUT")" && pwd)/$(basename "$INPUT")
```

### 2. Sniff the input format

By extension:

| Extension | Format |
|-----------|--------|
| `.md`, `.markdown` | Markdown |
| `.html`, `.htm` | HTML |
| `.bpmn`, `.bpmn20.xml` | BPMN |

Anything else → exit 2 with a clear "unsupported input format" message + the supported list.

### 3. Auto-detect `<name>` from the input path

The destination prompt needs a project name to fill in. Inference order:

1. If `--project=<name>` was passed → use it.
2. If `ABS_INPUT` is under `<projects_dir>/<name>/...` → `name` is the path segment after `projects_dir`.
3. If `ABS_INPUT` is under `<workspace_dir>/<name>/...` → `name` is the path segment after `workspace_dir`.
4. If neither matched (e.g. cwd is ops-fork root and input is `docs/foo.md`) → `name` is **unresolved**. The prompt will show "(no project — supply via --project)" in slots 1 + 2, and slots 3 + 4 remain valid.

### 4. Show the destination prompt

Always show this prompt unless `--no-prompt` or `--destination=...` was passed.

```
Where should the PDF land?

  (1) workspace/<name>/docs/<stem>.pdf  ← travels with the code
  (2) projects/<name>/pdfs/<stem>.pdf   ← ApexYard's view
  (3) <custom path>                     ← anywhere
  (k) keep next to source               ← <input-dir>/<stem>.pdf

  Hint: pick (1) if a downstream reader of the project repo would want
  this PDF (API spec, deployment runbook). Pick (2) if it's framework
  context (handover, stakeholder update, audit). Pick (k) when in doubt.

> 
```

When `<name>` couldn't be resolved, slots (1) and (2) print as `(no project — supply via --project)` and accepting them prompts for a name.

### 5. Compute the output path

```bash
STEM=$(basename "$INPUT")
STEM="${STEM%.*}"   # strip the extension
```

Filename rule:

- Default → `<stem>.pdf`
- **Audit-class outputs**: if `ABS_INPUT` matches `<projects_dir>/<name>/audits/<dim>/<YYYY-MM-DD>.md` (the dated-subdir convention from AgDR-0019), keep the date in the filename — the stem already contains it, so `<stem>.pdf` is correct as-is. No special case needed.

By destination:

| Destination | Output path |
|---|---|
| `1` / `workspace` | `<workspace_dir>/<name>/docs/<stem>.pdf` |
| `2` / `projects` | `<projects_dir>/<name>/pdfs/<stem>.pdf` |
| `3` / `<path>` | the operator-supplied path (relative to cwd, or absolute) |
| `k` / `keep` | `<dir-of-input>/<stem>.pdf` |

If the parent dir doesn't exist, `mkdir -p` it.

If the output file already exists, ask the operator: overwrite (`o`), pick a new path (`n`), or quit (`q`). No silent overwrite.

### 6. Run the converter

Delegate to `convert.sh` (the skill's converter-dispatch helper). It takes `--from`, `--to`, optional `--converter=<name>`, optional `--pdf-engine=<eng>`, and outputs to `--out`.

```bash
SKILL_DIR="$(dirname "$(realpath "$0")")"
"$SKILL_DIR/convert.sh" \
  --from="$ABS_INPUT" \
  --to="$OUT" \
  ${CONVERTER:+--converter="$CONVERTER"} \
  ${PDF_ENGINE:+--pdf-engine="$PDF_ENGINE"}
RC=$?
```

`convert.sh` exit codes:

- `0` — converted cleanly
- `1` — conversion failed (offending converter output streamed to stderr)
- `2` — bad input / unsupported format
- `3` — no converter available; advisory printed to stderr naming each install option. The skill propagates this exit code.

### 7. Report

On success:

```
✓ PDF written: <OUT>
  Source:     <ABS_INPUT>
  Format:     <markdown|html|bpmn> → PDF
  Converter:  <pandoc|md-to-pdf|wkhtmltopdf|bpmn-to-image+pandoc>
  Size:       <size>
```

On exit 3:

```
✗ No PDF converter is installed.

Markdown inputs can use:
  • pandoc           — brew install pandoc (or apt-get install pandoc)
                       For best output also install xelatex (mactex / texlive-xetex)
  • md-to-pdf (npm)  — npm install -g md-to-pdf  (or run via npx, no install)

HTML inputs can use:
  • wkhtmltopdf      — brew install --cask wkhtmltopdf
  • pandoc           — same as above (uses its HTML reader)

BPMN inputs need a two-step pipeline:
  • bpmn-to-image (npm) → SVG → pandoc → PDF

Install at least one of the above and re-run /pdf.
```

The skill **does not silently fall back** to leaving you without a PDF — it explicitly exits 3 so the operator knows the gap and can fix it.

## Config

`.claude/project-config.defaults.json` ships a `pdf` block:

```json
"pdf": {
  "preferred_converter": "pandoc",
  "pdf_engine": "xelatex",
  "default_destination": "ask"
}
```

- `preferred_converter` — when both pandoc and a fallback are installed, prefer this one. `null` means "first one found in the dispatch order".
- `pdf_engine` — passed to pandoc as `--pdf-engine=<engine>`. Common values: `xelatex` (best Unicode), `pdflatex` (smaller install), `wkhtmltopdf` (no LaTeX needed but degraded typography).
- `default_destination` — used when `--no-prompt` is passed. Must be one of `workspace`, `projects`, `keep`, or `ask`. `ask` with `--no-prompt` is an error (the skill exits 2 — operator must change config or drop `--no-prompt`).

Adopters override in `.claude/project-config.json`:

```json
{
  "pdf": {
    "preferred_converter": "md-to-pdf",
    "default_destination": "keep"
  }
}
```

## Rules

1. **Always ask about destination** unless `--no-prompt` or `--destination=...` was passed. The "would it follow the code?" question is genuinely contextual; guessing wrong creates landed-in-the-wrong-repo cleanup work.
2. **Never silently overwrite** an existing PDF. Always prompt or require `--destination=<explicit-path>` which the operator owns.
3. **Graceful degrade only on missing dep, not on conversion failure**. Missing converter → exit 3 + advisory. Converter installed but threw an error → exit 1 + propagate the converter's stderr. The two are different failure modes with different fixes.
4. **Source format detection by extension only**. We don't sniff content (would add complexity for marginal value — operators know what they're converting).
5. **No special-case templates**. v1 uses the converter's defaults. Custom LaTeX templates, branded header/footer, etc. are out of scope (separate ticket).
6. **No batch mode**. One input → one PDF. If the operator needs ten, they loop in shell. Keeps the skill's destination-prompt logic single-purpose.

## When to use this

| Trigger | Use `/pdf`? |
|---------|-------------|
| Board needs a one-pager PDF of a PRD | Yes |
| Sharing an audit verdict with a customer | Yes |
| Customer-facing API documentation | Yes (write to `workspace/<name>/docs/`) |
| Internal stakeholder update | Yes (write to `projects/<name>/pdfs/`) |
| Quick-share a diagram from `/c4` for a meeting | Yes (use `keep` to drop next to the source) |
| Replace the source markdown with the PDF | No — the source stays canonical; PDF is a render |
| Batch-converting 50 audit reports | No — loop `/pdf` in shell, the skill stays single-input |

## Out of scope (v1)

- **`--pdf` flag on each doc-emitting skill** that converts at write-time. Cleaner one-command UX but couples every doc skill to the converter dep. Standalone `/pdf` is v1; per-skill integration can land in v1.5 if operator usage demands it.
- **Custom LaTeX templates / branding / headers / footers**. Use system pandoc defaults for v1.
- **Batch export across multiple inputs**. Loop in shell.
- **Auto-watch + regenerate on source change**. Out of scope.
- **PDF accessibility audit** (tagged structure, alt-text propagation). The accessibility-audit skill covers the source markdown; PDF accessibility is a downstream concern.

## See also

- AgDR-0034 — converter dispatch + destination prompt rationale + standalone-skill vs flag-on-each-skill decision
- `docs/multi-project.md` § "Architecture diagrams" — the "would it follow the code?" rule extended to PDF outputs
- `.claude/skills/process/lint.sh` — graceful-degrade-on-missing-dep pattern that this skill mirrors for converter detection
- `.claude/skills/_lib-mermaid-lint.sh` — same pattern, npx-fallback case

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*
