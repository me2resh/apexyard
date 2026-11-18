#!/usr/bin/env python3
"""Apply this repository's expiring exceptions to the shared audit report."""

import argparse
from datetime import date, datetime, timezone
import json
import os
from pathlib import Path
import re


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
            ignores[entry["id"]] = entry["expires"]
        except ValueError as error:
            messages.append(f"Invalid ignore {label}: {error}")
            failed = True

    for finding in report["findings"]:
        severity = finding["severity"]
        if severity == "Unknown":
            failed = True
        if severity not in ("High", "Critical"):
            continue
        ids = [finding["advisory_id"], *finding["aliases"]]
        matched = next((identifier for identifier in ids if identifier in ignores), None)
        if matched:
            messages.append(
                f"Ignored: {finding['package']} — {finding['advisory_id']} "
                f"(matched {matched}, expires {ignores[matched]})"
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
