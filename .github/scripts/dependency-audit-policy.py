#!/usr/bin/env python3
"""Apply this repository's expiring exceptions to the shared audit report."""

import argparse
from datetime import date, datetime, timezone
import json
import os
from pathlib import Path
import re


# GHSA excludes ambiguous characters. Boundaries reject partial identifiers.
ADVISORY_RE = re.compile(
    r"(?<![A-Za-z0-9_-])(?:GHSA(?:-[23456789cfghjmpqrvwx]{4}){3}"
    r"|CVE-[0-9]{4}-[0-9]{4,})(?![A-Za-z0-9_-])", re.IGNORECASE
)
NPM_PACKAGE_RE = re.compile(r"(?:@[a-z0-9._~-]+/)?[a-z0-9._~-]+")


def advisory_ids(finding):
    """Extract identifiers from advisory IDs, URLs, and aliases."""
    values = [finding.get("advisory_id", ""), finding.get("url", ""),
              *finding.get("aliases", [])]
    return {match.upper() for value in values if isinstance(value, str)
            for match in ADVISORY_RE.findall(value)}


def project_scope(finding):
    """The helper assigns each npm dependency set's manifests to its findings."""
    manifests = finding.get("manifests")
    if (finding.get("ecosystem") != "npm" or not isinstance(manifests, list)
            or not manifests or not all(isinstance(path, str) and path for path in manifests)):
        return None
    return tuple(sorted(set(manifests)))


def ignored_roots(start, findings, ignores):
    """Resolve every reachable finding. Missing links and cycles fail closed."""
    roots = set()
    # Use an explicit stack so long chains cannot exceed Python's recursion limit.
    stack = [(start, False)]
    active, complete = set(), set()
    while stack:
        index, exiting = stack.pop()
        if exiting:
            active.remove(index)
            complete.add(index)
            continue
        if index in active:
            return None
        if index in complete:
            continue
        finding = findings[index]
        if finding["severity"] == "Unknown":
            return None
        identifiers = advisory_ids(finding)
        if identifiers:
            matched = identifiers.intersection(ignores)
            if not matched:
                return None
            roots.update(matched)
            complete.add(index)
            continue
        scope = project_scope(finding)
        via = finding.get("advisory_id")
        # report_to_dict omits raw.via. advisory_id retains its first item only.
        if scope is None or not isinstance(via, str) or not NPM_PACKAGE_RE.fullmatch(via):
            return None
        targets = [i for i, item in enumerate(findings)
                   if item.get("package") == via and project_scope(item) == scope]
        if not targets:
            return None
        active.add(index)
        stack.append((index, True))
        stack.extend((target, False) for target in targets)
    return roots or None


def evaluate(report, entries, helper_exit, today):
    """Return policy messages and a failing status when any check blocks."""
    messages = []
    ignores = {}
    failed = False
    if not isinstance(entries, list):
        raise ValueError("Ignore file must contain a list")
    for index, entry in enumerate(entries):
        label = entry.get("id", f"entry {index + 1}") if isinstance(entry, dict) else f"entry {index + 1}"
        try:
            if not isinstance(entry, dict):
                raise ValueError("expected an object")
            for field in ("id", "reason", "expires"):
                if not isinstance(entry.get(field), str) or not entry[field].strip():
                    raise ValueError(f"missing or empty {field}")
            if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", entry["expires"]):
                raise ValueError("expires must use YYYY-MM-DD")
            expiry = date.fromisoformat(entry["expires"])
            if expiry < today:
                raise ValueError(f"expired on {expiry}")
            ignores[entry["id"].upper()] = entry["expires"]
        except ValueError as error:
            messages.append(f"Invalid ignore {label}: {error}")
            failed = True

    for index, finding in enumerate(report["findings"]):
        severity = finding["severity"]
        if severity == "Unknown":
            failed = True
        if severity not in ("High", "Critical"):
            continue
        matched = ignored_roots(index, report["findings"], ignores)
        if matched:
            details = ", ".join(f"{identifier} (expires {ignores[identifier]})"
                                for identifier in sorted(matched))
            messages.append(
                f"Ignored: {finding['package']} — {finding['advisory_id']} "
                f"(root advisories: {details})"
            )
        else:
            messages.append(f"Blocking: {severity} {finding['package']} — {finding['advisory_id']}")
            failed = True

    # Critical findings take precedence over incomplete coverage in helper exit 1.
    incomplete = report["unsupported_only"] or any(
        item["coverage"] not in ("excluded", "not_applicable")
        and (item["coverage"] in ("incomplete", "failed")
             or item["check_status"] in ("failed", "incomplete", "skipped", "pending"))
        for item in report["dependency_sets"]
    )
    if helper_exit not in (0, 1) or incomplete:
        messages.append(f"Audit did not complete successfully (helper exit {helper_exit}).")
        failed = True
    return int(failed), messages


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("report", type=Path)
    parser.add_argument("ignores", type=Path)
    parser.add_argument("helper_exit", type=int)
    args = parser.parse_args()
    try:
        status, messages = evaluate(
            json.loads(args.report.read_text(encoding="utf-8")),
            json.loads(args.ignores.read_text(encoding="utf-8")),
            args.helper_exit,
            datetime.now(timezone.utc).date(),
        )
    except (OSError, ValueError, KeyError, TypeError) as error:
        status, messages = 1, [f"Dependency audit policy failed: {error}"]
    for message in messages:
        print(message)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as output:
            output.write("## Dependency audit policy\n\n")
            output.writelines(f"- {message}\n" for message in messages)
            output.write(f"\nPolicy result: {'FAILED' if status else 'PASSED'}.\n")
    return status


if __name__ == "__main__":
    raise SystemExit(main())
