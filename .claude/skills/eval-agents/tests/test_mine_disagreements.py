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

    def test_deciding_text_must_start_with_verdict(self):
        cases = [
            ("No blocking findings remain.", None),
            ("**No blocking findings.**", None),
            ("✅ APPROVED", md.APPROVED),
            ("Verdict: APPROVED", md.APPROVED),
            ("NOT APPROVED", md.CHANGES_REQUESTED),
            ("APPROVED. Next action: reply", md.APPROVED),
            ("**Verdict: APPROVED.** more text", md.APPROVED),
            ("No findings.\n**BLOCKING**", None),
        ]
        for text, expected in cases:
            with self.subTest(text=text):
                self.assertEqual(md.parse_verdict("### Verdict\n" + text + "\n")[0], expected)

    def test_excerpt_is_capped(self):
        body = "### Verdict\n**APPROVED**\n" + ("word " * 400)
        self.assertLessEqual(len(md.parse_verdict(body)[1]), md.EXCERPT_LIMIT)


class ReviewedCommitTest(unittest.TestCase):
    FULL = "0123456789abcdef0123456789abcdef01234567"
    LATER = "fedcba9876543210fedcba9876543210fedcba98"

    def test_body_footer_wins_over_api(self):
        body = "Reviewed commit: `{}`".format(self.FULL)
        self.assertEqual(md.reviewed_commit(body, self.LATER), self.FULL)

    def test_short_body_sha_wins_over_api(self):
        body = "**Commit**: `{}`".format(self.FULL[:8])
        self.assertEqual(md.reviewed_commit(body, self.FULL), self.FULL[:8])

    def test_api_fallback(self):
        self.assertEqual(
            md.reviewed_commit("no sha here", self.FULL.upper()), self.FULL
        )

    def test_body_fallback_without_api_commit(self):
        body = "Last reviewed commit: `{}`\nReviewed commit: `{}`".format(
            self.LATER, self.FULL[:8]
        )
        for api in (None, ""):
            self.assertEqual(md.reviewed_commit(body, api), self.FULL[:8])
        self.assertEqual(md.reviewed_commit("**Commit**: `abcdef01`", None), "abcdef01")
        self.assertIsNone(md.reviewed_commit("Last reviewed commit: `abcdef01`", None))

    def test_commit_line_wins_over_footer_and_api(self):
        body = "Reviewed commit: `{}`\n**Commit**: `{}`".format(
            self.LATER, self.FULL[:8]
        )
        self.assertEqual(md.reviewed_commit(body, self.LATER), self.FULL[:8])

    def test_last_reviewed_commit_variants_are_excluded(self):
        for label in ("Last reviewed commit", "Last-reviewed commit"):
            with self.subTest(label=label):
                body = "{}: `{}`".format(label, self.LATER)
                self.assertIsNone(md.reviewed_commit(body, None))
                self.assertEqual(md.reviewed_commit(body, self.FULL), self.FULL)
                body += "\nReviewed commit: `{}`".format(self.FULL[:8])
                self.assertEqual(md.reviewed_commit(body, None), self.FULL[:8])

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

    def test_prefix_groups_use_longest_sha_in_either_order(self):
        full = "0123456789abcdef0123456789abcdef0123456789"
        for length in (7, 8):
            units = [
                self.unit("rex", md.APPROVED, full, "t2"),
                self.unit("hakim", md.CHANGES_REQUESTED, full[:length], "t1"),
            ]
            for ordered in (units, list(reversed(units))):
                with self.subTest(length=length, ordered=ordered):
                    groups = md.group_by_commit(ordered)
                    self.assertEqual(list(groups), [full])
                    self.assertEqual([u["submitted_at"] for u in groups[full]], ["t1", "t2"])

    def test_six_character_prefix_and_unrelated_shas_stay_apart(self):
        full = "0123456789abcdef0123456789abcdef0123456789"
        other = "abcdef0123456789abcdef0123456789abcdef01"
        units = [self.unit("rex", md.APPROVED, sha, "t1")
                 for sha in (full, full[:6], other)]
        self.assertEqual(set(md.group_by_commit(units)), {full, full[:6], other})

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
        pr = next(pr for pr in load_fixture()["prs"] if pr["number"] == 106)
        self.assertEqual(md.review_unit(pr["reviews"][1])["commit"], "1" * 40)
        self.assertIn(106, self.by_pr)

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


class EdgeCasesFixtureTest(unittest.TestCase):
    def setUp(self):
        path = os.path.join(HERE, "fixtures", "mine-disagreements", "edge-cases.json")
        with open(path, encoding="utf-8") as handle:
            self.data = json.load(handle)
        self.report = md.mine(self.data["repo"], self.data["prs"])

    def test_pr_1080_keeps_body_commit_candidate_after_newer_push(self):
        candidates = [c for c in self.report["candidates"] if c["draft_entry"]["pr"] == 1080]
        self.assertEqual([c["candidate_id"] for c in candidates], ["rex-1080-63177daa"])

    def test_pr_1292_does_not_join_reviews_on_api_commit(self):
        candidates = [c for c in self.report["candidates"] if c["draft_entry"]["pr"] == 1292]
        self.assertEqual(candidates, [])

    def test_rereview_uses_submission_commit(self):
        candidates = [c for c in self.report["candidates"] if c["draft_entry"]["pr"] == 201]
        self.assertEqual(len(candidates), 1)
        self.assertEqual(candidates[0]["evidence"]["commit"], "b" * 40)

    def test_prose_verdict_is_unknown_and_not_a_candidate(self):
        self.assertFalse(any(c["draft_entry"]["pr"] == 202 for c in self.report["candidates"]))
        self.assertEqual(self.report["unparsed_agent_reviews"], [{
            "pr": 202, "reviewer": "hakim",
            "url": self.data["prs"][1]["reviews"][1]["html_url"],
        }])

    def test_body_prefix_groups_with_full_api_sha(self):
        candidates = [c for c in self.report["candidates"] if c["draft_entry"]["pr"] == 203]
        self.assertEqual(len(candidates), 1)
        self.assertEqual(candidates[0]["evidence"]["commit"], "d" * 40)


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
