#!/usr/bin/env python3
"""mine_disagreements.py - propose candidate /eval-agents corpus entries.

Scans the reviews on merged pull requests and finds one disagreement shape:
the code reviewer (Rex) APPROVED a commit, and the security reviewer (Hakim)
or the design reviewer (Tariq) gave CHANGES REQUESTED or BLOCKING on the
identical commit. Each match is a candidate Rex MISS backed by the
`independent_review` oracle (AgDR-0089).

The reverse shape (Hakim or Tariq APPROVED, Rex CHANGES) is not mined. Rex's
remit is a superset of Hakim's (Rex also enforces the writing standard), so
that shape is mostly two reviewers doing their own jobs. See
me2resh/apexyard#1440 (2026-09-28 correction).

Guarantees:

- Read-only against the forge. The only forge calls are `gh pr list` and
  `gh api` GET requests.
- Never writes a corpus file. Output goes to stdout only.
- Output is a candidate, not an entry. Each draft omits
  `ground_truth_defects` and `recorded_verdict.was_justified`, so
  `validate-corpus.sh` rejects a raw paste. A human writes the defects from
  the linked review evidence.

Verdict extraction reads only the explicit verdict section of a review body:
a `### Verdict` heading (any heading level), or a `**Verdict**:` line when no
heading exists. It never greps the whole body, because recap prose such as
"all four blocking findings are fixed" produced false positives in the
#1440 probe.

Usage:
    mine_disagreements.py --repo OWNER/REPO [--limit N] [--format json|markdown]
    mine_disagreements.py --fixture FILE [--format json|markdown]

Exit codes: 0 success (zero candidates is success), 1 forge or input error,
2 usage error.

Python 3.9+, standard library only.
"""

from __future__ import annotations

import argparse
import datetime as _dt
import json
import re
import subprocess
import sys
from typing import Any, Dict, Iterable, List, Optional, Tuple

OUTPUT_SCHEMA = "eval-agents-candidates/1"

CODE_REVIEWER = "rex"
CHALLENGER_REVIEWERS = ("hakim", "tariq")

APPROVED = "APPROVED"
CHANGES_REQUESTED = "CHANGES REQUESTED"
BLOCKING = "BLOCKING"
COMMENT = "COMMENT"
CHANGES_CLASS = (CHANGES_REQUESTED, BLOCKING)

EXCERPT_LIMIT = 400
MIN_COMMIT_PREFIX = 7

# Reviewer identity comes from the body, not the GitHub author: every agent
# posts under one account. The section header is primary. The signature
# footer is the fallback.
_HEADER_PATTERNS: Tuple[Tuple[str, "re.Pattern[str]"], ...] = (
    ("rex", re.compile(r"^#{1,3}\s*Code Review\b", re.IGNORECASE | re.MULTILINE)),
    ("hakim", re.compile(r"^#{1,3}\s*Security Review\b", re.IGNORECASE | re.MULTILINE)),
    (
        "tariq",
        re.compile(
            r"^#{1,3}\s*(?:Design|Architecture) Review\b", re.IGNORECASE | re.MULTILINE
        ),
    ),
)
_FOOTER_PATTERN = re.compile(r"Reviewed by (Rex|Hakim|Tariq)\b", re.IGNORECASE)

_VERDICT_HEADING = re.compile(r"^\s*#{2,4}\s*Verdict\s*:?\s*$", re.IGNORECASE)
_ANY_HEADING = re.compile(r"^\s*#{1,6}\s")
_RULE_LINE = re.compile(r"^\s*(?:-{3,}|\*{3,}|_{3,})\s*$")
# Matches `**Verdict**: X` and `**Verdict: X.** more text`.
_VERDICT_LINE = re.compile(r"^\s*\*\*Verdict\b(.*)$", re.IGNORECASE)

# Order matters: the negated form must match before plain APPROVED.
_TOKEN_PATTERNS: Tuple[Tuple[str, "re.Pattern[str]"], ...] = (
    (CHANGES_REQUESTED, re.compile(r"\bNOT\s+APPROVED\b", re.IGNORECASE)),
    (CHANGES_REQUESTED, re.compile(r"\bCHANGES[\s_]+REQUESTED\b", re.IGNORECASE)),
    (CHANGES_REQUESTED, re.compile(r"\bREQUEST(?:ING)?[\s_]+CHANGES\b", re.IGNORECASE)),
    (BLOCKING, re.compile(r"\bBLOCK(?:ING|ED)\b", re.IGNORECASE)),
    (APPROVED, re.compile(r"\bAPPROVED?\b", re.IGNORECASE)),
    (COMMENT, re.compile(r"\bCOMMENT\b", re.IGNORECASE)),
)

_COMMIT_PATTERNS = (
    re.compile(r"\*\*Commit\*\*:\s*`?([0-9a-f]{7,40})`?", re.IGNORECASE),
    re.compile(r"(?<!last )(?<!last-)Reviewed commit:\s*`?([0-9a-f]{7,40})`?", re.IGNORECASE),
)


class ForgeError(RuntimeError):
    """A forge call failed or returned data the miner cannot read."""


# ---------------------------------------------------------------------------
# Parsing (pure functions)
# ---------------------------------------------------------------------------


def classify_reviewer(body: str) -> Optional[str]:
    """Return 'rex', 'hakim', or 'tariq' for a review body, else None.

    The earliest section header wins. The signature footer is the fallback.
    """
    if not body:
        return None
    best: Optional[Tuple[int, str]] = None
    for name, pattern in _HEADER_PATTERNS:
        match = pattern.search(body)
        if match and (best is None or match.start() < best[0]):
            best = (match.start(), name)
    if best is not None:
        return best[1]
    footer = _FOOTER_PATTERN.search(body)
    if footer:
        return footer.group(1).lower()
    return None


def verdict_sections(body: str) -> List[str]:
    """Return the text of every verdict section in a review body.

    A section starts at a `### Verdict` heading and ends at the next heading
    or horizontal rule. When the body has no such heading, each
    `**Verdict**:` line counts as a one-line section.
    """
    lines = (body or "").splitlines()
    sections: List[str] = []
    index = 0
    while index < len(lines):
        if _VERDICT_HEADING.match(lines[index]):
            index += 1
            collected: List[str] = []
            while index < len(lines):
                line = lines[index]
                if _ANY_HEADING.match(line) or _RULE_LINE.match(line):
                    break
                collected.append(line)
                index += 1
            sections.append("\n".join(collected).strip())
            continue
        index += 1
    if sections:
        return sections
    for line in lines:
        match = _VERDICT_LINE.match(line)
        if match:
            # Drop the bold markers so the first-sentence rule applies to the
            # verdict text, whichever side of the label the markers sit on.
            sections.append(match.group(1).replace("**", "").lstrip(" :").strip())
    return sections


def tokens_in(text: str) -> List[str]:
    """Return the distinct verdict classes named in one line, in rule order."""
    found: List[str] = []
    remaining = text
    for verdict, pattern in _TOKEN_PATTERNS:
        if pattern.search(remaining):
            if verdict not in found:
                found.append(verdict)
            # Remove the matched text so "NOT APPROVED" does not also count
            # as APPROVED.
            remaining = pattern.sub(" ", remaining)
    return found


def verdict_of_section(section: str) -> Optional[str]:
    """Return the verdict that one section states, or None.

    The first non-empty line decides and must start with a verdict token.
    CHANGES REQUESTED and BLOCKING on one line agree. A line that names two
    other verdicts (an unfilled template such as
    `[APPROVED / CHANGES REQUESTED / COMMENT]`) is ambiguous: return None.
    """
    for line in section.splitlines():
        if not line.strip():
            continue
        deciding = _deciding_text(line)
        if not any(pattern.match(deciding) for _, pattern in _TOKEN_PATTERNS):
            return None
        found = tokens_in(deciding)
        if len(found) > 1 and not all(verdict in CHANGES_CLASS for verdict in found):
            return None
        return found[0]
    return None


_BOLD = re.compile(r"\*\*(.+?)\*\*")
_SENTENCE_END = re.compile(r"[.;:!?](?:\s|$)")


def _deciding_text(line: str) -> str:
    """Return the part of a line that states the verdict.

    Bold text wins, so `**APPROVED** - no blocking findings` reads as
    APPROVED. Without bold text, only the first sentence counts, so
    `APPROVED. Next action: reply to the comment` reads as APPROVED.
    """
    bold = [segment for segment in _BOLD.findall(line) if segment.strip()]
    text = " ".join(bold) if bold else line
    text = re.sub(r"^[^a-zA-Z]+", "", text)
    text = re.sub(r"^Verdict\b\s*[:\-]\s*", "", text, flags=re.IGNORECASE)
    text = re.sub(r"^[^a-zA-Z]+", "", text)
    if bold:
        return text
    end = _SENTENCE_END.search(text)
    return text[: end.start()] if end else text


def parse_verdict(body: str) -> Tuple[Optional[str], str]:
    """Return (verdict, excerpt) for a review body.

    The verdict is None when no verdict section exists, a section names no
    verdict, or two sections disagree. The excerpt is the last verdict
    section, cut to EXCERPT_LIMIT characters.
    """
    sections = verdict_sections(body)
    if not sections:
        return None, ""
    verdicts = {verdict_of_section(section) for section in sections}
    excerpt = _excerpt(sections[-1])
    if len(verdicts) != 1:
        return None, excerpt
    return verdicts.pop(), excerpt


def reviewed_commit(body: str, api_commit: Optional[str]) -> Optional[str]:
    """Return the commit SHA that the review submission identifies.

    The body's `**Commit**:` line wins, followed by its `Reviewed commit:`
    footer. Use API `commit_id` only when the body names no commit.
    """
    for pattern in _COMMIT_PATTERNS:
        match = pattern.search(body or "")
        if match:
            return match.group(1).lower()
    return (api_commit or "").lower() or None


def _excerpt(text: str) -> str:
    text = text.strip()
    if len(text) <= EXCERPT_LIMIT:
        return text
    return text[: EXCERPT_LIMIT - 3].rstrip() + "..."


# ---------------------------------------------------------------------------
# Grouping and candidate detection (pure functions)
# ---------------------------------------------------------------------------


def review_unit(raw: Dict[str, Any]) -> Dict[str, Any]:
    """Turn one raw GitHub review object into a review unit."""
    body = raw.get("body") or ""
    verdict, excerpt = parse_verdict(body)
    return {
        "review_id": raw.get("id"),
        "reviewer": classify_reviewer(body),
        "verdict": verdict,
        "commit": reviewed_commit(body, raw.get("commit_id")),
        "submitted_at": raw.get("submitted_at"),
        "url": raw.get("html_url"),
        "verdict_excerpt": excerpt,
    }


def group_by_commit(units: Iterable[Dict[str, Any]]) -> Dict[str, List[Dict[str, Any]]]:
    """Group review units by reviewed commit SHA.

    Match prefixes of at least MIN_COMMIT_PREFIX characters to the longest
    SHA. Drop units without a reviewer, verdict, or commit. Sort each group
    by submission time.
    """
    valid = [
        unit
        for unit in units
        if unit["reviewer"] and unit["verdict"] and unit["commit"]
    ]
    commits = sorted({unit["commit"] for unit in valid}, key=lambda sha: (-len(sha), sha))
    keys: Dict[str, str] = {}
    for commit in commits:
        keys[commit] = next(
            (
                sha
                for sha in commits
                if len(commit) >= MIN_COMMIT_PREFIX and sha.startswith(commit)
            ),
            commit,
        )
    groups: Dict[str, List[Dict[str, Any]]] = {}
    for unit in valid:
        groups.setdefault(keys[unit["commit"]], []).append(unit)
    for members in groups.values():
        members.sort(key=lambda unit: unit.get("submitted_at") or "")
    return groups


def find_candidates(
    repo: str, pr: Dict[str, Any], units: List[Dict[str, Any]]
) -> List[Dict[str, Any]]:
    """Return one candidate for each commit that has the mined shape.

    The shape: at least one Rex APPROVED unit and at least one Hakim or
    Tariq unit with CHANGES REQUESTED or BLOCKING, on the same commit.
    Order does not matter: a parallel review is as valid an oracle as a
    later one.
    """
    candidates: List[Dict[str, Any]] = []
    for commit, members in sorted(group_by_commit(units).items()):
        approvals = [
            unit
            for unit in members
            if unit["reviewer"] == CODE_REVIEWER and unit["verdict"] == APPROVED
        ]
        challenges = [
            unit
            for unit in members
            if unit["reviewer"] in CHALLENGER_REVIEWERS
            and unit["verdict"] in CHANGES_CLASS
        ]
        if approvals and challenges:
            candidates.append(
                build_candidate(repo, pr, commit, members, approvals, challenges)
            )
    return candidates


def build_candidate(
    repo: str,
    pr: Dict[str, Any],
    commit: str,
    members: List[Dict[str, Any]],
    approvals: List[Dict[str, Any]],
    challenges: List[Dict[str, Any]],
) -> Dict[str, Any]:
    """Shape one candidate: a partial corpus draft plus evidence links."""
    number = pr["number"]
    short = commit[:8]
    challengers = sorted({unit["reviewer"] for unit in challenges})
    challenger_names = " and ".join(name.capitalize() for name in challengers)
    later_rex = [
        unit
        for unit in members
        if unit["reviewer"] == CODE_REVIEWER and unit["verdict"] != APPROVED
    ]
    return {
        "candidate_id": "{}-{}-{}".format(CODE_REVIEWER, number, short),
        "target_corpus": "{}.json".format(CODE_REVIEWER),
        "direction": "{} APPROVED -> {} CHANGES".format(
            CODE_REVIEWER.capitalize(), challenger_names
        ),
        "draft_entry": {
            "id": "{}-{}-{}".format(CODE_REVIEWER, number, short),
            "pr": number,
            "repo": repo,
            "commit": short,
            "diff_range": "{}~1..{}".format(short, short),
            "oracle": {
                "source": "independent_review",
                "established_by": (
                    "{}'s review of the identical commit returned a changes verdict "
                    "after or beside Rex's approval. Confirm the finding before "
                    "you promote this entry."
                ).format(challenger_names),
                "reference": "{}#{}".format(repo, number),
            },
            "recorded_verdict": {"verdict": APPROVED},
        },
        "adjudication_required": [
            "Confirm the challenger's finding is a real defect in the diff at this commit.",
            "Confirm the finding is inside Rex's review scope.",
            "Write ground_truth_defects from the challenger's evidence, not from the summary.",
            "Set recorded_verdict.was_justified (false for a confirmed miss).",
        ],
        "evidence": {
            "pr_url": pr.get("url"),
            "commit": commit,
            "approvals": [_evidence(unit) for unit in approvals],
            "challenges": [_evidence(unit) for unit in challenges],
            "rex_non_approvals_same_commit": [_evidence(unit) for unit in later_rex],
        },
    }


def _evidence(unit: Dict[str, Any]) -> Dict[str, Any]:
    return {
        "reviewer": unit["reviewer"],
        "verdict": unit["verdict"],
        "submitted_at": unit["submitted_at"],
        "url": unit["url"],
        "verdict_excerpt": unit["verdict_excerpt"],
    }


def mine(repo: str, prs: List[Dict[str, Any]]) -> Dict[str, Any]:
    """Mine a list of PRs, each with its raw reviews, into a report."""
    candidates: List[Dict[str, Any]] = []
    review_units = 0
    attributed = 0
    unparsed: List[Dict[str, Any]] = []
    for pr in prs:
        units = [review_unit(raw) for raw in pr.get("reviews", [])]
        for unit in units:
            if not unit["reviewer"]:
                continue
            attributed += 1
            if not unit["verdict"]:
                unparsed.append(
                    {
                        "pr": pr["number"],
                        "reviewer": unit["reviewer"],
                        "url": unit["url"],
                    }
                )
        review_units += len(units)
        candidates.extend(find_candidates(repo, pr, units))
    return {
        "schema": OUTPUT_SCHEMA,
        "repo": repo,
        "direction": "Rex APPROVED -> Hakim or Tariq CHANGES REQUESTED / BLOCKING, same commit",
        "note": (
            "Candidates only. Nothing here is a corpus entry until a human adjudicates it. "
            "This tool never writes docs/eval-agents/corpus/."
        ),
        "scanned": {
            "prs": len(prs),
            "reviews": review_units,
            "agent_reviews": attributed,
            "agent_reviews_without_verdict": len(unparsed),
        },
        "unparsed_agent_reviews": unparsed,
        "candidates": candidates,
    }


# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------


def render_markdown(report: Dict[str, Any]) -> str:
    """Render a report as a Markdown table for a human adjudicator."""
    scanned = report["scanned"]
    lines = [
        "# Candidate eval-corpus entries - {}".format(report["repo"]),
        "",
        "Direction: {}.".format(report["direction"]),
        "",
        report["note"],
        "",
        "Scanned {} merged PRs, {} reviews, {} agent reviews. "
        "{} agent reviews had no readable verdict section.".format(
            scanned["prs"],
            scanned["reviews"],
            scanned["agent_reviews"],
            scanned["agent_reviews_without_verdict"],
        ),
        "",
    ]
    if not report["candidates"]:
        lines.append("No candidates found.")
        return "\n".join(lines) + "\n"
    lines.extend(
        [
            "| Candidate | PR | Commit | Rex approval | Challenge | Challenge verdict text |",
            "|---|---|---|---|---|---|",
        ]
    )
    for candidate in report["candidates"]:
        evidence = candidate["evidence"]
        approval = evidence["approvals"][0]
        for challenge in evidence["challenges"]:
            lines.append(
                "| `{}` | [#{}]({}) | `{}` | [{}]({}) | [{} {}]({}) | {} |".format(
                    candidate["candidate_id"],
                    candidate["draft_entry"]["pr"],
                    evidence["pr_url"] or "",
                    evidence["commit"][:8],
                    approval["submitted_at"] or "review",
                    approval["url"] or "",
                    challenge["reviewer"].capitalize(),
                    challenge["verdict"],
                    challenge["url"] or "",
                    _table_cell(challenge["verdict_excerpt"]),
                )
            )
    lines.append("")
    return "\n".join(lines) + "\n"


def _table_cell(text: str) -> str:
    return " ".join(text.split()).replace("|", "\\|")


# ---------------------------------------------------------------------------
# Forge access (read-only gh calls)
# ---------------------------------------------------------------------------


def _run_gh(args: List[str]) -> str:
    try:
        proc = subprocess.run(
            ["gh"] + args, capture_output=True, text=True, timeout=120, check=False
        )
    except FileNotFoundError as exc:
        raise ForgeError("gh CLI not found on PATH") from exc
    except subprocess.TimeoutExpired as exc:
        raise ForgeError("gh {} timed out".format(" ".join(args[:2]))) from exc
    if proc.returncode != 0:
        raise ForgeError(
            "gh {} failed (exit {}): {}".format(
                " ".join(args[:2]), proc.returncode, proc.stderr.strip()
            )
        )
    return proc.stdout


def parse_paginated(text: str) -> List[Any]:
    """Parse `gh api --paginate` output: one JSON array per page, back to back."""
    decoder = json.JSONDecoder()
    items: List[Any] = []
    index = 0
    text = text.strip()
    while index < len(text):
        while index < len(text) and text[index].isspace():
            index += 1
        if index >= len(text):
            break
        try:
            page, index = decoder.raw_decode(text, index)
        except json.JSONDecodeError as exc:
            raise ForgeError("unreadable gh api output: {}".format(exc)) from exc
        if not isinstance(page, list):
            raise ForgeError("gh api page is not a JSON array")
        items.extend(page)
    return items


def fetch_prs(repo: str, limit: int) -> List[Dict[str, Any]]:
    """Fetch the most recent merged PRs and their reviews. GET calls only."""
    listing = _run_gh(
        [
            "pr",
            "list",
            "--repo",
            repo,
            "--state",
            "merged",
            "--limit",
            str(limit),
            "--json",
            "number,url",
        ]
    )
    try:
        prs = json.loads(listing or "[]")
    except json.JSONDecodeError as exc:
        raise ForgeError("unreadable gh pr list output: {}".format(exc)) from exc
    result: List[Dict[str, Any]] = []
    for pr in prs:
        number = int(pr["number"])
        reviews = parse_paginated(
            _run_gh(
                [
                    "api",
                    "--method",
                    "GET",
                    "--paginate",
                    "repos/{}/pulls/{}/reviews".format(repo, number),
                ]
            )
        )
        result.append({"number": number, "url": pr.get("url"), "reviews": reviews})
    return result


def load_fixture(path: str) -> Tuple[str, List[Dict[str, Any]]]:
    """Load an offline input file: {"repo": "...", "prs": [{number, url, reviews}]}."""
    try:
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, json.JSONDecodeError) as exc:
        raise ForgeError("cannot read fixture {}: {}".format(path, exc)) from exc
    if (
        not isinstance(data, dict)
        or "repo" not in data
        or not isinstance(data.get("prs"), list)
    ):
        raise ForgeError(
            "fixture {} needs a 'repo' string and a 'prs' list".format(path)
        )
    return data["repo"], data["prs"]


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

_REPO_PATTERN = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Propose candidate /eval-agents corpus entries from cross-agent review "
            "disagreements (Rex APPROVED, Hakim or Tariq CHANGES, same commit). "
            "Read-only. Prints to stdout."
        )
    )
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--repo", help="owner/repo to scan with the gh CLI")
    source.add_argument("--fixture", help="offline input file (used by the tests)")
    parser.add_argument(
        "--limit",
        type=int,
        default=60,
        help="number of recent merged PRs to scan (default 60)",
    )
    parser.add_argument("--format", choices=("json", "markdown"), default="json")
    args = parser.parse_args(argv)

    if args.limit < 1:
        parser.error("--limit must be 1 or more")
    if args.repo and not _REPO_PATTERN.match(args.repo):
        parser.error("--repo must look like owner/repo")

    try:
        if args.fixture:
            repo, prs = load_fixture(args.fixture)
        else:
            repo, prs = args.repo, fetch_prs(args.repo, args.limit)
        report = mine(repo, prs)
    except ForgeError as exc:
        print("mine_disagreements: {}".format(exc), file=sys.stderr)
        return 1

    report["generated_at"] = _dt.datetime.now(_dt.timezone.utc).strftime(
        "%Y-%m-%dT%H:%M:%SZ"
    )
    if args.format == "markdown":
        sys.stdout.write(render_markdown(report))
    else:
        sys.stdout.write(json.dumps(report, indent=2) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
