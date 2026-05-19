# AgDR-0034 — `/pdf` skill: converter dispatch + destination prompt

> In the context of framework-generated docs (markdown, HTML, BPMN) needing PDF export for non-technical audiences, facing the choice of how to surface PDF export without forcing every adopter to install a heavy LaTeX stack, I decided to ship a **standalone `/pdf` skill** with **dispatch across pandoc / md-to-pdf / wkhtmltopdf / bpmn-to-image** and an **interactive destination prompt** that mirrors the "would it follow the code if the project spun out?" rule, accepting that PDFs become first-class but only when an operator explicitly converts.

## Context

The framework already emits a handful of document classes, each in its native format:

- `/write-spec` and `/feature` → Markdown
- `/c4`, `/dfd`, `/tech-vision` → Mermaid in Markdown (renders inline on GitHub)
- `/journey` → self-contained HTML with clickable modals (AgDR-0016)
- `/process` → BPMN 2.0 XML (renders in Camunda Modeler; AgDR-0025)
- `/threat-model`, `/launch-check`, `/compliance-check`, `/seo-audit`, etc. → dated Markdown audits under `projects/<name>/audits/<dim>/<YYYY-MM-DD>.md` (AgDR-0019)

These formats are right for the source of truth (text-diffable, GitHub-renderable, version-controlled). They are wrong for sharing with board members, customers in non-engineering roles, regulators, and auditors who expect a PDF attachment. The friction point: operators were copy-pasting markdown into Notion / Google Docs / Pages / Word, fixing the rendering by hand, then exporting to PDF — losing the source ↔ shared-artefact link.

The decision space had three live axes:

1. **Standalone `/pdf <input>` vs `--pdf` flag on every doc-emitting skill.**
2. **Hardcode one converter (pandoc) vs dispatch across multiple.**
3. **Default destination (auto-pick) vs operator prompt at export time.**

## Options Considered

### Axis 1 — Standalone skill vs per-skill flag

| Option | Pros | Cons |
|--------|------|------|
| Standalone `/pdf <input>` | One place to maintain converter logic. Adopters who never want PDF pay zero install cost. Decoupled from doc skills — `/c4` doesn't have to know about pandoc. Works on any markdown/HTML, including hand-written ones (not just framework-generated). | One extra step at use time (`/pdf <path>` instead of `--pdf`). |
| `--pdf` flag on each doc skill | One-command UX (`/c4 --pdf` writes both `.md` and `.pdf`). | Couples every doc skill to the PDF converter dep. `/c4`, `/dfd`, `/tech-vision`, `/write-spec`, audit family — all become PDF-aware. Adopters who never want PDFs still install pandoc. Drives the converter logic into N skills or one shared lib that every skill imports. |

### Axis 2 — Single converter vs dispatch

| Option | Pros | Cons |
|--------|------|------|
| Hardcode pandoc | Best output quality. Broadest input support (markdown, HTML, LaTeX, reST, ...). Single install path to document. | Pandoc + xelatex is ~500MB. Adopters on Alpine / minimal Linux / WSL with limited disk balk. No graceful degrade — adopters without pandoc just can't use `/pdf` at all. |
| Dispatch pandoc → md-to-pdf → wkhtmltopdf | Adopter chooses their stack. md-to-pdf via `npx` needs no global install. wkhtmltopdf works on HTML inputs without LaTeX. Graceful-degrade pattern matches `/process` (bpmnlint) + `/c4` (Mermaid lint). | More code. Each backend has quirks (md-to-pdf swallows stdin, wkhtmltopdf needs `--enable-local-file-access` for embedded images, etc.). |
| Browser-based (puppeteer / playwright) | Modern, supports CSS3, runs anywhere with Node. | Chromium download is ~170MB and is a recurring "what is `chrome.app` in my cache?" question from adopters. Slow startup (~3s per conversion). |

### Axis 3 — Default destination vs prompt

| Option | Pros | Cons |
|--------|------|------|
| Auto-pick based on input path | Zero-prompt UX. If `<input>` is under `projects/<name>/`, write to `projects/<name>/pdfs/<stem>.pdf` and call it done. | Wrong for the most important class of PDF (customer-facing docs that need to ship in the project repo). Auto-picking the wrong dir creates cleanup work. Mirrors AgDR-0007's "skill should ask, not guess" principle from the release-cut decision. |
| Always prompt | The skill asks once at export time, matching the operator's mental model of "this PDF is going to {a customer / the board / my own files}". Same shape as the C4 / DFD / vision skills' "edit list, accept" loop. | Slightly slower (one extra prompt). |
| Operator config locks the default | Adopters who always pick `workspace` can set `default_destination: workspace` in `.claude/project-config.json` + pass `--no-prompt`. | Two layers of indirection — the prompt + the override. But these are independently useful. |

## Decision

### Chosen on axis 1 — **Standalone `/pdf`**

The decoupling argument wins. Most adopters won't want every doc skill to emit a PDF (markdown is the source; PDFs are a derivative for the small subset of shares that need them). The cost of `--pdf` as a flag on every doc skill is N skills × one converter dep, all paid by every adopter. The cost of standalone `/pdf` is one extra command at use time, paid only by operators who actually want a PDF. The math favours decoupling.

Per-skill `--pdf` flags are listed as **deferred (v1.5)** in the ticket. If adopters ask for them after v1 lands, the per-skill flag becomes a thin wrapper that shells out to `/pdf` — no extra converter code, just UX sugar.

### Chosen on axis 2 — **Dispatch with graceful degrade**

`convert.sh` detects which converters are on `PATH` (pandoc / wkhtmltopdf / npx-for-md-to-pdf-and-bpmn-to-image) and picks the best fit for the input format. When none are installed, exit 3 with an advisory naming each install option — same shape as `/process`'s `lint.sh` and `_lib-mermaid-lint.sh`.

The "preferred" converter is configurable (`pdf.preferred_converter` in `.claude/project-config.json`) for adopters who explicitly want md-to-pdf (Node shop, no LaTeX) over pandoc.

Browser-based puppeteer/playwright was rejected for the Chromium-cache pain — adopters who want browser-based rendering can install `md-to-pdf` (which uses chromium under the hood) and the dispatch picks it up automatically.

### Chosen on axis 3 — **Always prompt, default-overridable via config**

The "would it follow the code?" question is **genuinely contextual** — same input file can land in two different places depending on who the PDF is for. An auto-pick based on path heuristics gets this wrong often enough that the cleanup cost dominates. The skill **asks**. Operators who always pick the same slot can set `default_destination` in config and pass `--no-prompt`.

The 4-option prompt:

```
(1) workspace/<name>/docs/<stem>.pdf  ← travels with the code
(2) projects/<name>/pdfs/<stem>.pdf   ← ApexYard's view
(3) <custom path>                     ← anywhere
(k) keep next to source               ← <input-dir>/<stem>.pdf
```

The hint text explicitly references the framework rule: *"Pick (1) if a downstream reader of the project repo would want this PDF (API spec, deployment runbook). Pick (2) if it's framework context (handover, stakeholder update, audit). Pick (k) when in doubt."*

## Consequences

### Positive

- **Adopters who never want PDFs pay zero install cost.** No pandoc dependency leaks into the framework's baseline. Same shape as the BPMN lint pipeline.
- **Graceful degrade is uniform** across `/c4` (Mermaid lint), `/process` (BPMN lint), and `/pdf` (converter dispatch). Adopters learn the pattern once.
- **Destination prompt mirrors the "would it follow the code?" rule** that already lives in `docs/multi-project.md` — no new mental model to learn.
- **Audit-class outputs need no special handling**: the dated stem (`2026-05-19`) already lives in the input filename, so `<stem>.pdf` = `2026-05-19.pdf` automatically.
- **Operators control the converter choice** via `--converter` flag or `pdf.preferred_converter` config — useful for CI where one converter is pinned for reproducibility.

### Negative

- **Two-step UX for routine shares**: operator runs `/c4 curios-dog`, then `/pdf projects/curios-dog/architecture/context.md`. We're betting that PDF emission is rare enough that the second step is acceptable; if adopters complain, the v1.5 per-skill `--pdf` flag is the answer.
- **BPMN → PDF pipeline is two stages** (bpmn-to-image → SVG → pandoc → PDF). When one stage fails, the error surface is less direct than a single binary call. Mitigated by streaming each tool's stderr through.
- **md-to-pdf via npx has cold-start latency** (~5s on first invocation as npx fetches the package). Adopters who use it often will want `npm install -g md-to-pdf` to skip the fetch.
- **No template/branding/custom-styling layer in v1** — the system pandoc defaults look "fine but not branded". Custom LaTeX templates are deferred to a separate ticket if demand surfaces.

### Migration / rollback

- **No data migration needed** — the skill is additive. No existing docs are touched.
- **Rollback** is `git revert` of the introducing PR; no state in `.claude/session/` is created.
- **Adopters with `default_destination: ask` and `--no-prompt` get an exit 2** with a clear message — by design, not regression.

## Artifacts

- PR: <to be filled at merge time>
- Issue: [me2resh/apexyard#284](https://github.com/me2resh/apexyard/issues/284)
- Skill: `.claude/skills/pdf/SKILL.md`
- Converter dispatch: `.claude/skills/pdf/convert.sh`
- Tests: `.claude/skills/pdf/tests/smoke.sh`
- Docs: `docs/multi-project.md` § "Architecture diagrams" → "PDF exports follow the same rule"
- Sibling patterns this AgDR reuses:
  - AgDR-0019 — dated audit subdirectory convention (filename rule)
  - AgDR-0023 — custom templates override semantics (the path-mirroring shape — similar discovery pattern but for templates rather than converters)
  - AgDR-0025 — `/process` graceful-degrade shape for `bpmnlint`
  - `.claude/skills/_lib-mermaid-lint.sh` — same shape, npx-fallback case
