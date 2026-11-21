#!/usr/bin/env python3
"""Test round counts, revert attribution, date boundaries, and GET-only capture."""

import io
import json
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from unittest.mock import patch

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "lib"))
import review_rounds as rr

END = rr.timestamp("2026-11-22T00:00:00Z")
START = END - rr.dt.timedelta(days=30)


def review(agent, sha=None, verdict="APPROVED"):
    headings = {"rex": "Code", "hakim": "Security", "tariq": "Architecture"}
    return {"body": f"## {headings[agent]} Review\n### Verdict\n{verdict}\n"
                    + (f"Reviewed commit: `{sha}`" if sha else "")}


def pr(number, merged_at="2026-11-21T12:00:00Z"):
    return {"number": number, "merged_at": merged_at,
            "merge_commit_sha": str(number) * 40, "merge_message": "A change",
            "reviews": [], "comments": []}


class ReportTest(unittest.TestCase):
    def render(self, prs):
        return rr.report({"repo": "example/repo", "prs": prs}, START, END)

    def test_rounds_deduplicate_agents_and_commit_prefixes(self):
        item = pr(1)
        item["reviews"] = [review("rex", "a" * 40), review("hakim", "a" * 40)]
        item["comments"] = [review("rex", "a" * 8), review("rex", "b" * 40),
                            review("tariq", "b" * 40)]
        self.assertIn("| #1 | 2 | 1 | 1 | 0 | 0 | None |", self.render([item]))

    def test_unknown_submissions_do_not_become_rounds(self):
        item = pr(1)
        item["reviews"] = [review("rex"), review("tariq", "c" * 40, "No findings remain.")]
        item["comments"] = [review("rex", "abc"), {"body": "Human comment"}]
        self.assertIn("| #1 | 0 | 0 | 0 | 3 |", self.render([item]))

    def test_body_commit_wins_over_api_commit(self):
        item = pr(1)
        item["reviews"] = [dict(review("rex", "a" * 40), commit_id="b" * 40),
                           dict(review("rex"), commit_id="a" * 40)]
        self.assertIn("| #1 | 1 | 0 | 0 | 0 |", self.render([item]))

    def test_post_merge_reviews_and_comments_do_not_count(self):
        item = pr(1)
        item["reviews"] = [dict(review("rex", "a" * 40), submitted_at=item["merged_at"]),
                           dict(review("rex", "b" * 40), submitted_at="2026-11-21T13:00:00Z")]
        item["comments"] = [dict(review("tariq", "c" * 40), created_at="2026-11-21T13:00:00Z")]
        self.assertIn("| #1 | 1 | 0 | 0 | 0 |", self.render([item]))

    def test_window_boundaries_and_unmerged_pr(self):
        text = self.render([pr(1, START.isoformat()), pr(2, END.isoformat()),
                            pr(3, "2026-10-22T23:59:59Z"), pr(4, None)])
        self.assertIn("| #1 |", text)
        for number in (2, 3, 4):
            self.assertNotIn(f"| #{number} |", text)

    def test_revert_targets_original_merge_and_deduplicates_trailers(self):
        original, revert, outside = pr(1), pr(2), pr(3, END.isoformat())
        trailer = "This reverts commit " + "1" * 40 + "."
        revert["merge_message"] = trailer + "\n" + trailer
        outside["merge_message"] = trailer
        text = self.render([original, revert, outside])
        self.assertIn("| #1 | 0 | 0 | 0 | 0 | 1 | #2 |", text)
        self.assertIn("| #2 | 0 | 0 | 0 | 0 | 0 | None |", text)

    def test_prose_revert_and_short_sha_do_not_count(self):
        original, other = pr(1), pr(2)
        other["merge_message"] = "Revert something\nThis reverts commit 1111111."
        self.assertIn("| #1 | 0 | 0 | 0 | 0 | 0 | None |", self.render([original, other]))

    def test_empty_report(self):
        self.assertIn("No merged PRs in this window.", self.render([]))

    def test_missing_evidence_is_an_error(self):
        item = pr(1)
        del item["reviews"]
        with self.assertRaises(KeyError):
            self.render([item])


class CaptureTest(unittest.TestCase):
    def test_paginated_get_calls_and_merge_time_filter(self):
        item = pr(1)
        calls = []

        def fake(args):
            calls.append(args)
            self.assertEqual(args[:3], ["api", "--method", "GET"])
            if args[-1].endswith("pulls?state=closed&per_page=100"):
                return json.dumps([item]) + "\n" + json.dumps([pr(2, None)])
            if "/commits/" in args[-1]:
                return json.dumps({"commit": {"message": "Change"}})
            self.assertIn("--paginate", args)
            return "[]\n[]"

        with patch.object(rr, "_run_gh", side_effect=fake):
            data = rr.fetch("example/repo", START, END)
        self.assertEqual([p["number"] for p in data["prs"]], [1])
        self.assertEqual(len(calls), 4)

    def test_api_failure_prints_no_partial_report(self):
        out, err = io.StringIO(), io.StringIO()
        with patch.object(rr, "_run_gh", side_effect=rr.ForgeError("offline")):
            with redirect_stdout(out), redirect_stderr(err):
                code = rr.main(["--repo", "example/repo"])
        self.assertEqual(code, 1)
        self.assertEqual(out.getvalue(), "")
        self.assertIn("offline", err.getvalue())

    def test_export_and_offline_report(self):
        data = {"repo": "example/repo", "prs": [pr(1)]}
        with tempfile.NamedTemporaryFile(mode="w", suffix=".json") as handle:
            json.dump(data, handle)
            handle.flush()
            for export in (False, True):
                out = io.StringIO()
                args = ["--input", handle.name, "--as-of", END.isoformat()]
                with redirect_stdout(out):
                    self.assertEqual(rr.main(args + (["--export"] if export else [])), 0)
                if export:
                    self.assertEqual(json.loads(out.getvalue()), data)
                else:
                    self.assertIn("| #1 |", out.getvalue())

    def test_naive_timestamp_fails(self):
        with redirect_stderr(io.StringIO()):
            self.assertEqual(rr.main(["--repo", "example/repo", "--as-of", "2026-11-22"]), 1)


if __name__ == "__main__":
    unittest.main()
