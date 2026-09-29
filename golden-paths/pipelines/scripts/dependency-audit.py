#!/usr/bin/env python3
# Shared dependency audit helper for npm and Python (AgDR-0176 / issue #1359).
# Adopters copy this file beside the workflow as .github/scripts/dependency-audit.py.
# Inventory collection is data-only for Python. Never run Poetry, uv, Pipenv,
# build backends, or checkout plugins.
"""Dependency audit: discover ecosystems, scan, normalise, report."""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Dict, Iterable, List, Optional, Sequence, Set, Tuple

HELPER_REVISION = "1"
HELPER_ID = "apexyard-dependency-audit"

REQUIRED_PIP_AUDIT = "2.10.0"
REQUIRED_PACKAGING = "25.0"
# cvss==3.6 declares LGPLv3+. Restricted-licence approval is pending (AgDR-0176).
# Until approved, vector-only severity stays Unknown unless another label exists.
CVSS_APPROVED = False

OSV_QUERYBATCH = "https://api.osv.dev/v1/querybatch"
OSV_VULN = "https://api.osv.dev/v1/vulns/{id}"
PYPI_JSON = "https://pypi.org/pypi/{name}/{version}/json"
PYPI_PROJECT = "https://pypi.org/pypi/{name}/json"

HTTP_TIMEOUT_SEC = 30
HTTP_RETRIES = 2
HTTP_RETRY_DELAYS = (1, 2)
OSV_BATCH_SIZE = 100
SUBPROCESS_TIMEOUT_SEC = 300
OVERALL_DEADLINE_SEC = 20 * 60

SKIP_DIR_NAMES = {
    "node_modules",
    ".venv",
    "venv",
    "vendor",
    "dist",
    "build",
    ".next",
    "__pycache__",
    ".git",
    ".tox",
    ".mypy_cache",
    ".pytest_cache",
}

NPM_MANIFEST = "package.json"
PYTHON_MANIFEST_NAMES = {
    "pyproject.toml",
    "Pipfile",
    "Pipfile.lock",
    "poetry.lock",
    "uv.lock",
}
REQUIREMENTS_RE = re.compile(r"^requirements.*\.txt$", re.IGNORECASE)
EXACT_PIN_RE = re.compile(
    r"^\s*([A-Za-z0-9][A-Za-z0-9._-]*)\s*==\s*([^\s\\;]+)"
)
REQ_INCLUDE_RE = re.compile(r"^\s*-r\s+(\S+)")
ENV_MARKER_RE = re.compile(r";\s*(.+)$")

ALLOWED_LICENCES = frozenset(
    {
        "MIT",
        "Apache-2.0",
        "BSD-2-Clause",
        "BSD-3-Clause",
        "ISC",
        "CC0-1.0",
        "0BSD",
        "Unlicense",
    }
)

# Current SPDX identifiers for restricted copyleft (AgDR-0176 / SPDX 3.29.0).
RESTRICTED_LICENCES = frozenset(
    {
        "GPL-2.0-only",
        "GPL-2.0-or-later",
        "GPL-3.0-only",
        "GPL-3.0-or-later",
        "LGPL-2.0-only",
        "LGPL-2.0-or-later",
        "LGPL-2.1-only",
        "LGPL-2.1-or-later",
        "LGPL-3.0-only",
        "LGPL-3.0-or-later",
        "AGPL-3.0-only",
        "AGPL-3.0-or-later",
        "MPL-2.0",
        "CDDL-1.0",
        "CDDL-1.1",
    }
)

# Explicit no-grant / proprietary claims. Unknown metadata is pending review,
# not banned (AgDR-0176).
BANNED_LICENCES = frozenset({"UNLICENSED", "Proprietary"})

SEVERITY_RANK = {
    "Critical": 5,
    "High": 4,
    "Medium": 3,
    "Low": 2,
    "Unknown": 1,
}

NPM_SEVERITY_MAP = {
    "critical": "Critical",
    "high": "High",
    "moderate": "Medium",
    "low": "Low",
}

OSV_LABEL_MAP = {
    "CRITICAL": "Critical",
    "HIGH": "High",
    "MODERATE": "Medium",
    "MEDIUM": "Medium",
    "LOW": "Low",
}


@dataclass
class PackagePin:
    name: str
    version: str
    ecosystem: str
    manifest: str
    extras: Tuple[str, ...] = ()
    source: str = "pin"


@dataclass
class Finding:
    ecosystem: str
    package: str
    version: str
    advisory_id: str
    severity: str
    severity_reason: str
    manifests: List[str] = field(default_factory=list)
    aliases: List[str] = field(default_factory=list)
    raw: Dict[str, Any] = field(default_factory=dict)


@dataclass
class LicenceFinding:
    ecosystem: str
    package: str
    version: str
    licence: str
    disposition: str  # allowed | restricted | banned | pending_review
    source: str
    manifest: str


@dataclass
class OutdatedFinding:
    ecosystem: str
    package: str
    current: str
    latest: str
    kind: str
    manifest: str


@dataclass
class DependencySet:
    directory: str
    ecosystem: str
    manifests: List[str]
    pins: List[PackagePin] = field(default_factory=list)
    coverage: str = "complete"  # complete | incomplete | failed | excluded | not_applicable
    coverage_reason: str = ""
    runner: str = ""
    check_status: str = "pending"


@dataclass
class AuditReport:
    project: str
    started_at: str
    helper_revision: str
    ecosystems: List[str]
    dependency_sets: List[DependencySet]
    findings: List[Finding]
    licences: List[LicenceFinding]
    outdated: List[OutdatedFinding]
    tool_versions: Dict[str, str]
    excluded_ecosystems: List[str] = field(default_factory=list)
    notes: List[str] = field(default_factory=list)

    def severity_totals(self) -> Dict[str, int]:
        totals = {k: 0 for k in ("Critical", "High", "Medium", "Low", "Unknown")}
        seen: Set[Tuple[str, str, str, str]] = set()
        for f in self.findings:
            key = (f.ecosystem, f.package.lower(), f.version, f.advisory_id)
            if key in seen:
                continue
            seen.add(key)
            totals[f.severity] = totals.get(f.severity, 0) + 1
        return totals


class Deadline:
    def __init__(self, seconds: float = OVERALL_DEADLINE_SEC) -> None:
        self.deadline = time.monotonic() + seconds

    def remaining(self) -> float:
        return max(0.0, self.deadline - time.monotonic())

    def expired(self) -> bool:
        return self.remaining() <= 0


def _now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def walk_project_files(root: Path) -> Iterable[Path]:
    root = root.resolve()
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIR_NAMES]
        for name in filenames:
            yield Path(dirpath) / name


def detect_manifests(root: Path) -> Dict[str, List[Path]]:
    """Return ecosystem -> manifest paths under root."""
    found: Dict[str, List[Path]] = {"npm": [], "python": []}
    for path in walk_project_files(root):
        name = path.name
        if name == NPM_MANIFEST:
            found["npm"].append(path)
        elif name in PYTHON_MANIFEST_NAMES or REQUIREMENTS_RE.match(name):
            found["python"].append(path)
    for eco in found:
        found[eco].sort(key=lambda p: str(p))
    return found


def group_dependency_sets(root: Path, manifests: Dict[str, List[Path]]) -> List[DependencySet]:
    """Group related manifests by project directory per ecosystem."""
    sets: List[DependencySet] = []
    root = root.resolve()

    npm_by_dir: Dict[Path, List[Path]] = {}
    for path in manifests.get("npm", []):
        npm_by_dir.setdefault(path.parent, []).append(path)
    for directory, paths in sorted(npm_by_dir.items(), key=lambda x: str(x[0])):
        rel_dir = _rel(root, directory)
        sets.append(
            DependencySet(
                directory=rel_dir,
                ecosystem="npm",
                manifests=[_rel(root, p) for p in paths],
                runner="npm",
            )
        )

    py_by_dir: Dict[Path, List[Path]] = {}
    for path in manifests.get("python", []):
        py_by_dir.setdefault(path.parent, []).append(path)
    for directory, paths in sorted(py_by_dir.items(), key=lambda x: str(x[0])):
        rel_dir = _rel(root, directory)
        names = {p.name for p in paths}
        rels = [_rel(root, p) for p in paths]
        # Tooling-only pyproject with no dependency groups.
        if names == {"pyproject.toml"} and _pyproject_tooling_only(directory / "pyproject.toml"):
            sets.append(
                DependencySet(
                    directory=rel_dir,
                    ecosystem="python",
                    manifests=rels,
                    coverage="not_applicable",
                    coverage_reason="tooling-only pyproject.toml with no declared dependency groups",
                    runner="pip-audit",
                    check_status="not_applicable",
                )
            )
            continue
        sets.append(
            DependencySet(
                directory=rel_dir,
                ecosystem="python",
                manifests=rels,
                runner="pip-audit",
            )
        )
    return sets


def _rel(root: Path, path: Path) -> str:
    try:
        return str(path.resolve().relative_to(root.resolve()))
    except ValueError:
        return str(path)


def _pyproject_tooling_only(path: Path) -> bool:
    text = path.read_text(encoding="utf-8", errors="replace")
    # Data-only TOML scan without executing the file.
    has_deps = bool(
        re.search(
            r"(?m)^\s*(dependencies|optional-dependencies|dev-dependencies)\s*=",
            text,
        )
    )
    has_poetry = "[tool.poetry.dependencies]" in text or "[tool.poetry.group" in text
    has_project = "[project]" in text and "dependencies" in text
    return not (has_deps or has_poetry or has_project)


# ---------------------------------------------------------------------------
# Python inventory (data-only)
# ---------------------------------------------------------------------------


def collect_python_inventory(root: Path, dep_set: DependencySet) -> None:
    directory = (root / dep_set.directory).resolve() if dep_set.directory != "." else root.resolve()
    lock_order = ("poetry.lock", "uv.lock", "Pipfile.lock")
    for lock_name in lock_order:
        lock_path = directory / lock_name
        if lock_path.is_file():
            pins, incomplete, reason = parse_python_lock(lock_path, _rel(root, lock_path))
            dep_set.pins = pins
            if incomplete:
                dep_set.coverage = "incomplete"
                dep_set.coverage_reason = reason
            else:
                dep_set.coverage = "complete"
                dep_set.coverage_reason = f"resolved from {lock_name}"
            return

    req_files = sorted(
        [directory / m.name for m in (directory.iterdir() if directory.is_dir() else []) if REQUIREMENTS_RE.match(m.name)],
        key=lambda p: p.name,
    )
    # Also honour manifests listed on the dependency set (nested paths).
    for rel in dep_set.manifests:
        p = root / rel
        if REQUIREMENTS_RE.match(p.name) and p.is_file() and p not in req_files:
            req_files.append(p)

    if req_files:
        pins: List[PackagePin] = []
        incomplete = False
        reasons: List[str] = []
        for req in req_files:
            part, part_incomplete, part_reason = parse_requirements_file(root, req)
            pins.extend(part)
            if part_incomplete:
                incomplete = True
                reasons.append(part_reason)
        dep_set.pins = _dedupe_pins(pins)
        if not dep_set.pins:
            dep_set.coverage = "incomplete"
            dep_set.coverage_reason = "requirements file contains no exact pins"
        elif incomplete:
            dep_set.coverage = "incomplete"
            dep_set.coverage_reason = " | ".join(reasons)
        else:
            dep_set.coverage = "complete"
            dep_set.coverage_reason = "exact pins from requirements (declared packages only)"
        return

    pyproject = directory / "pyproject.toml"
    if pyproject.is_file():
        pins, incomplete, reason = parse_pyproject_static(pyproject, _rel(root, pyproject))
        dep_set.pins = pins
        dep_set.coverage = "incomplete" if incomplete or not pins else "complete"
        dep_set.coverage_reason = reason
        if not pins and incomplete:
            dep_set.coverage = "incomplete"
        return

    pipfile = directory / "Pipfile"
    if pipfile.is_file():
        dep_set.coverage = "incomplete"
        dep_set.coverage_reason = "Pipfile without Pipfile.lock cannot establish resolved versions"
        return

    dep_set.coverage = "incomplete"
    dep_set.coverage_reason = "no supported Python lock or pinned requirements found"


def _dedupe_pins(pins: Sequence[PackagePin]) -> List[PackagePin]:
    seen: Set[Tuple[str, str, str]] = set()
    out: List[PackagePin] = []
    for p in pins:
        key = (p.name.lower(), p.version, p.manifest)
        if key in seen:
            continue
        seen.add(key)
        out.append(p)
    return out


def parse_requirements_file(
    root: Path, path: Path, seen: Optional[Set[Path]] = None
) -> Tuple[List[PackagePin], bool, str]:
    if seen is None:
        seen = set()
    path = path.resolve()
    if path in seen:
        return [], True, f"circular requirements include at {path}"
    seen.add(path)
    try:
        path.relative_to(root.resolve())
    except ValueError:
        return [], True, f"requirements include escapes project root: {path}"

    pins: List[PackagePin] = []
    incomplete = False
    reasons: List[str] = []
    text = path.read_text(encoding="utf-8", errors="replace")
    rel = _rel(root, path)
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        include = REQ_INCLUDE_RE.match(line)
        if include:
            target = (path.parent / include.group(1)).resolve()
            try:
                target.relative_to(root.resolve())
            except ValueError:
                incomplete = True
                reasons.append(f"include outside project root: {include.group(1)}")
                continue
            if not target.is_file():
                incomplete = True
                reasons.append(f"missing include: {include.group(1)}")
                continue
            nested, nest_inc, nest_reason = parse_requirements_file(root, target, seen)
            pins.extend(nested)
            if nest_inc:
                incomplete = True
                reasons.append(nest_reason)
            continue
        if line.startswith("-"):
            # Other pip options (index-url, editable, etc.).
            if "--index-url" in line or "-i " in line or "git+" in line or line.startswith("-e "):
                incomplete = True
                reasons.append(f"unsupported or private requirement line in {rel}")
            continue
        marker = None
        marker_m = ENV_MARKER_RE.search(line)
        if marker_m:
            marker = marker_m.group(1).strip()
            line = line[: marker_m.start()].strip()
        if marker and not evaluate_marker(marker):
            continue
        if "@" in line or "git+" in line or line.startswith("http"):
            incomplete = True
            reasons.append(f"VCS or URL dependency in {rel}")
            continue
        pin_m = EXACT_PIN_RE.match(line)
        if not pin_m:
            incomplete = True
            reasons.append(f"unpinned or non-exact requirement in {rel}: {line.split()[0]}")
            continue
        name, version = pin_m.group(1), pin_m.group(2).strip()
        extras: Tuple[str, ...] = ()
        if "[" in name and name.endswith("]"):
            base, rest = name.split("[", 1)
            name = base
            extras = tuple(x.strip() for x in rest[:-1].split(",") if x.strip())
        pins.append(
            PackagePin(
                name=name,
                version=version,
                ecosystem="PyPI",
                manifest=rel,
                extras=extras,
                source="requirements",
            )
        )
    reason = " | ".join(reasons) if reasons else ""
    return pins, incomplete, reason


def evaluate_marker(marker: str) -> bool:
    """Evaluate an environment marker. Prefer packaging==25.0 when available."""
    packaging = _load_packaging()
    if packaging is None:
        # Conservative: keep the pin when markers cannot be evaluated.
        return True
    try:
        return bool(packaging.markers.Marker(marker).evaluate())
    except Exception:
        return True


def _load_packaging() -> Any:
    try:
        import packaging  # type: ignore
        import packaging.markers  # type: ignore
        import packaging.version  # type: ignore

        ver = getattr(packaging, "__version__", "")
        if ver != REQUIRED_PACKAGING:
            # Record mismatch elsewhere. Still usable for markers in local runs,
            # but trusted CI must pin 25.0.
            pass
        return packaging
    except Exception:
        return None


def parse_python_lock(path: Path, rel: str) -> Tuple[List[PackagePin], bool, str]:
    name = path.name
    text = path.read_text(encoding="utf-8", errors="replace")
    if name == "Pipfile.lock":
        return _parse_pipfile_lock(text, rel)
    if name == "poetry.lock":
        return _parse_poetry_lock(text, rel)
    if name == "uv.lock":
        return _parse_uv_lock(text, rel)
    return [], True, f"unsupported lock file: {rel}"


def _parse_pipfile_lock(text: str, rel: str) -> Tuple[List[PackagePin], bool, str]:
    try:
        data = json.loads(text)
    except json.JSONDecodeError:
        return [], True, f"malformed Pipfile.lock: {rel}"
    meta = data.get("_meta", {})
    # Pipfile.lock has no single schema version field in all eras. Treat missing
    # default packages as incomplete.
    pins: List[PackagePin] = []
    for section in ("default", "develop"):
        packages = data.get(section) or {}
        if not isinstance(packages, dict):
            continue
        for pkg, meta_pkg in packages.items():
            if not isinstance(meta_pkg, dict):
                continue
            version = str(meta_pkg.get("version", "")).lstrip("=")
            if not version:
                continue
            if meta_pkg.get("index") and meta_pkg.get("index") not in ("pypi", "PyPI", None):
                return pins, True, f"private-index dependency in {rel}"
            pins.append(
                PackagePin(
                    name=pkg,
                    version=version,
                    ecosystem="PyPI",
                    manifest=rel,
                    source="Pipfile.lock",
                )
            )
    if not pins and not data.get("default"):
        return [], True, f"empty or unsupported Pipfile.lock: {rel}"
    _ = meta  # keep for future schema checks
    return pins, False, ""


def _parse_poetry_lock(text: str, rel: str) -> Tuple[List[PackagePin], bool, str]:
    # Validate known metadata version without executing Poetry.
    meta_ver = None
    m = re.search(r"(?m)^\[metadata\]\s*$([\s\S]*?)(?=^\[|\Z)", text)
    if m:
        vm = re.search(r'(?m)^lock-version\s*=\s*"([^"]+)"', m.group(1))
        if vm:
            meta_ver = vm.group(1)
        else:
            vm = re.search(r'(?m)^metadata_content_hash', m.group(1))
            # Older poetry.lock files use metadata without lock-version.
            if not vm:
                pass
    # Poetry 1.x/2.x lock-version values we accept.
    if meta_ver is not None and meta_ver.split(".")[0] not in ("1", "2"):
        return [], True, f"unsupported poetry.lock schema version {meta_ver} in {rel}"

    pins: List[PackagePin] = []
    for block in re.finditer(r"(?m)^\[\[package\]\]\s*$([\s\S]*?)(?=^\[\[|\Z)", text):
        body = block.group(1)
        nm = re.search(r'(?m)^name\s*=\s*"([^"]+)"', body)
        vm = re.search(r'(?m)^version\s*=\s*"([^"]+)"', body)
        if not nm or not vm:
            continue
        src = re.search(r'(?m)^source\s*=\s*"([^"]+)"', body)
        if src and src.group(1) not in ("pypi", "PyPI", ""):
            return pins, True, f"non-PyPI source in poetry.lock: {rel}"
        pins.append(
            PackagePin(
                name=nm.group(1),
                version=vm.group(1),
                ecosystem="PyPI",
                manifest=rel,
                source="poetry.lock",
            )
        )
    if not pins:
        return [], True, f"no packages parsed from poetry.lock: {rel}"
    return pins, False, ""


def _parse_uv_lock(text: str, rel: str) -> Tuple[List[PackagePin], bool, str]:
    ver_m = re.search(r"(?m)^version\s*=\s*(\d+)", text)
    if ver_m and int(ver_m.group(1)) > 1:
        # uv.lock version 1 is the current documented schema.
        return [], True, f"unsupported uv.lock schema version {ver_m.group(1)} in {rel}"
    pins: List[PackagePin] = []
    for block in re.finditer(r"(?m)^\[\[package\]\]\s*$([\s\S]*?)(?=^\[\[|\Z)", text):
        body = block.group(1)
        nm = re.search(r'(?m)^name\s*=\s*"([^"]+)"', body)
        vm = re.search(r'(?m)^version\s*=\s*"([^"]+)"', body)
        if not nm or not vm:
            continue
        pins.append(
            PackagePin(
                name=nm.group(1),
                version=vm.group(1),
                ecosystem="PyPI",
                manifest=rel,
                source="uv.lock",
            )
        )
    if not pins:
        return [], True, f"no packages parsed from uv.lock: {rel}"
    return pins, False, ""


def parse_pyproject_static(path: Path, rel: str) -> Tuple[List[PackagePin], bool, str]:
    text = path.read_text(encoding="utf-8", errors="replace")
    if "dynamic" in text and re.search(r"dynamic\s*=\s*\[[^\]]*dependencies", text):
        return [], True, f"dynamic dependencies in {rel} without a lockfile"
    pins: List[PackagePin] = []
    # Only accept exact == pins inside a dependencies array. Ranges are incomplete.
    for m in re.finditer(r'"([A-Za-z0-9][A-Za-z0-9._-]*)\s*==\s*([^"]+)"', text):
        pins.append(
            PackagePin(
                name=m.group(1),
                version=m.group(2).strip(),
                ecosystem="PyPI",
                manifest=rel,
                source="pyproject.toml",
            )
        )
    if pins:
        return pins, False, "exact pins from pyproject.toml (declared packages only)"
    return [], True, f"pyproject.toml has no exact pins and no lockfile: {rel}"


# ---------------------------------------------------------------------------
# Severity normalisation
# ---------------------------------------------------------------------------


def map_npm_severity(raw: str) -> Tuple[str, str]:
    key = (raw or "").lower()
    if key in NPM_SEVERITY_MAP:
        return NPM_SEVERITY_MAP[key], f"npm:{key}"
    return "Unknown", f"unrecognised npm severity:{raw!r}"


def map_osv_severity(record: Dict[str, Any]) -> Tuple[str, str]:
    labels: List[Tuple[str, str]] = []
    scores: List[Tuple[float, str]] = []

    db = record.get("database_specific") or {}
    if isinstance(db, dict):
        sev = db.get("severity")
        if isinstance(sev, str):
            mapped = OSV_LABEL_MAP.get(sev.upper())
            if mapped:
                labels.append((mapped, f"database_specific.severity:{sev}"))
            else:
                labels.append(("Unknown", f"unrecognised OSV label:{sev}"))

    for item in record.get("severity") or []:
        if not isinstance(item, dict):
            continue
        if item.get("type") == "label" or "severity" in item and "score" not in item:
            raw = str(item.get("severity") or item.get("score") or "")
            mapped = OSV_LABEL_MAP.get(raw.upper())
            if mapped:
                labels.append((mapped, f"severity.label:{raw}"))
        score = item.get("score")
        if isinstance(score, (int, float)):
            scores.append((float(score), f"numeric_score:{score}"))
        vector = item.get("vector") or item.get("vector_string")
        if isinstance(vector, str) and vector:
            parsed = parse_cvss_vector(vector)
            if parsed is not None:
                scores.append((parsed, f"cvss_vector:{vector}"))
            else:
                labels.append(("Unknown", f"unparseable CVSS vector:{vector}"))

    # Prefer highest recognised label or score.
    best_label = None
    best_rank = 0
    reasons: List[str] = []
    for sev, reason in labels:
        reasons.append(reason)
        rank = SEVERITY_RANK.get(sev, 0)
        if rank > best_rank and sev != "Unknown":
            best_rank = rank
            best_label = sev
        elif best_label is None and sev == "Unknown":
            best_label = "Unknown"

    best_score_sev = None
    best_score_val = -1.0
    for score, reason in scores:
        reasons.append(reason)
        mapped = score_to_severity(score)
        if mapped == "Unknown":
            continue
        if score > best_score_val:
            best_score_val = score
            best_score_sev = mapped

    if best_label and best_score_sev:
        if SEVERITY_RANK[best_label] >= SEVERITY_RANK[best_score_sev]:
            return best_label, " | ".join(reasons)
        return best_score_sev, " | ".join(reasons) + " (score wins over label)"
    if best_label and best_label != "Unknown":
        return best_label, " | ".join(reasons) if reasons else "label"
    if best_score_sev:
        return best_score_sev, " | ".join(reasons)
    if not reasons:
        return "Unknown", "no severity evidence"
    return "Unknown", " | ".join(reasons)


def score_to_severity(score: float) -> str:
    if score >= 9.0:
        return "Critical"
    if score >= 7.0:
        return "High"
    if score >= 4.0:
        return "Medium"
    if score > 0.0:
        return "Low"
    return "Unknown"


def parse_cvss_vector(vector: str) -> Optional[float]:
    if not CVSS_APPROVED:
        # AgDR-0176: until cvss LGPLv3+ is approved, vector-only stays Unknown.
        return None
    try:
        import cvss  # type: ignore

        if vector.startswith("CVSS:4.0/"):
            return float(cvss.CVSS4(vector).scores()[0])
        if vector.startswith("CVSS:3.1/") or vector.startswith("CVSS:3.0/"):
            return float(cvss.CVSS3(vector).scores()[0])
        if vector.startswith("CVSS:2.0/") or vector.startswith("("):
            return float(cvss.CVSS2(vector).scores()[0])
    except Exception:
        return None
    return None


# ---------------------------------------------------------------------------
# Licence classification
# ---------------------------------------------------------------------------


def classify_licence(raw: Optional[str]) -> Tuple[str, str]:
    """Return (disposition, normalised_or_raw)."""
    if raw is None or str(raw).strip() == "" or str(raw).strip().upper() in {"UNKNOWN", "NONE"}:
        return "pending_review", "Unknown"
    text = str(raw).strip()
    # Compound expressions need manual review in this first pass.
    if any(op in text for op in (" AND ", " OR ", " WITH ", " and ", " or ", " with ")):
        return "pending_review", text
    if text in BANNED_LICENCES:
        return "banned", text
    if text in ALLOWED_LICENCES:
        return "allowed", text
    if text in RESTRICTED_LICENCES:
        return "restricted", text
    # Deprecated SPDX identifiers map to restricted review, not auto-allow.
    deprecated_map = {
        "GPL-2.0": "GPL-2.0-only",
        "GPL-3.0": "GPL-3.0-only",
        "LGPL-2.0": "LGPL-2.0-only",
        "LGPL-2.1": "LGPL-2.1-only",
        "LGPL-3.0": "LGPL-3.0-only",
        "AGPL-3.0": "AGPL-3.0-only",
    }
    if text in deprecated_map:
        return "restricted", deprecated_map[text]
    # Do not invent SPDX from classifiers via substring matching alone.
    return "pending_review", text


def extract_licence_from_pypi_meta(info: Dict[str, Any]) -> Tuple[str, str]:
    """Prefer License-Expression, then License, then License :: classifiers."""
    meta = info.get("info") if "info" in info else info
    if not isinstance(meta, dict):
        return "Unknown", "missing"
    expr = meta.get("license_expression") or meta.get("License-Expression")
    if expr:
        return str(expr), "license_expression"
    lic = meta.get("license") or meta.get("License")
    if lic and str(lic).strip():
        return str(lic).strip(), "license"
    for classifier in meta.get("classifiers") or []:
        if isinstance(classifier, str) and classifier.startswith("License ::"):
            # Keep the classifier text. Do not invent an SPDX id.
            return classifier, "classifier"
    return "Unknown", "missing"


# ---------------------------------------------------------------------------
# HTTP / scanner adapters (fixture-injectable for tests)
# ---------------------------------------------------------------------------


class HttpClient:
    def __init__(self, fixture_dir: Optional[Path] = None, deadline: Optional[Deadline] = None) -> None:
        self.fixture_dir = fixture_dir
        self.deadline = deadline or Deadline()

    def post_json(self, url: str, payload: Dict[str, Any]) -> Dict[str, Any]:
        if self.fixture_dir:
            return self._fixture_response("POST", url, payload)
        return self._live_request("POST", url, payload)

    def get_json(self, url: str) -> Dict[str, Any]:
        if self.fixture_dir:
            return self._fixture_response("GET", url, None)
        return self._live_request("GET", url, None)

    def _fixture_key(self, method: str, url: str, payload: Optional[Dict[str, Any]]) -> str:
        if "querybatch" in url:
            return "osv_querybatch.json"
        if "/vulns/" in url:
            vuln_id = url.rstrip("/").split("/")[-1]
            safe = re.sub(r"[^A-Za-z0-9._-]", "_", vuln_id)
            return f"osv_vuln_{safe}.json"
        if "pypi.org/pypi/" in url:
            parts = url.split("/pypi/")[-1].strip("/").split("/")
            if len(parts) >= 2 and parts[-1] == "json":
                # /pypi/{name}/{version}/json
                if len(parts) == 3:
                    return f"pypi_{parts[0]}_{parts[1]}.json"
                return f"pypi_{parts[0]}.json"
        return "http_default.json"

    def _fixture_response(
        self, method: str, url: str, payload: Optional[Dict[str, Any]]
    ) -> Dict[str, Any]:
        assert self.fixture_dir is not None
        name = self._fixture_key(method, url, payload)
        path = self.fixture_dir / name
        if not path.is_file() and name.endswith(".json"):
            alt = self.fixture_dir / (name[:-5] + ".fixture")
            if alt.is_file():
                path = alt
        if not path.is_file():
            # Allow a catch-all empty querybatch.
            if "querybatch" in url:
                queries = (payload or {}).get("queries") or []
                return {"results": [{"vulns": []} for _ in queries]}
            raise FileNotFoundError(f"missing HTTP fixture: {path}")
        return json.loads(path.read_text(encoding="utf-8"))

    def _live_request(
        self, method: str, url: str, payload: Optional[Dict[str, Any]]
    ) -> Dict[str, Any]:
        if self.deadline.expired():
            raise TimeoutError("overall audit deadline expired")
        body = None if payload is None else json.dumps(payload).encode("utf-8")
        headers = {"Content-Type": "application/json", "Accept": "application/json"}
        last_err: Optional[Exception] = None
        for attempt in range(HTTP_RETRIES + 1):
            if self.deadline.expired():
                raise TimeoutError("overall audit deadline expired")
            timeout = min(HTTP_TIMEOUT_SEC, self.deadline.remaining())
            req = urllib.request.Request(url, data=body, headers=headers, method=method)
            try:
                with urllib.request.urlopen(req, timeout=timeout) as resp:
                    raw = resp.read().decode("utf-8")
                    return json.loads(raw)
            except urllib.error.HTTPError as exc:
                last_err = exc
                if exc.code in (429, 500, 502, 503, 504) and attempt < HTTP_RETRIES:
                    time.sleep(HTTP_RETRY_DELAYS[min(attempt, len(HTTP_RETRY_DELAYS) - 1)])
                    continue
                raise
            except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
                last_err = exc
                if attempt < HTTP_RETRIES:
                    time.sleep(HTTP_RETRY_DELAYS[min(attempt, len(HTTP_RETRY_DELAYS) - 1)])
                    continue
                raise
        assert last_err is not None
        raise last_err


def run_pip_audit(
    pins: Sequence[PackagePin],
    trusted_python: str,
    deadline: Deadline,
    pip_audit_cmd: Optional[Sequence[str]] = None,
) -> Tuple[List[Dict[str, Any]], Optional[str]]:
    """Run trusted pip-audit on synthesized exact pins. Returns (vulns, error)."""
    if not pins:
        return [], None
    with tempfile.TemporaryDirectory(prefix="dep-audit-") as tmp:
        req_path = Path(tmp) / "pins.txt"
        req_path.write_text(
            "\n".join(f"{p.name}=={p.version}" for p in pins) + "\n",
            encoding="utf-8",
        )
        if pip_audit_cmd:
            cmd = list(pip_audit_cmd) + ["-r", str(req_path)]
        else:
            cmd = [
                trusted_python,
                "-I",
                "-m",
                "pip_audit",
                "-r",
                str(req_path),
                "--no-deps",
                "--disable-pip",
                "-s",
                "osv",
                "-f",
                "json",
                "--timeout",
                "30",
            ]
        try:
            proc = subprocess.run(
                cmd,
                cwd=tmp,
                capture_output=True,
                text=True,
                timeout=min(SUBPROCESS_TIMEOUT_SEC, max(1, int(deadline.remaining()))),
                env=_trusted_env(),
                check=False,
            )
        except FileNotFoundError:
            return [], "pip-audit not found"
        except subprocess.TimeoutExpired:
            return [], "pip-audit timed out"
        if proc.returncode not in (0, 1):
            # pip-audit uses 1 when vulns found. Other codes are failures.
            err = (proc.stderr or proc.stdout or "").strip() or f"exit {proc.returncode}"
            return [], f"pip-audit failed: {err}"
        try:
            data = json.loads(proc.stdout or "[]")
        except json.JSONDecodeError:
            return [], "pip-audit returned malformed JSON"
        if isinstance(data, dict) and "dependencies" in data:
            vulns = []
            for dep in data.get("dependencies") or []:
                for v in dep.get("vulns") or []:
                    vulns.append(
                        {
                            "name": dep.get("name"),
                            "version": dep.get("version"),
                            "id": v.get("id"),
                            "aliases": v.get("aliases") or [],
                        }
                    )
            return vulns, None
        if isinstance(data, list):
            return data, None
        return [], "unrecognised pip-audit JSON shape"


def _trusted_env() -> Dict[str, str]:
    env = {
        "PATH": os.environ.get("PATH", ""),
        "HOME": os.environ.get("HOME", tempfile.gettempdir()),
        "LANG": "C.UTF-8",
    }
    # Never inherit PYTHONPATH or scanner service overrides from the checkout.
    for key in ("PYTHONPATH", "PIP_AUDIT_SERVICE", "PIP_INDEX_URL", "PIP_EXTRA_INDEX_URL"):
        env.pop(key, None)
    return env


def query_osv_batch(
    pins: Sequence[PackagePin], http: HttpClient, deadline: Deadline
) -> Tuple[List[Dict[str, Any]], Optional[str]]:
    results: List[Dict[str, Any]] = []
    for i in range(0, len(pins), OSV_BATCH_SIZE):
        if deadline.expired():
            return results, "overall audit deadline expired during OSV querybatch"
        chunk = pins[i : i + OSV_BATCH_SIZE]
        payload = {
            "queries": [
                {
                    "package": {"name": p.name, "ecosystem": "PyPI"},
                    "version": p.version,
                }
                for p in chunk
            ]
        }
        try:
            data = http.post_json(OSV_QUERYBATCH, payload)
        except Exception as exc:  # noqa: BLE001 — surface as failed check
            return results, f"OSV querybatch failed: {exc}"
        batch_results = data.get("results") or []
        for pin, item in zip(chunk, batch_results):
            for vuln in item.get("vulns") or []:
                results.append(
                    {
                        "name": pin.name,
                        "version": pin.version,
                        "id": vuln.get("id"),
                        "aliases": vuln.get("aliases") or [],
                        "manifest": pin.manifest,
                    }
                )
            next_token = item.get("next_page_token")
            seen_tokens: Set[str] = set()
            while next_token:
                if next_token in seen_tokens:
                    return results, "repeated OSV pagination token"
                seen_tokens.add(next_token)
                if deadline.expired():
                    return results, "deadline during OSV pagination"
                page_payload = {
                    "queries": [
                        {
                            "package": {"name": pin.name, "ecosystem": "PyPI"},
                            "version": pin.version,
                            "page_token": next_token,
                        }
                    ]
                }
                try:
                    page = http.post_json(OSV_QUERYBATCH, page_payload)
                except Exception as exc:  # noqa: BLE001
                    return results, f"OSV pagination failed: {exc}"
                page_item = (page.get("results") or [{}])[0]
                for vuln in page_item.get("vulns") or []:
                    results.append(
                        {
                            "name": pin.name,
                            "version": pin.version,
                            "id": vuln.get("id"),
                            "aliases": vuln.get("aliases") or [],
                            "manifest": pin.manifest,
                        }
                    )
                next_token = page_item.get("next_page_token")
    return results, None


def enrich_osv_records(
    vuln_hits: Sequence[Dict[str, Any]], http: HttpClient, deadline: Deadline
) -> Tuple[List[Finding], Optional[str]]:
    findings: List[Finding] = []
    enrich_error: Optional[str] = None
    for hit in vuln_hits:
        vuln_id = hit.get("id")
        if not vuln_id:
            continue
        record: Dict[str, Any] = {}
        try:
            if deadline.expired():
                raise TimeoutError("deadline during OSV enrichment")
            record = http.get_json(OSV_VULN.format(id=vuln_id))
            severity, reason = map_osv_severity(record)
        except Exception as exc:  # noqa: BLE001
            enrich_error = f"OSV enrichment failed: {exc}"
            severity, reason = "Unknown", f"failed enrichment: {exc}"
            record = {"id": vuln_id}
        aliases = list(hit.get("aliases") or []) + list(record.get("aliases") or [])
        # Also fetch alias records when present for severity enrichment.
        for alias in list(aliases):
            if not alias or alias == vuln_id:
                continue
            try:
                alias_rec = http.get_json(OSV_VULN.format(id=alias))
                a_sev, a_reason = map_osv_severity(alias_rec)
                if SEVERITY_RANK.get(a_sev, 0) > SEVERITY_RANK.get(severity, 0):
                    severity, reason = a_sev, a_reason + f" (via alias {alias})"
                aliases.extend(alias_rec.get("aliases") or [])
            except Exception:
                continue
        findings.append(
            Finding(
                ecosystem="python",
                package=str(hit.get("name")),
                version=str(hit.get("version")),
                advisory_id=str(vuln_id),
                severity=severity,
                severity_reason=reason,
                manifests=[hit["manifest"]] if hit.get("manifest") else [],
                aliases=sorted(set(aliases)),
                raw=record,
            )
        )
    return dedupe_findings(findings), enrich_error


def dedupe_findings(findings: Sequence[Finding]) -> List[Finding]:
    """Merge alias-connected advisories for the same ecosystem package version."""
    merged: List[Finding] = []
    for f in findings:
        found = None
        f_ids = {f.advisory_id, *f.aliases}
        for existing in merged:
            if (
                existing.ecosystem != f.ecosystem
                or existing.package.lower() != f.package.lower()
                or existing.version != f.version
            ):
                continue
            e_ids = {existing.advisory_id, *existing.aliases}
            if f_ids & e_ids:
                found = existing
                break
        if found is None:
            merged.append(f)
            continue
        if SEVERITY_RANK.get(f.severity, 0) > SEVERITY_RANK.get(found.severity, 0):
            found.severity = f.severity
            found.severity_reason = f.severity_reason
        for path in f.manifests:
            if path not in found.manifests:
                found.manifests.append(path)
        found.aliases = sorted((set(found.aliases) | f_ids) - {found.advisory_id})
    return merged


# ---------------------------------------------------------------------------
# npm runners
# ---------------------------------------------------------------------------


def run_npm_audit(
    directory: Path, deadline: Deadline, npm_cmd: Optional[Sequence[str]] = None
) -> Tuple[List[Finding], Optional[str]]:
    cmd = list(npm_cmd) if npm_cmd else ["npm", "audit", "--json"]
    try:
        proc = subprocess.run(
            cmd,
            cwd=str(directory),
            capture_output=True,
            text=True,
            timeout=min(SUBPROCESS_TIMEOUT_SEC, max(1, int(deadline.remaining()))),
            check=False,
        )
    except FileNotFoundError:
        return [], "npm not found"
    except subprocess.TimeoutExpired:
        return [], "npm audit timed out"
    raw = proc.stdout or ""
    try:
        data = json.loads(raw) if raw.strip() else {}
    except json.JSONDecodeError:
        return [], "npm audit returned malformed JSON"
    findings: List[Finding] = []
    vulns = data.get("vulnerabilities") or {}
    if isinstance(vulns, dict):
        for name, meta in vulns.items():
            if not isinstance(meta, dict):
                continue
            sev, reason = map_npm_severity(str(meta.get("severity") or ""))
            via = meta.get("via") or []
            adv_id = name
            if isinstance(via, list) and via:
                first = via[0]
                if isinstance(first, dict) and first.get("source"):
                    adv_id = str(first.get("url") or first.get("source"))
                elif isinstance(first, str):
                    adv_id = first
            findings.append(
                Finding(
                    ecosystem="npm",
                    package=name,
                    version=str(meta.get("range") or meta.get("version") or ""),
                    advisory_id=adv_id,
                    severity=sev,
                    severity_reason=reason,
                    manifests=["package.json"],
                    raw=meta,
                )
            )
    return findings, None


def remediation_command(ecosystem: str, package: str) -> str:
    if ecosystem == "npm":
        return f"npm update {package}"
    if ecosystem == "python":
        return (
            f"Update {package} through the project's Python lockfile workflow "
            f"(pip / poetry / uv / pipenv). Do not run npm update."
        )
    return f"Update {package} with the ecosystem package manager"


# ---------------------------------------------------------------------------
# Licence + outdated (Python)
# ---------------------------------------------------------------------------


def python_licence_and_outdated(
    pins: Sequence[PackagePin],
    http: HttpClient,
    deadline: Deadline,
) -> Tuple[List[LicenceFinding], List[OutdatedFinding], Optional[str]]:
    licences: List[LicenceFinding] = []
    outdated: List[OutdatedFinding] = []
    err: Optional[str] = None
    packaging = _load_packaging()
    for pin in pins:
        if deadline.expired():
            err = "deadline during PyPI metadata"
            break
        try:
            meta = http.get_json(PYPI_JSON.format(name=pin.name, version=pin.version))
        except Exception as exc:  # noqa: BLE001
            err = f"PyPI metadata failed for {pin.name}=={pin.version}: {exc}"
            licences.append(
                LicenceFinding(
                    ecosystem="python",
                    package=pin.name,
                    version=pin.version,
                    licence="Unknown",
                    disposition="pending_review",
                    source="metadata_failed",
                    manifest=pin.manifest,
                )
            )
            continue
        raw_lic, src = extract_licence_from_pypi_meta(meta)
        disposition, normalised = classify_licence(raw_lic)
        licences.append(
            LicenceFinding(
                ecosystem="python",
                package=pin.name,
                version=pin.version,
                licence=normalised,
                disposition=disposition,
                source=src,
                manifest=pin.manifest,
            )
        )
        try:
            project = http.get_json(PYPI_PROJECT.format(name=pin.name))
            latest = ((project.get("info") or {}).get("version")) or ""
            if latest and latest != pin.version:
                kind = "unknown"
                if packaging is not None:
                    try:
                        cur = packaging.version.Version(pin.version)
                        lat = packaging.version.Version(latest)
                        if lat.major != cur.major:
                            kind = "major"
                        elif lat.minor != cur.minor:
                            kind = "minor"
                        else:
                            kind = "patch"
                    except Exception:
                        kind = "unknown"
                outdated.append(
                    OutdatedFinding(
                        ecosystem="python",
                        package=pin.name,
                        current=pin.version,
                        latest=latest,
                        kind=kind,
                        manifest=pin.manifest,
                    )
                )
        except Exception as exc:  # noqa: BLE001
            err = f"PyPI project lookup failed for {pin.name}: {exc}"
    return licences, outdated, err


# ---------------------------------------------------------------------------
# Report rendering + exit codes
# ---------------------------------------------------------------------------


def choose_exit_code(report: AuditReport) -> int:
    totals = report.severity_totals()
    if totals.get("Critical", 0) > 0:
        return 1
    selected = [
        ds
        for ds in report.dependency_sets
        if ds.coverage not in ("excluded", "not_applicable")
    ]
    for ds in selected:
        if ds.coverage in ("incomplete", "failed") or ds.check_status == "failed":
            return 3
    if totals.get("Unknown", 0) > 0:
        return 4
    return 0


def report_to_dict(report: AuditReport) -> Dict[str, Any]:
    return {
        "project": report.project,
        "started_at": report.started_at,
        "helper_id": HELPER_ID,
        "helper_revision": report.helper_revision,
        "ecosystems": report.ecosystems,
        "excluded_ecosystems": report.excluded_ecosystems,
        "tool_versions": report.tool_versions,
        "severity_totals": report.severity_totals(),
        "notes": report.notes,
        "dependency_sets": [
            {
                "directory": ds.directory,
                "ecosystem": ds.ecosystem,
                "manifests": ds.manifests,
                "runner": ds.runner,
                "coverage": ds.coverage,
                "coverage_reason": ds.coverage_reason,
                "check_status": ds.check_status,
                "package_count": len(ds.pins),
                "packages": [
                    {"name": p.name, "version": p.version, "manifest": p.manifest}
                    for p in ds.pins
                ],
            }
            for ds in report.dependency_sets
        ],
        "findings": [
            {
                "ecosystem": f.ecosystem,
                "package": f.package,
                "version": f.version,
                "advisory_id": f.advisory_id,
                "severity": f.severity,
                "severity_reason": f.severity_reason,
                "manifests": f.manifests,
                "aliases": f.aliases,
                "remediation": remediation_command(f.ecosystem, f.package),
            }
            for f in report.findings
        ],
        "licences": [
            {
                "ecosystem": lic.ecosystem,
                "package": lic.package,
                "version": lic.version,
                "licence": lic.licence,
                "disposition": lic.disposition,
                "source": lic.source,
                "manifest": lic.manifest,
            }
            for lic in report.licences
        ],
        "outdated": [
            {
                "ecosystem": o.ecosystem,
                "package": o.package,
                "current": o.current,
                "latest": o.latest,
                "kind": o.kind,
                "manifest": o.manifest,
            }
            for o in report.outdated
        ],
        "exit_code_meaning": {
            "0": "Complete selected checks, no Critical or Unknown vulnerability findings",
            "1": "Known Critical vulnerability findings",
            "2": "Invalid arguments or incompatible runner override",
            "3": "Missing selected tool, failed check, or incomplete selected coverage",
            "4": "Complete selected coverage with Unknown vulnerability findings",
        },
    }


def render_markdown(report: AuditReport) -> str:
    totals = report.severity_totals()
    lines = [
        f"# Dependency audit report — {report.project}",
        "",
        f"| Field | Value |",
        f"|-------|-------|",
        f"| Date | {report.started_at} |",
        f"| Helper | {HELPER_ID} revision {report.helper_revision} |",
        f"| Ecosystems | {', '.join(report.ecosystems) or '(none)'} |",
        f"| Tools | {json.dumps(report.tool_versions)} |",
        "",
        "## Vulnerability summary",
        "",
        "| Severity | Count |",
        "|----------|-------|",
        f"| Critical | {totals.get('Critical', 0)} |",
        f"| High | {totals.get('High', 0)} |",
        f"| Medium | {totals.get('Medium', 0)} |",
        f"| Low | {totals.get('Low', 0)} |",
        f"| Unknown | {totals.get('Unknown', 0)} |",
        "",
    ]
    for eco in report.ecosystems:
        lines.append(f"## Ecosystem: {eco}")
        lines.append("")
        for ds in report.dependency_sets:
            if ds.ecosystem != eco:
                continue
            lines.append(f"### `{ds.directory}`")
            lines.append("")
            lines.append(f"- Manifests: {', '.join(f'`{m}`' for m in ds.manifests)}")
            lines.append(f"- Runner: `{ds.runner}`")
            lines.append(f"- Coverage: **{ds.coverage}** — {ds.coverage_reason or ds.check_status}")
            lines.append("")
    if report.findings:
        lines.append("## Findings")
        lines.append("")
        for f in report.findings:
            lines.append(
                f"- **{f.severity}** `{f.package}@{f.version}` ({f.ecosystem}) "
                f"— {f.advisory_id}. Fix: {remediation_command(f.ecosystem, f.package)}"
            )
        lines.append("")
    if report.licences:
        lines.append("## Licences")
        lines.append("")
        lines.append("| Package | Licence | Disposition |")
        lines.append("|---------|---------|-------------|")
        for lic in report.licences:
            lines.append(
                f"| {lic.package}@{lic.version} | {lic.licence} | {lic.disposition} |"
            )
        lines.append("")
    if report.notes:
        lines.append("## Notes")
        lines.append("")
        for note in report.notes:
            lines.append(f"- {note}")
        lines.append("")
    return "\n".join(lines) + "\n"


# ---------------------------------------------------------------------------
# CLI orchestration
# ---------------------------------------------------------------------------


def parse_args(argv: Optional[Sequence[str]] = None) -> argparse.Namespace:
    p = argparse.ArgumentParser(description="ApexYard dependency audit helper (AgDR-0176)")
    p.add_argument("project", nargs="?", default=".", help="Project root to audit")
    p.add_argument("--ecosystem", choices=("npm", "python"), action="append", default=None)
    p.add_argument("--language", choices=("js", "ts", "python"), action="append", default=None)
    p.add_argument("--runner", choices=("npm", "pip-audit", "osv"), default=None)
    p.add_argument("--json-out", default=None, help="Write machine-readable JSON report")
    p.add_argument("--md-out", default=None, help="Write markdown report")
    p.add_argument(
        "--fixture-http",
        default=os.environ.get("DEPENDENCY_AUDIT_HTTP_FIXTURE_DIR"),
        help="Directory of stub HTTP responses (tests, no network)",
    )
    p.add_argument(
        "--trusted-python",
        default=os.environ.get("DEPENDENCY_AUDIT_TRUSTED_PYTHON", sys.executable),
        help="Trusted interpreter for pip-audit (-I)",
    )
    p.add_argument(
        "--skip-npm-scan",
        action="store_true",
        help="Discover npm but skip invoking npm (tests)",
    )
    p.add_argument(
        "--skip-python-scan",
        action="store_true",
        help="Collect Python inventory but skip advisory queries (tests)",
    )
    p.add_argument(
        "--pip-audit-stub",
        default=os.environ.get("DEPENDENCY_AUDIT_PIP_AUDIT_STUB"),
        help="Path to JSON stub used instead of pip-audit",
    )
    return p.parse_args(argv)


def language_to_ecosystem(lang: str) -> str:
    if lang in ("js", "ts"):
        return "npm"
    if lang == "python":
        return "python"
    raise ValueError(lang)


def resolve_ecosystem_filter(args: argparse.Namespace) -> Tuple[Optional[Set[str]], Optional[str]]:
    eco: Set[str] = set()
    if args.ecosystem:
        eco.update(args.ecosystem)
    if args.language:
        for lang in args.language:
            eco.add(language_to_ecosystem(lang))
    if args.ecosystem and args.language:
        from_lang = {language_to_ecosystem(l) for l in args.language}
        from_eco = set(args.ecosystem)
        if from_lang != from_eco:
            return None, "conflicting --ecosystem and --language filters"
    if args.runner == "npm" and eco and "npm" not in eco:
        return None, "--runner=npm requires npm ecosystem"
    if args.runner in ("pip-audit", "osv") and eco and "python" not in eco:
        return None, f"--runner={args.runner} requires python ecosystem"
    return (eco or None), None


def run_audit(args: argparse.Namespace) -> Tuple[AuditReport, int]:
    root = Path(args.project).resolve()
    if not root.is_dir():
        print(f"dependency-audit: project path not found: {root}", file=sys.stderr)
        return (
            AuditReport(
                project=str(root),
                started_at=_now_iso(),
                helper_revision=HELPER_REVISION,
                ecosystems=[],
                dependency_sets=[],
                findings=[],
                licences=[],
                outdated=[],
                tool_versions={},
            ),
            2,
        )

    eco_filter, err = resolve_ecosystem_filter(args)
    if err:
        print(f"dependency-audit: {err}", file=sys.stderr)
        return (
            AuditReport(
                project=str(root),
                started_at=_now_iso(),
                helper_revision=HELPER_REVISION,
                ecosystems=[],
                dependency_sets=[],
                findings=[],
                licences=[],
                outdated=[],
                tool_versions={},
                notes=[err],
            ),
            2,
        )

    deadline = Deadline()
    manifests = detect_manifests(root)
    detected = [e for e, paths in manifests.items() if paths]
    excluded = []
    if eco_filter is not None:
        for e in list(manifests):
            if e not in eco_filter:
                if manifests[e]:
                    excluded.append(e)
                manifests[e] = []
        for e in eco_filter:
            if e not in detected:
                pass

    dep_sets = group_dependency_sets(root, manifests)
    report = AuditReport(
        project=root.name,
        started_at=_now_iso(),
        helper_revision=HELPER_REVISION,
        ecosystems=sorted({ds.ecosystem for ds in dep_sets if ds.coverage != "excluded"}),
        dependency_sets=dep_sets,
        findings=[],
        licences=[],
        outdated=[],
        tool_versions={
            "helper_revision": HELPER_REVISION,
            "python": sys.version.split()[0],
            "pip_audit_required": REQUIRED_PIP_AUDIT,
            "packaging_required": REQUIRED_PACKAGING,
            "cvss_approved": str(CVSS_APPROVED).lower(),
        },
        excluded_ecosystems=excluded,
    )

    fixture_dir = Path(args.fixture_http).resolve() if args.fixture_http else None
    http = HttpClient(fixture_dir=fixture_dir, deadline=deadline)

    # Validate runner override early.
    if args.runner == "pip-audit":
        # Explicit selection: missing tool exits 3 (no silent OSV fallback).
        pass

    for ds in dep_sets:
        if ds.ecosystem == "python" and ds.coverage != "not_applicable":
            collect_python_inventory(root, ds)
            if args.skip_python_scan:
                ds.check_status = "skipped"
                continue
            if ds.coverage == "incomplete" and not ds.pins:
                ds.check_status = "failed"
                continue
            runner = args.runner or "pip-audit"
            ds.runner = runner if runner != "npm" else "pip-audit"
            vuln_hits: List[Dict[str, Any]] = []
            scan_err: Optional[str] = None
            if ds.runner == "pip-audit":
                if args.pip_audit_stub:
                    stub = json.loads(Path(args.pip_audit_stub).read_text(encoding="utf-8"))
                    vuln_hits = stub if isinstance(stub, list) else stub.get("vulns") or []
                    for hit in vuln_hits:
                        if "manifest" not in hit and ds.pins:
                            hit["manifest"] = ds.pins[0].manifest
                else:
                    vuln_hits, scan_err = run_pip_audit(
                        ds.pins, args.trusted_python, deadline
                    )
                    if scan_err and "not found" in scan_err:
                        if args.runner == "pip-audit":
                            ds.coverage = "failed"
                            ds.coverage_reason = scan_err
                            ds.check_status = "failed"
                            report.notes.append(
                                "pip-audit missing. Install pip-audit==2.10.0 in a trusted "
                                "environment. Re-run /audit-deps."
                            )
                            continue
                        # Preferred scanner absent: direct OSV fallback (AgDR-0176).
                        report.notes.append(
                            "pip-audit absent. Falling back to direct OSV for the same inventory."
                        )
                        ds.runner = "osv"
                        vuln_hits, scan_err = query_osv_batch(ds.pins, http, deadline)
                    elif scan_err:
                        # Scanner failure remains failed. No silent clean fallback.
                        ds.coverage = "failed"
                        ds.coverage_reason = scan_err
                        ds.check_status = "failed"
                        report.notes.append(scan_err)
                        continue
            else:
                vuln_hits, scan_err = query_osv_batch(ds.pins, http, deadline)
                if scan_err:
                    ds.coverage = "failed"
                    ds.coverage_reason = scan_err
                    ds.check_status = "failed"
                    report.notes.append(scan_err)
                    continue

            findings, enrich_err = enrich_osv_records(vuln_hits, http, deadline)
            for f in findings:
                if not f.manifests:
                    f.manifests = list(ds.manifests)
            report.findings.extend(findings)
            if enrich_err:
                report.notes.append(enrich_err)
            licences, outdated, meta_err = python_licence_and_outdated(ds.pins, http, deadline)
            report.licences.extend(licences)
            report.outdated.extend(outdated)
            if meta_err:
                report.notes.append(meta_err)
            if ds.coverage == "incomplete":
                ds.check_status = "incomplete"
            else:
                ds.check_status = "complete"

        elif ds.ecosystem == "npm":
            if args.skip_npm_scan or args.runner in ("pip-audit", "osv"):
                ds.check_status = "skipped"
                continue
            directory = root if ds.directory == "." else root / ds.directory
            findings, npm_err = run_npm_audit(directory, deadline)
            if npm_err:
                ds.coverage = "failed"
                ds.coverage_reason = npm_err
                ds.check_status = "failed"
                report.notes.append(npm_err)
            else:
                for f in findings:
                    f.manifests = list(ds.manifests)
                report.findings.extend(findings)
                ds.coverage = "complete"
                ds.check_status = "complete"

    report.ecosystems = sorted({ds.ecosystem for ds in dep_sets})
    if excluded:
        report.notes.append(
            "Detected ecosystems excluded by filter: " + ", ".join(excluded)
        )

    code = choose_exit_code(report)
    return report, code


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = parse_args(argv)
    report, code = run_audit(args)
    payload = report_to_dict(report)
    payload["exit_code"] = code
    text = json.dumps(payload, indent=2, sort_keys=True)
    if args.json_out:
        Path(args.json_out).write_text(text + "\n", encoding="utf-8")
    else:
        # Success path must not write to stderr (framework convention for hooks).
        # The helper prints JSON on stdout.
        sys.stdout.write(text + "\n")
    if args.md_out:
        Path(args.md_out).write_text(render_markdown(report), encoding="utf-8")
    return code


if __name__ == "__main__":
    sys.exit(main())
