#!/usr/bin/env python3
"""
Serialise a /threat-model structured-input file into OWASP Threat Dragon v2 JSON.

Input shape (YAML or JSON — see fixtures/sample-input.yaml for a worked example):

    title: "Example Project"
    description: "Threat model for the example project."
    owner: "Security Team"
    contributors:
      - "Alice"
      - "Bob"
    reviewer: "Carol"

    actors:
      - { id: user, name: "External user" }
    processes:
      - { id: web, name: "Web frontend" }
      - { id: api, name: "API service" }
    stores:
      - { id: db, name: "Primary data store" }

    boundaries:
      - { id: internet, name: "Public internet", children: [web] }
      - { id: backend,  name: "Backend network", children: [api, db] }

    flows:
      - { id: f1, source: user, target: web, label: "credentials, form input" }
      - { id: f2, source: web,  target: api, label: "auth token, user PII" }
      - { id: f3, source: api,  target: db,  label: "user PII, transaction" }

    threats:
      - parent: api
        type: "Spoofing"
        severity: "high"
        title: "No rate limit on /auth/login"
        description: "Attacker can brute-force login credentials."
        mitigation: "Add a rate limiter (5/min/IP) at the API gateway."
      - parent: db
        type: "Information disclosure"
        severity: "medium"
        title: "Stack traces in prod"
        description: "Server returns stack traces in 500 responses."
        mitigation: "Strip stack traces when NODE_ENV=production."

Threats may attach to actor / process / store / flow IDs via the `parent` field.

Output: OWASP Threat Dragon v2 JSON written to stdout (or to --out <path>).
Validates against `td.vue/src/assets/schema/threat-dragon-v2.schema.json` at
the structural level the schema's `required` lists enforce. See AgDR-0022 for
the format-choice rationale.

Usage:
    python3 serialize_dragon.py <input.yaml> [--out <path>]

Exit codes:
    0 — JSON written
    1 — input invalid (missing required field, dangling flow source/target, etc.)
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import uuid
from typing import Any, Dict, List, Optional, Tuple


# ---------------------------------------------------------------------------
# YAML loader — PyYAML if available, minimal subset parser otherwise.
# Same convention as .claude/skills/journey/tests/render_smoke.py — keeps the
# script runnable on minimal Python installs (no `pip install` required).
# ---------------------------------------------------------------------------


def load_input(path: str) -> Dict[str, Any]:
    text = _read_text(path)
    if path.endswith(".json"):
        return json.loads(text)
    try:
        import yaml  # type: ignore[import-not-found]

        return yaml.safe_load(text)
    except ImportError:
        return _minimal_yaml_parse(text)


def _read_text(path: str) -> str:
    with open(path, "r", encoding="utf-8") as fh:
        return fh.read()


def _minimal_yaml_parse(text: str) -> Dict[str, Any]:
    """
    Small YAML subset parser — handles the fixture shape:
      - top-level scalars (string / int)
      - block lists of maps (using inline `{ key: val, ... }` OR nested keys)
      - nested maps via indentation
      - quoted and unquoted scalars

    Not a general YAML parser. If PyYAML is available, the loader above uses
    it instead; this fallback exists to keep the script runnable on minimal
    Python installs (mirrors /journey's render_smoke.py approach).
    """
    lines = [ln.rstrip() for ln in text.splitlines()]
    pos = [0]

    def peek() -> Optional[str]:
        while pos[0] < len(lines):
            ln = lines[pos[0]]
            stripped = ln.strip()
            if not stripped or stripped.startswith("#"):
                pos[0] += 1
                continue
            return ln
        return None

    def consume() -> Optional[str]:
        ln = peek()
        if ln is not None:
            pos[0] += 1
        return ln

    def indent_of(ln: str) -> int:
        return len(ln) - len(ln.lstrip(" "))

    def parse_scalar(s: str) -> Any:
        s = s.strip()
        if not s:
            return ""
        if (s.startswith('"') and s.endswith('"')) or (
            s.startswith("'") and s.endswith("'")
        ):
            return s[1:-1]
        if s.lower() in ("true", "false"):
            return s.lower() == "true"
        if s.lower() in ("null", "~"):
            return None
        try:
            if "." in s:
                return float(s)
            return int(s)
        except ValueError:
            return s

    def parse_inline_value(v: str) -> Any:
        v = v.strip()
        if v.startswith("{") and v.endswith("}"):
            return parse_inline_map(v)
        if v.startswith("[") and v.endswith("]"):
            return parse_inline_list(v)
        return parse_scalar(v)

    def parse_inline_map(s: str) -> Dict[str, Any]:
        # `{ key: val, key2: "val2", key3: [a, b], ... }`
        s = s.strip()
        assert s.startswith("{") and s.endswith("}"), s
        inner = s[1:-1].strip()
        if not inner:
            return {}
        result: Dict[str, Any] = {}
        for pair in _split_top_level(inner, ","):
            if ":" not in pair:
                continue
            k, v = pair.split(":", 1)
            result[k.strip()] = parse_inline_value(v)
        return result

    def parse_inline_list(s: str) -> List[Any]:
        s = s.strip()
        assert s.startswith("[") and s.endswith("]"), s
        inner = s[1:-1].strip()
        if not inner:
            return []
        return [parse_inline_value(x) for x in _split_top_level(inner, ",")]

    def parse_map(min_indent: int) -> Dict[str, Any]:
        result: Dict[str, Any] = {}
        while True:
            ln = peek()
            if ln is None:
                break
            ind = indent_of(ln)
            if ind < min_indent:
                break
            if ind > min_indent:
                # shouldn't happen at this level
                break
            stripped = ln.strip()
            if stripped.startswith("- "):
                # we hit a list at this level — caller should have dispatched
                # via parse_list. Stop here.
                break
            if ":" not in stripped:
                consume()
                continue
            key, rest = stripped.split(":", 1)
            consume()
            rest = rest.strip()
            if rest == "":
                # nested map or list on the next line
                nxt = peek()
                if nxt is None:
                    result[key] = None
                    continue
                nxt_ind = indent_of(nxt)
                if nxt_ind <= min_indent:
                    result[key] = None
                    continue
                nxt_stripped = nxt.strip()
                if nxt_stripped.startswith("- "):
                    result[key] = parse_list(nxt_ind)
                else:
                    result[key] = parse_map(nxt_ind)
            elif rest.startswith("{") and rest.endswith("}"):
                result[key] = parse_inline_map(rest)
            elif rest.startswith("[") and rest.endswith("]"):
                result[key] = parse_inline_list(rest)
            else:
                result[key] = parse_scalar(rest)
        return result

    def parse_list(min_indent: int) -> List[Any]:
        items: List[Any] = []
        while True:
            ln = peek()
            if ln is None:
                break
            ind = indent_of(ln)
            if ind < min_indent:
                break
            stripped = ln.strip()
            if not stripped.startswith("- "):
                break
            consume()
            item_text = stripped[2:].strip()
            if item_text.startswith("{") and item_text.endswith("}"):
                items.append(parse_inline_map(item_text))
            elif ":" in item_text and not item_text.startswith('"'):
                # inline first key, then possibly nested keys at deeper indent
                key, rest = item_text.split(":", 1)
                first: Dict[str, Any] = {}
                rest = rest.strip()
                if rest.startswith("{") and rest.endswith("}"):
                    first[key] = parse_inline_map(rest)
                elif rest.startswith("[") and rest.endswith("]"):
                    first[key] = parse_inline_list(rest)
                elif rest:
                    first[key] = parse_scalar(rest)
                else:
                    first[key] = None
                # check for continuation keys at deeper indent
                nxt = peek()
                if nxt is not None and indent_of(nxt) > min_indent:
                    deeper = parse_map(indent_of(nxt))
                    first.update(deeper)
                items.append(first)
            else:
                items.append(parse_scalar(item_text))
        return items

    return parse_map(0)


def _split_top_level(s: str, sep: str) -> List[str]:
    out: List[str] = []
    depth = 0
    cur: List[str] = []
    in_str: Optional[str] = None
    for ch in s:
        if in_str:
            cur.append(ch)
            if ch == in_str:
                in_str = None
            continue
        if ch in ('"', "'"):
            in_str = ch
            cur.append(ch)
            continue
        if ch in "({[":
            depth += 1
            cur.append(ch)
            continue
        if ch in ")}]":
            depth -= 1
            cur.append(ch)
            continue
        if ch == sep and depth == 0:
            out.append("".join(cur))
            cur = []
            continue
        cur.append(ch)
    out.append("".join(cur))
    return [x.strip() for x in out if x.strip()]


# ---------------------------------------------------------------------------
# Threat Dragon v2 serialiser. See AgDR-0022 for the schema mapping rationale.
# ---------------------------------------------------------------------------

# Auto-grid layout constants. Dragon's auto-arrange re-flows on first open;
# these are sane starting positions only.
ACTOR_ROW_Y = 0
PROCESS_ROW_Y = 200
STORE_ROW_Y = 400
COL_X_START = 10
COL_X_STEP = 200
SHAPE_W = 160
SHAPE_H = 80
PROCESS_W = 100
PROCESS_H = 100
BOUNDARY_MARGIN = 40

# Dragon's threat-severity enum is High / Medium / Low. Map our lowercase
# severity vocabulary (critical/high/medium/low/info) into that bucket.
SEVERITY_MAP = {
    "critical": "High",
    "high": "High",
    "medium": "Medium",
    "low": "Low",
    "info": "Low",
}

# STRIDE type — match Dragon's canonical labels (verified against demo fixtures).
STRIDE_TYPES = {
    "spoofing": "Spoofing",
    "tampering": "Tampering",
    "repudiation": "Repudiation",
    "information disclosure": "Information disclosure",
    "info disclosure": "Information disclosure",
    "info disc": "Information disclosure",
    "denial of service": "Denial of service",
    "dos": "Denial of service",
    "elevation of privilege": "Elevation of privilege",
    "eop": "Elevation of privilege",
}

DRAGON_VERSION = "2.3.0"


def _norm_severity(sev: str) -> str:
    return SEVERITY_MAP.get((sev or "").strip().lower(), "Medium")


def _norm_stride_type(t: str) -> str:
    key = (t or "").strip().lower()
    return STRIDE_TYPES.get(key, t or "")


def _new_uuid() -> str:
    return str(uuid.uuid4())


def _grid_position(row_y: int, col: int) -> Dict[str, int]:
    return {"x": COL_X_START + col * COL_X_STEP, "y": row_y}


def _build_shape_cell(
    shape: str,
    name: str,
    position: Dict[str, int],
    size: Dict[str, int],
    data_type: str,
    z_index: int,
    threats: Optional[List[Dict[str, Any]]] = None,
    extra_data: Optional[Dict[str, Any]] = None,
) -> Dict[str, Any]:
    data: Dict[str, Any] = {
        "name": name,
        "description": "",
        "type": data_type,
        "isTrustBoundary": False,
        "outOfScope": False,
        "reasonOutOfScope": "",
        "hasOpenThreats": bool(threats),
        "threats": threats or [],
    }
    if extra_data:
        data.update(extra_data)
    return {
        "id": _new_uuid(),
        "shape": shape,
        "zIndex": z_index,
        "position": position,
        "size": size,
        "visible": True,
        "data": data,
    }


def _build_boundary_box(
    name: str, child_cells: List[Dict[str, Any]], z_index: int
) -> Optional[Dict[str, Any]]:
    if not child_cells:
        return None
    xs = [c["position"]["x"] for c in child_cells]
    ys = [c["position"]["y"] for c in child_cells]
    widths = [c["size"]["width"] for c in child_cells]
    heights = [c["size"]["height"] for c in child_cells]
    min_x = min(xs) - BOUNDARY_MARGIN
    min_y = min(ys) - BOUNDARY_MARGIN
    max_x = max(x + w for x, w in zip(xs, widths)) + BOUNDARY_MARGIN
    max_y = max(y + h for y, h in zip(ys, heights)) + BOUNDARY_MARGIN
    return {
        "id": _new_uuid(),
        "shape": "trust-boundary-box",
        "zIndex": z_index,
        "position": {"x": min_x, "y": min_y},
        "size": {"width": max_x - min_x, "height": max_y - min_y},
        "visible": True,
        "attrs": {"label": {"text": name}},
        "data": {
            "name": name,
            "description": "",
            "type": "tm.BoundaryBox",
            "isTrustBoundary": True,
            "hasOpenThreats": False,
        },
    }


def _build_flow_cell(
    source_uuid: str,
    target_uuid: str,
    label: str,
    threats: Optional[List[Dict[str, Any]]] = None,
) -> Dict[str, Any]:
    cell: Dict[str, Any] = {
        "id": _new_uuid(),
        "shape": "flow",
        "zIndex": 10,
        "source": {"cell": source_uuid},
        "target": {"cell": target_uuid},
        "attrs": {
            "line": {
                "stroke": "#333333",
                "strokeWidth": 1,
                "targetMarker": {"name": "block"},
                "strokeDasharray": None,
            }
        },
        "data": {
            "name": label or "",
            "description": "",
            "type": "tm.Flow",
            "isTrustBoundary": False,
            "isBidirectional": False,
            "isEncrypted": False,
            "isPublicNetwork": False,
            "protocol": "",
            "outOfScope": False,
            "reasonOutOfScope": "",
            "hasOpenThreats": bool(threats),
            "threats": threats or [],
        },
    }
    if label:
        cell["labels"] = [
            {
                "attrs": {
                    "labelText": {
                        "text": label,
                        "textAnchor": "middle",
                        "textVerticalAnchor": "middle",
                    }
                },
                "position": 0.5,
            }
        ]
    return cell


def _build_threat(t: Dict[str, Any]) -> Dict[str, Any]:
    return {
        "id": _new_uuid(),
        "title": t.get("title", "Unnamed threat"),
        "type": _norm_stride_type(t.get("type", "")),
        "description": t.get("description", ""),
        "mitigation": t.get("mitigation", ""),
        "severity": _norm_severity(t.get("severity", "medium")),
        "status": t.get("status", "Open"),
        "modelType": "STRIDE",
    }


def serialise(model: Dict[str, Any]) -> Tuple[Dict[str, Any], List[str]]:
    """Return (threat_dragon_v2_json, validation_errors)."""
    errors: List[str] = []

    title = (model.get("title") or "").strip() or "Untitled threat model"
    description = (model.get("description") or "").strip()
    owner = (model.get("owner") or "").strip()
    reviewer = (model.get("reviewer") or "").strip()
    contributors = model.get("contributors") or []

    # Resolve threats per entity id.
    threats_by_parent: Dict[str, List[Dict[str, Any]]] = {}
    for t in model.get("threats") or []:
        parent = t.get("parent")
        if not parent:
            errors.append(f"threat missing `parent`: {t.get('title', '<no title>')}")
            continue
        threats_by_parent.setdefault(parent, []).append(_build_threat(t))

    # Build shape cells; track input-id → cell-uuid for flow wiring.
    id_to_cell: Dict[str, Dict[str, Any]] = {}
    cells: List[Dict[str, Any]] = []

    actors = model.get("actors") or []
    for col, a in enumerate(actors):
        aid = a.get("id") or f"actor-{col}"
        cell = _build_shape_cell(
            shape="actor",
            name=a.get("name", aid),
            position=_grid_position(ACTOR_ROW_Y, col),
            size={"width": SHAPE_W, "height": SHAPE_H},
            data_type="tm.Actor",
            z_index=1,
            threats=threats_by_parent.pop(aid, []),
            extra_data={"providesAuthentication": False},
        )
        id_to_cell[aid] = cell
        cells.append(cell)

    processes = model.get("processes") or []
    for col, p in enumerate(processes):
        pid = p.get("id") or f"process-{col}"
        cell = _build_shape_cell(
            shape="process",
            name=p.get("name", pid),
            position=_grid_position(PROCESS_ROW_Y, col),
            size={"width": PROCESS_W, "height": PROCESS_H},
            data_type="tm.Process",
            z_index=2,
            threats=threats_by_parent.pop(pid, []),
            extra_data={
                "handlesCardPayment": False,
                "handlesGoodsOrServices": False,
                "isWebApplication": False,
                "privilegeLevel": "",
            },
        )
        id_to_cell[pid] = cell
        cells.append(cell)

    stores = model.get("stores") or []
    for col, s in enumerate(stores):
        sid = s.get("id") or f"store-{col}"
        cell = _build_shape_cell(
            shape="store",
            name=s.get("name", sid),
            position=_grid_position(STORE_ROW_Y, col),
            size={"width": SHAPE_W, "height": SHAPE_H},
            data_type="tm.Store",
            z_index=3,
            threats=threats_by_parent.pop(sid, []),
            extra_data={
                "isALog": False,
                "isEncrypted": False,
                "isSigned": False,
                "storesCredentials": False,
                "storesInventory": False,
            },
        )
        id_to_cell[sid] = cell
        cells.append(cell)

    # Boundary boxes wrap their children. z-index -1 so they render behind
    # the shapes (matches Dragon's three-tier demo convention).
    for b in model.get("boundaries") or []:
        bname = b.get("name") or b.get("id") or "Trust boundary"
        children = b.get("children") or []
        child_cells = [id_to_cell[c] for c in children if c in id_to_cell]
        if len(child_cells) != len(children):
            missing = [c for c in children if c not in id_to_cell]
            errors.append(
                f"boundary {bname!r} references unknown children: {missing}"
            )
            continue
        box = _build_boundary_box(bname, child_cells, z_index=-1)
        if box:
            cells.append(box)

    # Flows — must come last so the JSON cell ordering is shapes → boundaries → flows.
    for f in model.get("flows") or []:
        fid = f.get("id") or _new_uuid()
        source = f.get("source")
        target = f.get("target")
        if source not in id_to_cell:
            errors.append(f"flow {fid!r} has unknown source: {source!r}")
            continue
        if target not in id_to_cell:
            errors.append(f"flow {fid!r} has unknown target: {target!r}")
            continue
        flow_threats = threats_by_parent.pop(fid, [])
        flow_cell = _build_flow_cell(
            source_uuid=id_to_cell[source]["id"],
            target_uuid=id_to_cell[target]["id"],
            label=f.get("label", ""),
            threats=flow_threats,
        )
        # Preserve the input-id → cell-uuid mapping for flows too (in case a
        # threat targets a flow).
        id_to_cell[fid] = flow_cell
        cells.append(flow_cell)

    # Any threats whose parent didn't resolve to a known entity ID.
    for orphan_parent, orphans in threats_by_parent.items():
        errors.append(
            f"{len(orphans)} threat(s) reference unknown parent id: {orphan_parent!r}"
        )

    diagram = {
        "id": 0,
        "title": title,
        "diagramType": "STRIDE",
        "placeholder": "STRIDE diagram description",
        "thumbnail": "./public/content/images/thumbnail.stride.jpg",
        "version": DRAGON_VERSION,
        "description": description,
        "cells": cells,
    }

    # Highest threat number across all cells. Threat-Dragon expects monotone
    # `number` per-threat; since we use UUIDs as IDs, set threatTop to the
    # count of threats to satisfy the schema's required integer.
    threat_count = sum(len(c.get("data", {}).get("threats", [])) for c in cells)

    model_json: Dict[str, Any] = {
        "version": DRAGON_VERSION,
        "summary": {
            "title": title,
            "owner": owner,
            "description": description,
            "id": 0,
        },
        "detail": {
            "contributors": [{"name": c} for c in contributors],
            "diagrams": [diagram],
            "diagramTop": 1,
            "reviewer": reviewer,
            "threatTop": threat_count,
        },
    }
    return model_json, errors


def main() -> int:
    p = argparse.ArgumentParser(
        description="Serialise /threat-model input → OWASP Threat Dragon v2 JSON.",
    )
    p.add_argument("input", help="Path to YAML or JSON input file")
    p.add_argument(
        "--out",
        default=None,
        help="Output path (default: stdout)",
    )
    p.add_argument(
        "--strict",
        action="store_true",
        help="Exit 1 if any validation error is reported (default: warn).",
    )
    args = p.parse_args()

    if not os.path.exists(args.input):
        print(f"input not found: {args.input}", file=sys.stderr)
        return 1

    model = load_input(args.input)
    if not isinstance(model, dict):
        print("input did not parse to a mapping at the top level", file=sys.stderr)
        return 1

    output, errors = serialise(model)
    for err in errors:
        print(f"warning: {err}", file=sys.stderr)

    if args.strict and errors:
        return 1

    text = json.dumps(output, indent=2)
    if args.out:
        with open(args.out, "w", encoding="utf-8") as fh:
            fh.write(text)
            fh.write("\n")
    else:
        print(text)

    return 0


if __name__ == "__main__":
    sys.exit(main())
