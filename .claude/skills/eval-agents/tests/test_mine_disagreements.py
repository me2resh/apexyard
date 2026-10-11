#!/usr/bin/env python3
"""Unit tests for lib/mine_disagreements.py. No network: fixtures only.

Run: python3 -m unittest discover -s .claude/skills/eval-agents/tests -p 'test_mine_*.py'
"""

from __future__ import annotations

import io
import json
import os
import sys
import unittest
from contextlib import redirect_stderr, redirect_stdout

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "lib"))

import mine_disagreements as md  # noqa: E402

FIXTURE = os.path.join(HERE, "fixtures", "mine-disagreements", "merged-prs.json")


def load_fixture():
    with open(FIXTURE, encoding="utf-8") as handle:
        return json.load(handle)


class ClassifyReviewerTest(unittest.TestCase):
    def test_section_headers(self):
        self.assertEqual(md.classify_reviewer("## Code Review: PR #1\n"), "rex")
        self.assertEqual(md.classify_reviewer("## Security Review: PR #1\n"), "hakim")
        self.assertEqual(md.classify_reviewer("## Design Review: PR #1\n"), "tariq")
        self.assertEqual(
            md.classify_reviewer("## Architecture Review: PR #1\n"), "tariq"
        )

    def test_header_after_lead_line(self):
        body = "The verdict is APPROVED.\n\n## Code Review: PR #1\n"
        self.assertEqual(md.classify_reviewer(body), "rex")

    def test_earliest_header_wins(self):
        body = (
            "## Security Review: PR #1\n\nRex's earlier note:\n## Code Review: PR #1\n"
        )
        self.assertEqual(md.classify_reviewer(body), "hakim")

    def test_footer_fallback(self):
        self.assertEqual(
            md.classify_reviewer("text\n---\nReviewed by Hakim (Security Auditor)"),
            "hakim",
        )

    def test_unknown_or_empty(self):
        self.assertIsNone(md.classify_reviewer(""))
        self.assertIsNone(md.classify_reviewer("LGTM, ship it."))


class ParseVerdictTest(unittest.TestCase):
    def test_heading_section_bold(self):
        body = "## Code Review\n\n### Verdict\n**APPROVED**\nReason.\n\n---\nfooter CHANGES REQUESTED"
        verdict, excerpt = md.parse_verdict(body)
        self.assertEqual(verdict, md.APPROVED)
        self.assertIn("APPROVED", excerpt)
        self.assertNotIn("footer", excerpt)

    def test_heading_with_blank_line(self):
        self.assertEqual(
            md.parse_verdict("### Verdict\n\n**CHANGES REQUESTED**\n")[0],
            md.CHANGES_REQUESTED,
        )

    def test_recap_prose_outside_section_is_ignored(self):
        body = (
            "## Security Review\n\n### Summary\nRound 1 was CHANGES REQUESTED. "
            "All four BLOCKING findings are fixed.\n\n### Verdict\n**APPROVED**\n"
        )
        self.assertEqual(md.parse_verdict(body)[0], md.APPROVED)

    def test_no_section_means_no_verdict(self):
        body = "## Code Review\n\nThe verdict is APPROVED. All blocking findings are fixed."
        self.assertEqual(md.parse_verdict(body), (None, ""))

    def test_bold_wins_over_trailing_prose(self):
        self.assertEqual(
            md.parse_verdict("### Verdict\n**APPROVED** - no blocking findings.\n")[0],
            md.APPROVED,
        )

    def test_verdict_line_fallback(self):
        body = "## Code Review\n\n**Verdict**: APPROVED. Next action: reply to the comment.\n"
        self.assertEqual(md.parse_verdict(body)[0], md.APPROVED)

    def test_inline_bold_verdict_line(self):
        body = "## Security Review\n\n**Verdict: APPROVED.** LOW-1 is fixed. No new blocking finding.\n"
        self.assertEqual(md.parse_verdict(body)[0], md.APPROVED)

    def test_heading_beats_verdict_line(self):
        body = "**Verdict**: APPROVED.\n\n### Verdict\n**CHANGES REQUESTED**\n"
        self.assertEqual(md.parse_verdict(body)[0], md.CHANGES_REQUESTED)

    def test_blocking_and_synonyms(self):
        self.assertEqual(
            md.parse_verdict("### Verdict\n**BLOCKING**\n")[0], md.BLOCKING
        )
        self.assertEqual(
            md.parse_verdict("### Verdict\nREQUEST CHANGES\n")[0], md.CHANGES_REQUESTED
        )
        self.assertEqual(
            md.parse_verdict("### Verdict\nCHANGES_REQUESTED\n")[0],
            md.CHANGES_REQUESTED,
        )
        self.assertEqual(
            md.parse_verdict("### Verdict\n**NOT APPROVED**\n")[0], md.CHANGES_REQUESTED
        )
        self.assertEqual(md.parse_verdict("### Verdict\n**COMMENT**\n")[0], md.COMMENT)

    def test_changes_and_blocking_on_one_line_agree(self):
        self.assertEqual(
            md.parse_verdict("### Verdict\n**CHANGES REQUESTED (BLOCKING)**\n")[0],
            md.CHANGES_REQUESTED,
        )

    def test_unfilled_template_is_ambiguous(self):
        body = "### Verdict\n**[APPROVED / CHANGES REQUESTED / COMMENT]**\n"
        self.assertIsNone(md.parse_verdict(body)[0])

    def test_conflicting_sections_are_ambiguous(self):
        body = "### Verdict\n**APPROVED**\n\n## Later\n\n### Verdict\n**CHANGES REQUESTED**\n"
        self.assertIsNone(md.parse_verdict(body)[0])

    def test_repeated_matching_sections_agree(self):
        body = "### Verdict\n**CHANGES REQUESTED**\n\n### Glossary\nx\n\n### Verdict\n**CHANGES REQUESTED**\n"
        self.assertEqual(md.parse_verdict(body)[0], md.CHANGES_REQUESTED)

    def test_excerpt_is_capped(self):
        body = "### Verdict\n**APPROVED**\n" + ("word " * 400)
        self.assertLessEqual(len(md.parse_verdict(body)[1]), md.EXCERPT_LIMIT)


class ReviewedCommitTest(unittest.TestCase):
    FULL = "0123456789abcdef0123456789abcdef01234567"
    LATER = "fedcba9876543210fedcba9876543210fedcba98"

    def test_body_footer_wins_over_api(self):
        body = "Reviewed commit: `{}`".format(self.FULL)
        self.assertEqual(md.reviewed_commit(body, self.LATER), self.FULL)

    def test_short_body_sha_resolves_to_api(self):
        body = "**Commit**: `{}`".format(self.FULL[:8])
        self.assertEqual(md.reviewed_commit(body, self.FULL), self.FULL)

    def test_api_fallback(self):
        self.assertEqual(
            md.reviewed_commit("no sha here", self.FULL.upper()), self.FULL
        )

    def test_nothing_known(self):
        self.assertIsNone(md.reviewed_commit("", None))


class GroupingTest(unittest.TestCase):
    def unit(self, reviewer, verdict, commit, at):
        return {
            "review_id": at,
            "reviewer": reviewer,
            "verdict": verdict,
            "commit": commit,
            "submitted_at": at,
            "url": "u",
            "verdict_excerpt": "",
        }

    def test_groups_by_commit_and_sorts_by_time(self):
        units = [
            self.unit("hakim", md.CHANGES_REQUESTED, "aaa", "2026-01-01T10:10:00Z"),
            self.unit("rex", md.APPROVED, "aaa", "2026-01-01T10:00:00Z"),
            self.unit("rex", md.APPROVED, "bbb", "2026-01-01T11:00:00Z"),
        ]
        groups = md.group_by_commit(units)
        self.assertEqual(sorted(groups), ["aaa", "bbb"])
        self.assertEqual([u["reviewer"] for u in groups["aaa"]], ["rex", "hakim"])

    def test_drops_units_without_reviewer_verdict_or_commit(self):
        units = [
            self.unit(None, md.APPROVED, "aaa", "t1"),
            self.unit("rex", None, "aaa", "t2"),
            self.unit("rex", md.APPROVED, None, "t3"),
        ]
        self.assertEqual(md.group_by_commit(units), {})

    def test_parallel_challenge_counts_regardless_of_order(self):
        units = [
            self.unit("hakim", md.CHANGES_REQUESTED, "aaa", "2026-01-01T09:00:00Z"),
            self.unit("rex", md.APPROVED, "aaa", "2026-01-01T10:00:00Z"),
        ]
        found = md.find_candidates("o/r", {"number": 9, "url": "u"}, units)
        self.assertEqual(len(found), 1)

    def test_rex_vs_rex_is_not_a_candidate(self):
        units = [
            self.unit("rex", md.APPROVED, "aaa", "t1"),
            self.unit("rex", md.CHANGES_REQUESTED, "aaa", "t2"),
        ]
        self.assertEqual(
            md.find_candidates("o/r", {"number": 9, "url": "u"}, units), []
        )

    def test_comment_challenge_is_not_a_candidate(self):
        units = [
            self.unit("rex", md.APPROVED, "aaa", "t1"),
            self.unit("hakim", md.COMMENT, "aaa", "t2"),
        ]
        self.assertEqual(
            md.find_candidates("o/r", {"number": 9, "url": "u"}, units), []
        )


class FixtureMineTest(unittest.TestCase):
    def setUp(self):
        data = load_fixture()
        self.report = md.mine(data["repo"], data["prs"])
        self.by_pr = {c["draft_entry"]["pr"]: c for c in self.report["candidates"]}

    def test_only_the_mined_direction_is_reported(self):
        self.assertEqual(sorted(self.by_pr), [101, 105, 106])

    def test_reverse_direction_is_not_mined(self):
        self.assertNotIn(102, self.by_pr)

    def test_recap_prose_is_not_a_candidate(self):
        self.assertNotIn(103, self.by_pr)

    def test_cross_commit_disagreement_is_not_a_candidate(self):
        self.assertNotIn(104, self.by_pr)

    def test_tariq_challenge_is_mined(self):
        self.assertEqual(self.by_pr[105]["direction"], "Rex APPROVED -> Tariq CHANGES")

    def test_body_commit_beats_api_commit(self):
        self.assertEqual(self.by_pr[106]["evidence"]["commit"], "1" * 40)
        self.assertEqual(
            self.by_pr[106]["evidence"]["challenges"][0]["verdict"], md.BLOCKING
        )

    def test_unparsed_reviews_are_reported(self):
        self.assertEqual(self.report["scanned"]["agent_reviews_without_verdict"], 1)
        self.assertEqual(self.report["unparsed_agent_reviews"][0]["pr"], 107)
        self.assertNotIn(107, self.by_pr)

    def test_counts(self):
        self.assertEqual(self.report["scanned"]["prs"], 7)
        self.assertEqual(self.report["scanned"]["reviews"], 15)
        self.assertEqual(self.report["scanned"]["agent_reviews"], 14)

    def test_draft_is_not_a_complete_corpus_entry(self):
        draft = self.by_pr[101]["draft_entry"]
        self.assertNotIn("ground_truth_defects", draft)
        self.assertNotIn("was_justified", draft["recorded_verdict"])
        self.assertEqual(draft["oracle"]["source"], "independent_review")
        self.assertEqual(draft["id"], "rex-101-aaaaaaaa")
        self.assertEqual(draft["diff_range"], "aaaaaaaa~1..aaaaaaaa")
        self.assertEqual(draft["repo"], "example-org/example-repo")

    def test_evidence_links(self):
        evidence = self.by_pr[101]["evidence"]
        self.assertTrue(
            evidence["approvals"][0]["url"].endswith("pullrequestreview-1011")
        )
        self.assertTrue(
            evidence["challenges"][0]["url"].endswith("pullrequestreview-1012")
        )
        self.assertEqual(
            evidence["pr_url"], "https://github.com/example-org/example-repo/pull/101"
        )


class PaginationTest(unittest.TestCase):
    def test_concatenated_pages(self):
        self.assertEqual(
            md.parse_paginated('[{"id":1}]\n[{"id":2},{"id":3}]'),
            [{"id": 1}, {"id": 2}, {"id": 3}],
        )

    def test_empty_output(self):
        self.assertEqual(md.parse_paginated(""), [])

    def test_bad_output_raises(self):
        with self.assertRaises(md.ForgeError):
            md.parse_paginated("[{")
        with self.assertRaises(md.ForgeError):
            md.parse_paginated('{"message":"Not Found"}')


class CliTest(unittest.TestCase):
    def run_main(self, argv):
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            try:
                code = md.main(argv)
            except SystemExit as exc:
                code = exc.code
        return code, out.getvalue(), err.getvalue()

    def test_json_output(self):
        code, out, _ = self.run_main(["--fixture", FIXTURE])
        self.assertEqual(code, 0)
        report = json.loads(out)
        self.assertEqual(report["schema"], md.OUTPUT_SCHEMA)
        self.assertEqual(len(report["candidates"]), 3)

    def test_markdown_output(self):
        code, out, _ = self.run_main(["--fixture", FIXTURE, "--format", "markdown"])
        self.assertEqual(code, 0)
        self.assertIn("| `rex-101-aaaaaaaa` |", out)
        self.assertIn("Hakim CHANGES REQUESTED", out)

    def test_missing_fixture_is_a_clean_error(self):
        code, _, err = self.run_main(
            ["--fixture", os.path.join(HERE, "no-such-file.json")]
        )
        self.assertEqual(code, 1)
        self.assertIn("cannot read fixture", err)

    def test_usage_errors(self):
        self.assertEqual(self.run_main([])[0], 2)
        self.assertEqual(self.run_main(["--repo", "not a repo"])[0], 2)
        self.assertEqual(self.run_main(["--fixture", FIXTURE, "--limit", "0"])[0], 2)


if __name__ == "__main__":
    unittest.main()
