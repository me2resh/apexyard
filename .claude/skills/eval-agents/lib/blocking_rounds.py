#!/usr/bin/env python3
"""List blocking review submissions and later named reverts for merged PRs."""

import argparse
import datetime as dt
import json
import re
import sys

from review_rounds import ForgeError, _run_gh, fetch, in_window, parse_paginated, timestamp


def is_blocking(review):
    if review.get("state") == "CHANGES_REQUESTED":
        return True
    heading = False
    for line in (review.get("body") or "").splitlines():
        text = re.sub(r"[*_`]+", "", line).strip().upper()
        if not text:
            continue
        if heading and text == "CHANGES REQUESTED":
            return True
        text = re.sub(r"^#{1,6}\s+", "", text)
        text = re.sub(r"\s+#+$", "", text).strip()
        if re.fullmatch(r"VERDICT\s*:\s*CHANGES REQUESTED", text):
            return True
        if re.fullmatch(r"VERDICT\s+CHANGES REQUESTED", text) and re.match(r"^\s*#{1,6}\s", line):
            return True
        heading = text == "VERDICT" and bool(re.match(r"^\s*#{1,6}\s", line))
    return False


def report(data, start, end):
    lines = ["PR  Blocking rounds  Reverted"]
    for pr in sorted(data["prs"], key=lambda item: item["number"]):
        if not in_window(pr, start, end):
            continue
        merged = timestamp(pr["merged_at"])
        rounds = sum(
            is_blocking(review)
            and (not review.get("submitted_at") or timestamp(review["submitted_at"]) <= merged)
            for review in pr["reviews"]
        )
        reverted = any(
            timestamp(commit["commit"]["committer"]["date"]) > merged
            and commit["commit"]["message"].splitlines()[0].startswith("Revert")
            and re.search(rf"(?<![\w/])#{pr['number']}(?!\d)",
                          commit["commit"]["message"].splitlines()[0])
            for commit in data["commits"]
        )
        lines.append(f"#{pr['number']}  {rounds}  {'yes' if reverted else 'no'}")
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", required=True)
    parser.add_argument("--days", type=int, default=30)
    parser.add_argument("--input", help="Offline JSON with repo, prs, and commits")
    parser.add_argument("--as-of", help="Exclusive merge-window end")
    args = parser.parse_args()
    if args.days <= 0 or not re.fullmatch(r"[\w.-]+/[\w.-]+", args.repo):
        parser.error("use a positive day count and an owner/repo")
    try:
        end = timestamp(args.as_of) if args.as_of else dt.datetime.now(dt.timezone.utc)
        start = end - dt.timedelta(days=args.days)
        if args.input:
            with open(args.input, encoding="utf-8") as handle:
                data = json.load(handle)
            if data["repo"] != args.repo:
                raise ValueError("fixture repo does not match --repo")
        else:
            data = fetch(args.repo, start, end)
            # Read through the capture time, including reverts after the merge window.
            data["commits"] = parse_paginated(_run_gh([
                "api", "--method", "GET", "--paginate",
                f"repos/{args.repo}/commits?since={start.isoformat()}&per_page=100",
            ]))
        print(report(data, start, end))
    except (ForgeError, OSError, ValueError, KeyError, TypeError, IndexError) as exc:
        print(f"blocking-rounds: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
