#!/usr/bin/env python3
"""Report review rounds and explicit reverts for PRs merged in the last 30 days.

Read GitHub with GET calls, or read a saved JSON export with --input.
A round is one distinct reviewed commit per agent, not one posted comment.
"""

import argparse
import datetime as dt
import json
import re
import sys

from mine_disagreements import (
    ForgeError, _run_gh, group_by_commit, parse_paginated, review_unit,
)


def timestamp(value):
    parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        raise ValueError("timestamps must include a timezone")
    return parsed


def in_window(pr, start, end):
    return bool(pr.get("merged_at")) and start <= timestamp(pr["merged_at"]) < end


def fetch(repo, start, end):
    """Read all closed PR pages, then fetch evidence for the selected window."""
    def pages(path):
        return parse_paginated(_run_gh(["api", "--method", "GET", "--paginate", path]))

    prs = pages(f"repos/{repo}/pulls?state=closed&per_page=100")
    selected = [pr for pr in prs if in_window(pr, start, end)]
    for pr in selected:
        number = pr["number"]
        pr["reviews"] = pages(f"repos/{repo}/pulls/{number}/reviews?per_page=100")
        pr["comments"] = pages(f"repos/{repo}/issues/{number}/comments?per_page=100")
        commit = json.loads(_run_gh([
            "api", "--method", "GET",
            f"repos/{repo}/commits/{pr['merge_commit_sha']}",
        ]))
        pr["merge_message"] = commit["commit"]["message"]
    return {"repo": repo, "prs": selected}


def report(data, start, end):
    prs = sorted((pr for pr in data["prs"] if in_window(pr, start, end)),
                 key=lambda pr: (pr["merged_at"], pr["number"]))
    reverted_by = {}
    for pr in prs:
        targets = set(re.findall(r"^This reverts commit ([0-9a-fA-F]{40})\.$",
                                 pr["merge_message"], re.MULTILINE))
        for target in targets:
            reverted_by.setdefault(target.lower(), set()).add(pr["number"])
    lines = [
        "# Review rounds and reverts", "",
        f"Repository: `{data['repo']}`.",
        f"Merge window: {start.isoformat()} inclusive to {end.isoformat()} exclusive.", "",
        "A round is one distinct reviewed commit per agent across reviews and conversation comments.",
        "Only submissions at or before merge count when submission timestamps exist.",
        "Repeated submissions on the same commit count once per agent.",
        "Unknown counts agent submissions without a readable verdict or valid commit.",
        "Reverts count explicit full-SHA revert trailers in merge commits within this window.",
        "Manual reversals, constituent-commit reversions, and reverts outside this window remain unmeasured.", "",
        "| PR | Rex rounds | Hakim rounds | Tariq rounds | Unknown | Reverts | Reverting PRs |",
        "|---|---|---|---|---|---|---|",
    ]
    for pr in prs:
        submissions = pr["reviews"] + pr["comments"]
        units = [review_unit(raw) for raw in submissions
                 if not (raw.get("submitted_at") or raw.get("created_at"))
                 or timestamp(raw.get("submitted_at") or raw["created_at"])
                 <= timestamp(pr["merged_at"])]
        # Comments lack API commit_id. Require an explicit body SHA in that case.
        for unit in units:
            if not re.fullmatch(r"[0-9a-f]{7,40}", unit["commit"] or ""):
                unit["commit"] = None
        unknown = sum(bool(u["reviewer"]) and not (u["verdict"] and u["commit"])
                      for u in units)
        groups = group_by_commit(units)
        counts = [sum(any(u["reviewer"] == agent for u in group) for group in groups.values())
                  for agent in ("rex", "hakim", "tariq")]
        reverts = sorted(reverted_by.get(pr["merge_commit_sha"].lower(), set()))
        lines.append(f"| #{pr['number']} | {counts[0]} | {counts[1]} | {counts[2]} | "
                     f"{unknown} | {len(reverts)} | {', '.join('#' + str(n) for n in reverts) or 'None'} |")
    if not prs:
        lines.extend(["", "No merged PRs in this window."])
    return "\n".join(lines) + "\n"


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--repo", help="GitHub owner/repo")
    source.add_argument("--input", help="Saved JSON export with repo and prs")
    parser.add_argument("--as-of", help="Exclusive window end as an ISO timestamp with timezone")
    parser.add_argument("--export", action="store_true", help="Print captured JSON instead of Markdown")
    args = parser.parse_args(argv)
    if args.repo and not re.fullmatch(r"[\w.-]+/[\w.-]+", args.repo):
        parser.error("--repo must be owner/repo")
    try:
        end = timestamp(args.as_of) if args.as_of else dt.datetime.now(dt.timezone.utc)
        start = end - dt.timedelta(days=30)
        if args.input:
            with open(args.input, encoding="utf-8") as handle:
                data = json.load(handle)
        else:
            data = fetch(args.repo, start, end)
        rendered = report(data, start, end)
        print(json.dumps(data, indent=2) if args.export else rendered, end="\n" if args.export else "")
    except (ForgeError, OSError, ValueError, KeyError, TypeError) as exc:
        print(f"review-rounds: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
