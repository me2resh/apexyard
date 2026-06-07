#!/usr/bin/env python3
"""Lightweight markdown/doc extraction when no LLM API key is set.

Produces graphify-compatible nodes/edges from headings, inline code, and path
mentions so doc-aware graphs work offline. Not a replacement for full semantic
extraction — use GEMINI_API_KEY + graphify-bootstrap for richer graphs.
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

HEADING = re.compile(r"^(#{1,4})\s+(.+)$")
BACKTICK = re.compile(r"`([^`]{2,80})`")
PATHLIKE = re.compile(
    r"\b(?:src/|docs/|app/|lib/|scripts/|prompts/)[\w./-]+\.(?:ts|tsx|js|jsx|py|md|json)\b"
)
WORD_ID = re.compile(r"[^a-z0-9_]+")


def _slug(stem: str, label: str) -> str:
    s = WORD_ID.sub("_", f"{stem}_{label}".lower()).strip("_")
    return s[:120] or "doc_node"


def extract_docs(paths: list[str | Path], *, project_root: Path) -> dict:
    nodes: list[dict] = []
    edges: list[dict] = []
    seen_ids: set[str] = set()
    code_labels: set[str] = set()

    for p in paths:
        path = Path(p)
        if not path.is_file():
            continue
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        rel = str(path.resolve().relative_to(project_root.resolve()))
        stem = WORD_ID.sub("_", path.stem.lower())

        file_id = _slug(stem, path.stem)
        if file_id not in seen_ids:
            seen_ids.add(file_id)
            nodes.append(
                {
                    "id": file_id,
                    "label": path.name,
                    "file_type": "document",
                    "source_file": rel,
                    "source_location": None,
                }
            )

        last_section_id = file_id
        for i, line in enumerate(text.splitlines(), 1):
            hm = HEADING.match(line.strip())
            if hm:
                title = hm.group(2).strip()
                sid = _slug(stem, title)
                if sid not in seen_ids:
                    seen_ids.add(sid)
                    nodes.append(
                        {
                            "id": sid,
                            "label": title,
                            "file_type": "document",
                            "source_file": rel,
                            "source_location": f"L{i}",
                        }
                    )
                edges.append(
                    {
                        "source": last_section_id,
                        "target": sid,
                        "relation": "contains",
                        "confidence": "EXTRACTED",
                        "confidence_score": 1.0,
                        "source_file": rel,
                        "source_location": f"L{i}",
                        "weight": 1.0,
                    }
                )
                last_section_id = sid

            for sym in BACKTICK.findall(line):
                if sym.startswith("http") or "/" in sym and "." not in sym:
                    continue
                tid = _slug(stem, sym)
                if tid not in seen_ids:
                    seen_ids.add(tid)
                    nodes.append(
                        {
                            "id": tid,
                            "label": sym,
                            "file_type": "concept",
                            "source_file": rel,
                            "source_location": f"L{i}",
                        }
                    )
                code_labels.add(sym.lower())
                edges.append(
                    {
                        "source": last_section_id,
                        "target": tid,
                        "relation": "references",
                        "confidence": "EXTRACTED",
                        "confidence_score": 1.0,
                        "source_file": rel,
                        "source_location": f"L{i}",
                        "weight": 1.0,
                    }
                )

            for pl in PATHLIKE.findall(line):
                tid = _slug("path", pl.replace("/", "_"))
                if tid not in seen_ids:
                    seen_ids.add(tid)
                    nodes.append(
                        {
                            "id": tid,
                            "label": pl,
                            "file_type": "document",
                            "source_file": rel,
                            "source_location": f"L{i}",
                        }
                    )
                edges.append(
                    {
                        "source": last_section_id,
                        "target": tid,
                        "relation": "references",
                        "confidence": "EXTRACTED",
                        "confidence_score": 1.0,
                        "source_file": rel,
                        "source_location": f"L{i}",
                        "weight": 1.0,
                    }
                )

    return {
        "nodes": nodes,
        "edges": edges,
        "hyperedges": [],
        "input_tokens": 0,
        "output_tokens": 0,
        "_code_labels": sorted(code_labels),
    }


def main() -> None:
    root = Path(sys.argv[1]).resolve()
    out = Path(sys.argv[2])
    paths = [Path(p) for p in sys.argv[3:]]
    data = extract_docs(paths, project_root=root)
    out.write_text(json.dumps(data, indent=2, ensure_ascii=False), encoding="utf-8")
    print(f"doc-extract: {len(data['nodes'])} nodes, {len(data['edges'])} edges")


if __name__ == "__main__":
    main()
