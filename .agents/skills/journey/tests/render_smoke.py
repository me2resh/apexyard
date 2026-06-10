#!/usr/bin/env python3
"""
Smoke-test renderer for /journey.

Reads a YAML journey fixture, lays out the boxes-and-arrows graph using the
algorithm documented in SKILL.md (BFS-by-row vertical flowchart), and emits a
single self-contained HTML file with all CSS + JS inline. This script exists to
prove the rendering algorithm works on a small fixture (3 pages, 2 transitions)
before the skill runs on real input.

Usage:
    python3 render_smoke.py <path/to/fixture.yaml> <path/to/output.html>

If no args are provided, defaults to:
    fixtures/sample-checkout.yaml -> /tmp/sample-checkout.html

The script is intentionally dependency-free except for PyYAML, which ships with
most Python distributions but is also imported lazily so the script can fall
back to a tiny YAML subset parser if PyYAML is absent.
"""

from __future__ import annotations

import collections
import html
import os
import sys
from typing import Any, Dict, List, Optional, Tuple

# ---------------------------------------------------------------------------
# YAML loader (PyYAML if available, else a minimal subset parser sufficient for
# the smoke-test fixture).
# ---------------------------------------------------------------------------


def load_yaml(path: str) -> Dict[str, Any]:
    try:
        import yaml  # type: ignore[import-not-found]

        with open(path, "r", encoding="utf-8") as fh:
            return yaml.safe_load(fh)
    except ImportError:
        with open(path, "r", encoding="utf-8") as fh:
            return _minimal_yaml_parse(fh.read())


def _minimal_yaml_parse(text: str) -> Dict[str, Any]:
    """
    Very small YAML subset parser — handles only what the journey fixtures need:
    top-level scalars, single-line scalars, simple block lists, nested maps via
    indentation, and `|` block scalars. Sufficient for the smoke-test fixture.

    Not a general YAML parser. If PyYAML is available, the loader uses it
    instead; this fallback exists only to keep the smoke test runnable on
    minimal Python installs.
    """
    lines = text.splitlines()
    pos = 0

    def parse_block(indent: int) -> Any:
        nonlocal pos
        # Decide list vs map by looking at the first non-blank line at this indent.
        while pos < len(lines):
            ln = lines[pos]
            stripped = ln.strip()
            if stripped == "" or stripped.startswith("#"):
                pos += 1
                continue
            cur_indent = len(ln) - len(ln.lstrip(" "))
            if cur_indent < indent:
                return None
            if stripped.startswith("- "):
                return parse_list(indent)
            return parse_map(indent)
        return None

    def parse_list(indent: int) -> List[Any]:
        nonlocal pos
        out: List[Any] = []
        while pos < len(lines):
            ln = lines[pos]
            stripped = ln.strip()
            if stripped == "" or stripped.startswith("#"):
                pos += 1
                continue
            cur_indent = len(ln) - len(ln.lstrip(" "))
            if cur_indent < indent or not stripped.startswith("- "):
                return out
            # Consume the "- " prefix and treat the remainder + following nested
            # lines as a map item.
            after_dash = ln[cur_indent + 2 :]
            first_line_indent = cur_indent + 2
            # If the line after "- " is "key: value", start a map.
            item: Any
            if ":" in after_dash and not after_dash.startswith("|"):
                key, _, value = after_dash.partition(":")
                key = key.strip()
                value = value.strip()
                pos += 1
                item = {}
                if value:
                    item[key] = _scalar(value)
                else:
                    # Nested block (list or map) under this key.
                    nested = parse_block(first_line_indent + 2)
                    item[key] = nested if nested is not None else {}
                # Continue collecting sibling keys at first_line_indent.
                while pos < len(lines):
                    ln2 = lines[pos]
                    s2 = ln2.strip()
                    if s2 == "" or s2.startswith("#"):
                        pos += 1
                        continue
                    i2 = len(ln2) - len(ln2.lstrip(" "))
                    if i2 < first_line_indent or s2.startswith("- "):
                        break
                    if i2 == first_line_indent and ":" in s2:
                        k2, _, v2 = s2.partition(":")
                        k2 = k2.strip()
                        v2 = v2.strip()
                        pos += 1
                        if v2 == "|":
                            item[k2] = _consume_block_scalar(first_line_indent + 2)
                        elif v2:
                            item[k2] = _scalar(v2)
                        else:
                            nested = parse_block(first_line_indent + 2)
                            item[k2] = nested if nested is not None else []
                    else:
                        break
                out.append(item)
            else:
                pos += 1
                out.append(_scalar(after_dash.strip()))
        return out

    def parse_map(indent: int) -> Dict[str, Any]:
        nonlocal pos
        out: Dict[str, Any] = {}
        while pos < len(lines):
            ln = lines[pos]
            stripped = ln.strip()
            if stripped == "" or stripped.startswith("#"):
                pos += 1
                continue
            cur_indent = len(ln) - len(ln.lstrip(" "))
            if cur_indent < indent:
                return out
            if stripped.startswith("- "):
                return out
            if ":" not in stripped:
                pos += 1
                continue
            key, _, value = stripped.partition(":")
            key = key.strip()
            value = value.strip()
            pos += 1
            if value == "|":
                out[key] = _consume_block_scalar(indent + 2)
            elif value == "":
                nested = parse_block(indent + 2)
                out[key] = nested if nested is not None else []
            else:
                out[key] = _scalar(value)
        return out

    def _consume_block_scalar(indent: int) -> str:
        nonlocal pos
        collected: List[str] = []
        while pos < len(lines):
            ln = lines[pos]
            if ln.strip() == "":
                collected.append("")
                pos += 1
                continue
            cur_indent = len(ln) - len(ln.lstrip(" "))
            if cur_indent < indent:
                break
            collected.append(ln[indent:])
            pos += 1
        return "\n".join(collected).rstrip() + "\n"

    def _scalar(s: str) -> Any:
        if s == "" or s == "[]":
            return []
        if (s.startswith('"') and s.endswith('"')) or (
            s.startswith("'") and s.endswith("'")
        ):
            return s[1:-1]
        return s

    return parse_block(0) or {}


# ---------------------------------------------------------------------------
# Layout: BFS-by-row vertical flowchart.
# ---------------------------------------------------------------------------

BOX_WIDTH = 220
BOX_HEIGHT = 80
ROW_SPACING = 140
COL_SPACING = 40
PADDING = 40


def layout(
    pages: List[Dict[str, Any]],
    transitions: List[Dict[str, Any]],
    entry: str,
) -> Tuple[Dict[str, Tuple[int, int]], int, int]:
    """
    Return (page_id -> (x, y)), canvas_width, canvas_height.

    BFS from entry, group pages by depth, distribute evenly within a row.
    Pages unreachable from entry are placed in a final row.
    """
    page_ids = [p["id"] for p in pages]
    adj: Dict[str, List[str]] = collections.defaultdict(list)
    for t in transitions:
        adj[t["from"]].append(t["to"])

    depth: Dict[str, int] = {}
    queue = collections.deque([(entry, 0)])
    while queue:
        node, d = queue.popleft()
        if node in depth:
            continue
        depth[node] = d
        for nxt in adj.get(node, []):
            if nxt not in depth:
                queue.append((nxt, d + 1))

    max_depth_assigned = max(depth.values(), default=0)
    for pid in page_ids:
        if pid not in depth:
            max_depth_assigned += 1
            depth[pid] = max_depth_assigned

    rows: Dict[int, List[str]] = collections.defaultdict(list)
    for pid in page_ids:
        rows[depth[pid]].append(pid)

    max_in_row = max((len(r) for r in rows.values()), default=1)
    canvas_width = max(
        BOX_WIDTH + 2 * PADDING,
        max_in_row * BOX_WIDTH + (max_in_row - 1) * COL_SPACING + 2 * PADDING,
    )
    num_rows = max(rows.keys()) + 1 if rows else 1
    canvas_height = (num_rows - 1) * ROW_SPACING + BOX_HEIGHT + 2 * PADDING

    positions: Dict[str, Tuple[int, int]] = {}
    for d in sorted(rows):
        row = rows[d]
        n = len(row)
        row_total_width = n * BOX_WIDTH + (n - 1) * COL_SPACING
        x_start = (canvas_width - row_total_width) // 2
        for i, pid in enumerate(row):
            x = x_start + i * (BOX_WIDTH + COL_SPACING)
            y = PADDING + d * ROW_SPACING
            positions[pid] = (x, y)

    return positions, canvas_width, canvas_height


# ---------------------------------------------------------------------------
# Render: single self-contained HTML.
# ---------------------------------------------------------------------------


CSS = """
* { box-sizing: border-box; }
body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif;
       margin: 0; color: #1f2937; background: #f9fafb; }
header { padding: 24px 32px; background: #fff; border-bottom: 1px solid #e5e7eb; }
header h1 { margin: 0 0 4px; font-size: 1.5rem; }
header .project { font-size: 0.85rem; color: #6b7280; text-transform: uppercase; letter-spacing: 0.04em; }
header .description { color: #4b5563; margin-top: 6px; }
header .disclaimer { display: inline-block; margin-top: 12px; padding: 4px 10px;
                     background: #fef3c7; color: #92400e; font-size: 0.8rem; border-radius: 4px; font-weight: 600; }
header .timestamp { font-size: 0.75rem; color: #9ca3af; margin-top: 8px; }
main { padding: 32px; }
section.graph { display: flex; justify-content: center; }
svg { max-width: 100%; height: auto; }
.page-box rect { fill: #fff; stroke: #6366f1; stroke-width: 2; cursor: pointer;
                 transition: fill 0.15s, stroke 0.15s; }
.page-box:hover rect, .page-box:focus rect { fill: #eef2ff; stroke: #4338ca; }
.page-box text { font-size: 14px; pointer-events: none; }
.page-title { font-weight: 600; }
.page-persona { font-size: 11px; fill: #6b7280; }
.transition-arrow { fill: none; stroke: #9ca3af; stroke-width: 1.5; }
.transition-label { font-size: 11px; fill: #4b5563; pointer-events: none; }
.modal[hidden] { display: none; }
.modal { position: fixed; inset: 0; z-index: 1000; }
.modal-backdrop { position: absolute; inset: 0; background: rgba(17, 24, 39, 0.5); }
.modal-content { position: relative; max-width: 640px; margin: 5vh auto; max-height: 90vh;
                 overflow-y: auto; background: #fff; border-radius: 8px; padding: 24px;
                 box-shadow: 0 10px 25px rgba(0, 0, 0, 0.2); }
.modal-content header { display: flex; align-items: center; gap: 12px; padding: 0 0 16px;
                        border-bottom: 1px solid #e5e7eb; background: transparent; }
.modal-content header h2 { margin: 0; font-size: 1.25rem; flex: 1; }
.modal-close { background: none; border: 0; font-size: 1.5rem; cursor: pointer; color: #6b7280; }
.modal-close:hover { color: #1f2937; }
.modal-content section { margin-top: 16px; }
.modal-content h3 { font-size: 0.9rem; text-transform: uppercase; letter-spacing: 0.05em;
                    color: #6b7280; margin: 0 0 8px; }
.modal-content ul { padding-left: 20px; margin: 0; }
.persona-pill { display: inline-block; padding: 2px 8px; font-size: 0.75rem;
                background: #eef2ff; color: #4338ca; border-radius: 999px; }
footer { padding: 24px 32px; font-size: 0.8rem; color: #6b7280;
         border-top: 1px solid #e5e7eb; background: #fff; }
footer code { background: #f3f4f6; padding: 2px 6px; border-radius: 3px; font-size: 0.85em; }
""".strip()


JS = """
(function () {
  var pages = document.querySelectorAll('.page-box');
  var modals = document.querySelectorAll('.modal');

  function openModal(id) {
    var m = document.getElementById('modal-' + id);
    if (!m) return;
    m.hidden = false;
    document.body.style.overflow = 'hidden';
    var closeBtn = m.querySelector('.modal-close');
    if (closeBtn) closeBtn.focus();
  }

  function closeModal(id) {
    var m = document.getElementById('modal-' + id);
    if (!m) return;
    m.hidden = true;
    document.body.style.overflow = '';
    var trigger = document.getElementById('page-' + id);
    if (trigger) trigger.focus();
  }

  pages.forEach(function (p) {
    var id = p.dataset.pageId;
    p.addEventListener('click', function () { openModal(id); });
    p.addEventListener('keydown', function (e) {
      if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); openModal(id); }
    });
  });

  document.querySelectorAll('[data-close-modal]').forEach(function (el) {
    el.addEventListener('click', function () { closeModal(el.dataset.closeModal); });
  });

  document.addEventListener('keydown', function (e) {
    if (e.key === 'Escape') {
      modals.forEach(function (m) {
        if (!m.hidden) closeModal(m.id.replace(/^modal-/, ''));
      });
    }
  });
})();
""".strip()


def render(journey: Dict[str, Any]) -> str:
    pages: List[Dict[str, Any]] = journey.get("pages", []) or []
    transitions: List[Dict[str, Any]] = journey.get("transitions", []) or []
    entry: str = journey.get("entry") or (pages[0]["id"] if pages else "")
    title: str = journey.get("title", journey.get("feature", "User Journey"))
    project: str = journey.get("project", "")
    description: str = journey.get("description", "")
    generated_at: str = journey.get("generated_at", "")
    feature_slug: str = journey.get("feature", "")

    if not pages or not entry:
        raise ValueError("journey must have at least one page and an entry")

    positions, canvas_w, canvas_h = layout(pages, transitions, entry)

    # SVG boxes.
    box_svg: List[str] = []
    for p in pages:
        pid = p["id"]
        x, y = positions[pid]
        cx = x + BOX_WIDTH // 2
        cy = y + BOX_HEIGHT // 2
        persona = p.get("persona") or ""
        persona_attr = f' data-persona="{html.escape(persona)}"' if persona else ""
        title_text = html.escape(p.get("title", pid))
        persona_tspan = (
            f'<tspan class="page-persona" x="{cx}" dy="18">{html.escape(persona)}</tspan>'
            if persona
            else ""
        )
        box_svg.append(
            f'<g class="page-box" id="page-{html.escape(pid)}" data-page-id="{html.escape(pid)}"{persona_attr} '
            f'tabindex="0" role="button" aria-label="Open details for {title_text}">'
            f'<rect x="{x}" y="{y}" width="{BOX_WIDTH}" height="{BOX_HEIGHT}" rx="8"/>'
            f'<text x="{cx}" y="{cy}" text-anchor="middle" dominant-baseline="middle">'
            f'<tspan class="page-title" x="{cx}">{title_text}</tspan>'
            f"{persona_tspan}"
            f"</text></g>"
        )

    # SVG arrows.
    arrow_svg: List[str] = []
    for t in transitions:
        f_id = t["from"]
        t_id = t["to"]
        if f_id not in positions or t_id not in positions:
            continue
        fx, fy = positions[f_id]
        tx, ty = positions[t_id]
        # Connect bottom-center of from-box to top-center of to-box.
        x1 = fx + BOX_WIDTH // 2
        y1 = fy + BOX_HEIGHT
        x2 = tx + BOX_WIDTH // 2
        y2 = ty
        # Cubic curve with vertical control points.
        cy1 = y1 + (y2 - y1) // 2
        cy2 = y2 - (y2 - y1) // 2
        if y2 <= y1:
            # Back-edge: curve to the side.
            mid_x = (x1 + x2) // 2 + 200
            d = f"M{x1},{y1} C{mid_x},{y1} {mid_x},{y2} {x2},{y2}"
        else:
            d = f"M{x1},{y1} C{x1},{cy1} {x2},{cy2} {x2},{y2}"
        trigger = html.escape(t.get("trigger", ""))
        label_x = (x1 + x2) // 2
        label_y = (y1 + y2) // 2
        arrow_svg.append(
            f'<path class="transition-arrow" d="{d}" marker-end="url(#arrowhead)"/>'
        )
        if trigger:
            arrow_svg.append(
                f'<text class="transition-label" x="{label_x}" y="{label_y}" text-anchor="middle">{trigger}</text>'
            )

    # Modals.
    incoming: Dict[str, List[Dict[str, Any]]] = collections.defaultdict(list)
    outgoing: Dict[str, List[Dict[str, Any]]] = collections.defaultdict(list)
    title_by_id = {p["id"]: p.get("title", p["id"]) for p in pages}
    for t in transitions:
        outgoing[t["from"]].append(t)
        incoming[t["to"]].append(t)

    modals_html: List[str] = []
    for p in pages:
        pid = p["id"]
        title_text = html.escape(p.get("title", pid))
        persona = p.get("persona") or ""
        persona_pill = (
            f'<span class="persona-pill">{html.escape(persona)}</span>' if persona else ""
        )
        contents = p.get("contents") or []
        contents_html = (
            "<ul>"
            + "".join(f"<li>{html.escape(str(c))}</li>" for c in contents)
            + "</ul>"
            if contents
            else "<p><em>No page contents specified.</em></p>"
        )
        success_html = (
            f"<section><h3>Success state</h3><p>{html.escape(p['success_state'])}</p></section>"
            if p.get("success_state")
            else ""
        )
        error_html = (
            f"<section><h3>Error / edge state</h3><p>{html.escape(p['error_state'])}</p></section>"
            if p.get("error_state")
            else ""
        )
        in_lis = "".join(
            f"<li>from <strong>{html.escape(title_by_id.get(t['from'], t['from']))}</strong> on {html.escape(t.get('trigger', ''))}</li>"
            for t in incoming.get(pid, [])
        ) or "<li><em>None — entry page or unreachable.</em></li>"
        out_lis = "".join(
            f"<li>to <strong>{html.escape(title_by_id.get(t['to'], t['to']))}</strong> on {html.escape(t.get('trigger', ''))}</li>"
            for t in outgoing.get(pid, [])
        ) or "<li><em>None — terminal page.</em></li>"
        image_html = (
            f'<section><h3>Reference image</h3><img src="{html.escape(p["image"])}" alt="" style="max-width:100%"></section>'
            if p.get("image")
            else ""
        )
        wireframe_html = (
            f'<section><h3>Wireframe (sketch)</h3><div class="wireframe-sandbox" style="border:1px dashed #d1d5db;padding:12px;background:#fafafa;">{p["wireframe_html"]}</div></section>'
            if p.get("wireframe_html")
            else ""
        )

        modals_html.append(
            f'<div class="modal" id="modal-{html.escape(pid)}" role="dialog" aria-modal="true" aria-labelledby="modal-title-{html.escape(pid)}" hidden>'
            f'<div class="modal-backdrop" data-close-modal="{html.escape(pid)}"></div>'
            f'<div class="modal-content">'
            f"<header>"
            f'<h2 id="modal-title-{html.escape(pid)}">{title_text}</h2>'
            f"{persona_pill}"
            f'<button class="modal-close" data-close-modal="{html.escape(pid)}" aria-label="Close">&times;</button>'
            f"</header>"
            f'<section class="modal-description"><p>{html.escape(p.get("description", ""))}</p></section>'
            f'<section class="modal-contents"><h3>Page contents</h3>{contents_html}</section>'
            f"{success_html}{error_html}"
            f'<section class="modal-transitions-in"><h3>Transitions in</h3><ul>{in_lis}</ul></section>'
            f'<section class="modal-transitions-out"><h3>Transitions out</h3><ul>{out_lis}</ul></section>'
            f"{image_html}{wireframe_html}"
            f"</div></div>"
        )

    yaml_path_hint = f"projects/{project}/journeys/{feature_slug}.yaml" if project and feature_slug else "projects/<name>/journeys/<feature-slug>.yaml"

    html_doc = f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{html.escape(title)} — User Journey</title>
  <style>{CSS}</style>
</head>
<body>
  <header>
    <div class="meta">
      <div class="project">{html.escape(project)}</div>
      <h1>{html.escape(title)}</h1>
      <div class="description">{html.escape(description)}</div>
      <div class="disclaimer">DRAFT — preview before implementation. Not a production deliverable.</div>
      <div class="timestamp">Generated {html.escape(generated_at)}</div>
    </div>
  </header>
  <main>
    <section class="graph">
      <svg viewBox="0 0 {canvas_w} {canvas_h}" role="img" aria-label="User journey graph">
        <defs>
          <marker id="arrowhead" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="8" markerHeight="8" orient="auto">
            <path d="M0,0 L10,5 L0,10 z" fill="#9ca3af"/>
          </marker>
        </defs>
        {''.join(arrow_svg)}
        {''.join(box_svg)}
      </svg>
    </section>
    {''.join(modals_html)}
  </main>
  <footer>
    <div>Source: <code>{html.escape(yaml_path_hint)}</code></div>
    <div>Regenerate: <code>/journey {html.escape(feature_slug)} --update</code></div>
  </footer>
  <script>{JS}</script>
</body>
</html>
"""
    return html_doc


# ---------------------------------------------------------------------------
# Smoke-test entry point.
# ---------------------------------------------------------------------------


def main() -> int:
    if len(sys.argv) >= 3:
        in_path = sys.argv[1]
        out_path = sys.argv[2]
    else:
        here = os.path.dirname(os.path.abspath(__file__))
        in_path = os.path.join(here, "..", "fixtures", "sample-checkout.yaml")
        out_path = "/tmp/sample-checkout.html"

    journey = load_yaml(in_path)
    if not isinstance(journey, dict):
        print(f"FAIL: {in_path} did not parse to a mapping (got {type(journey)})")
        return 1

    pages = journey.get("pages") or []
    transitions = journey.get("transitions") or []
    entry = journey.get("entry")

    # Validate.
    if not pages:
        print("FAIL: no pages")
        return 1
    if not entry:
        print("FAIL: no entry")
        return 1
    page_ids = {p["id"] for p in pages}
    if entry not in page_ids:
        print(f"FAIL: entry '{entry}' not in pages {sorted(page_ids)}")
        return 1
    for t in transitions:
        if t.get("from") not in page_ids:
            print(f"FAIL: transition.from '{t.get('from')}' not a page id")
            return 1
        if t.get("to") not in page_ids:
            print(f"FAIL: transition.to '{t.get('to')}' not a page id")
            return 1
    if len(pages) > 12:
        print(f"FAIL: too many pages ({len(pages)} > 12)")
        return 1
    if len(transitions) > 30:
        print(f"FAIL: too many transitions ({len(transitions)} > 30)")
        return 1

    # Render.
    html_doc = render(journey)
    with open(out_path, "w", encoding="utf-8") as fh:
        fh.write(html_doc)

    # Self-check assertions on the output.
    failures: List[str] = []
    if "<!DOCTYPE html>" not in html_doc:
        failures.append("missing doctype")
    if "src=" in html_doc and 'src=""' not in html_doc:
        # No external script/style/etc references (image src is allowed if a
        # page sets an image; the smoke fixture sets no image so this should
        # never trip on the canonical fixture).
        if any(
            f'{tag} src="' in html_doc and "//" in html_doc.split(f'{tag} src="', 1)[1][:200]
            for tag in ("script", "link", "iframe")
        ):
            failures.append("found external src reference (expected single self-contained file)")
    if "<style>" not in html_doc or "<script>" not in html_doc:
        failures.append("expected inline <style> and <script>")
    for p in pages:
        pid = p["id"]
        if f'id="modal-{pid}"' not in html_doc:
            failures.append(f"missing modal for page '{pid}'")
        if f'id="page-{pid}"' not in html_doc:
            failures.append(f"missing box for page '{pid}'")
    for t in transitions:
        # Trigger text should appear at least once in the document (in a
        # transition label or in a modal's transitions-in/out section).
        trig = t.get("trigger", "")
        if trig and html.escape(trig) not in html_doc:
            failures.append(f"transition trigger '{trig}' not rendered")

    if failures:
        for f in failures:
            print(f"FAIL: {f}")
        return 1

    print(f"OK: rendered {len(pages)} pages, {len(transitions)} transitions to {out_path}")
    print(f"     canvas: {layout(pages, transitions, entry)[1]}x{layout(pages, transitions, entry)[2]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
