#!/usr/bin/env python3
"""Report defect recall for the labeled 21 November miss subset."""

import argparse
import json

CASES = {"rex": ["20261121-filter", "20261121-audit-ignore"],
         "tariq": ["20261121-threat-count"]}


def report(corpus, results):
    agent = corpus["agent"]
    entries = {entry["id"]: entry for entry in corpus["entries"]}
    runs = {run["id"]: run for run in results}
    caught = total = alarms = scored_controls = pending = 0
    for case in CASES[agent]:
        controls = [entry["id"] for entry in corpus["entries"]
                    if entry.get("control_for") == case]
        for entry_id in [case, *(controls or [None])]:
            entry, run = entries.get(entry_id), runs.get(entry_id)
            if entry is None or run is None or run["status"] != "SCORED":
                pending += 1
                continue
            defects = {defect["id"] for defect in entry["ground_truth_defects"]}
            found = set(run["caught_defects"])
            if not found <= defects:
                raise ValueError("caught defects must belong to the frozen key")
            if entry_id in controls:
                if defects:
                    raise ValueError("controls must have an empty defect set")
                scored_controls += 1
                alarms += run["false_alarms"]
            else:
                total += len(defects)
                caught += len(found)
    recall = f"{caught / total:.0%} ({caught}/{total})" if total else "n/a (0/0)"
    return (f"21 November miss recall — {agent}: {recall}\n"
            f"Clean-control false alarms: {alarms} ({scored_controls} controls scored)\n"
            f"Pending or discarded cases: {pending}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--corpus", required=True)
    parser.add_argument("--results", required=True)
    args = parser.parse_args()
    with open(args.corpus, encoding="utf-8") as handle:
        corpus = json.load(handle)
    with open(args.results, encoding="utf-8") as handle:
        results = json.load(handle)
    print(report(corpus, results))


if __name__ == "__main__":
    main()
