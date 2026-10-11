#!/usr/bin/env python3
"""token-cost: report the token and time cost of a Claude Code session.

One script, three views (me2resh/apexyard#1624, plan-apexyard-token-efficiency o1):

  session    the main-loop transcript: context tokens per turn, context share
             by category, skill injections, compactions, main-loop cache
             rebuilds during a CI wait, cache TTL.
  reviewers  the subagent transcripts: per reviewer and per review, the
             first-turn context, total tokens, cache-read tokens, tool calls,
             CI-wait turns, cache rebuilds, resume rebuilds and cache TTL.
  forge      merged PRs of me2resh/apexyard: Rex rounds per PR, hours from
             open to merge, refresh rounds and records PRs.

  report     all three views in one JSON or Markdown document.
  compare    the relative change of each metric between two JSON reports.

The script reads local files and, for the forge view, the GitHub CLI. It
writes nothing except the output it prints (or the --save file of the forge
view). It never prints transcript text or local paths. See
docs/perf/token-cost.md for usage and the counting rules.

Python 3.9 or later, standard library only.
"""

import argparse
import datetime
import glob
import hashlib
import json
import os
import re
import statistics
import subprocess
import sys

FORGE_REPO = "me2resh/apexyard"
REVIEWER_TYPES = ("code-reviewer", "security-reviewer", "solution-architect")
REVIEWER_NAMES = {
    "code-reviewer": "Rex",
    "security-reviewer": "Hakim",
    "solution-architect": "Tariq",
}
IMAGE_TOKENS = 1600  # Estimate per image; base64 bytes are not counted.
NEAR_CAP_TOKENS = 950000  # A compaction with preTokens at or above this is "near the cap".
LONG_WAIT_SECONDS = 300  # A wait of this length or more can expire a 5-minute cache.

# A command polls CI when it reads check or run status, or watches it.
CI_POLL_RE = re.compile(
    r"gh\s+pr\s+checks|gh\s+run\s+(?:watch|view|list)"
    r"|gh\s+api\s+\S*(?:check-runs|check-suites|/status\b|/actions/runs)",
    re.I,
)
CI_WATCH_RE = re.compile(r"gh\s+pr\s+checks\b[^\n;&|]*--watch|gh\s+run\s+watch", re.I)
SLEEP_RE = re.compile(r"(?:^|[\s;&|(])sleep\s+\d+", re.I)
BARE_SLEEP_RE = re.compile(r"^\s*sleep\s+\d+[smh]?\s*$", re.I)
CI_GREEN_RE = re.compile(
    r"\bgreen\b|CI (?:is )?(?:now )?(?:green|passed|complete)"
    r"|checks (?:are )?(?:all )?(?:green|passing|passed)",
    re.I,
)
CI_GREEN_EXCLUDE_RE = re.compile(r"fix|commit|delta|re-review", re.I)


# --------------------------------------------------------------------------
# Generic helpers
# --------------------------------------------------------------------------


def parse_ts(value):
    """Return a timezone-aware datetime for an ISO-8601 string, or None."""
    if not value or not isinstance(value, str):
        return None
    text = value.strip().replace("Z", "+00:00")
    try:
        parsed = datetime.datetime.fromisoformat(text)
    except ValueError:
        # Python 3.9 accepts at most 6 fractional digits.
        match = re.match(r"^(.*?\.\d{6})\d*(.*)$", text)
        if not match:
            return None
        try:
            parsed = datetime.datetime.fromisoformat(match.group(1) + match.group(2))
        except ValueError:
            return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=datetime.timezone.utc)
    return parsed


def percentile(sorted_values, q):
    """Nearest-rank percentile on an ascending list (index floor(q * n))."""
    if not sorted_values:
        return 0
    index = min(len(sorted_values) - 1, int(q * len(sorted_values)))
    return sorted_values[index]


def median(values):
    return statistics.median(values) if values else 0


def mean(values):
    return sum(values) / len(values) if values else 0


def utf8_len(value):
    if not isinstance(value, str):
        value = json.dumps(value if value is not None else "")
    return len(value.encode("utf-8"))


def est_tokens(nbytes):
    return int(round(nbytes / 4.0))


def as_dict(value):
    """Return value when it is a JSON object, else an empty dict (wrong type = missing)."""
    return value if isinstance(value, dict) else {}


def as_list(value):
    """Return value when it is a JSON array, else an empty list (wrong type = missing)."""
    return value if isinstance(value, list) else []


def text_of(content):
    """Plain text of a message content (string or list of blocks)."""
    if content is None:
        return ""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for block in content:
            if isinstance(block, str):
                parts.append(block)
            elif isinstance(block, dict) and block.get("type") == "text":
                parts.append(block.get("text") or "")
        return "\n".join(parts)
    return ""


class Window:
    """A time window. Records outside it are not counted."""

    def __init__(self, since=None, until=None):
        self.since = parse_ts(since) if since else None
        self.until = parse_ts(until) if until else None
        if since and self.since is None:
            raise ValueError("invalid --since timestamp: %s" % since)
        if until and self.until is None:
            raise ValueError("invalid --until timestamp: %s" % until)

    def contains(self, ts):
        if ts is None:
            return True
        if self.since and ts < self.since:
            return False
        if self.until and ts > self.until:
            return False
        return True

    def after(self, ts):
        return bool(ts is not None and self.until and ts > self.until)


def iter_records(path, window, digest=None):
    """Yield (record, timestamp) for each JSON line inside the window.

    A record without a timestamp takes the timestamp of the record before it.
    When digest is given, it receives the file bytes up to the end of the
    last line inside the window, so the hash identifies the measured prefix.
    """
    last_ts = None
    pending = []
    with open(path, "rb") as handle:
        for raw in handle:
            try:
                record = json.loads(raw)
            except ValueError:
                record = None
            if isinstance(record, dict):
                ts = parse_ts(record.get("timestamp")) or last_ts
                if record.get("timestamp"):
                    last_ts = ts
            else:
                ts = last_ts
            if digest is not None:
                pending.append(raw)
            if window.after(ts):
                continue
            if digest is not None:
                for chunk in pending:
                    digest.update(chunk)
                pending = []
            if not isinstance(record, dict):
                continue
            if not window.contains(ts):
                continue
            yield record, ts


def usage_numbers(usage):
    """Return (input, cache_creation, cache_read, output, eph_5m, eph_1h)."""
    if not isinstance(usage, dict):
        usage = {}

    def get(src, key):
        value = src.get(key)
        return value if isinstance(value, (int, float)) else 0

    inp = get(usage, "input_tokens")
    cc = get(usage, "cache_creation_input_tokens")
    cr = get(usage, "cache_read_input_tokens")
    out = get(usage, "output_tokens")
    if inp + cc + cr + out == 0 and isinstance(usage.get("iterations"), list):
        for item in usage["iterations"]:
            if isinstance(item, dict):
                inp += get(item, "input_tokens")
                cc += get(item, "cache_creation_input_tokens")
                cr += get(item, "cache_read_input_tokens")
                out += get(item, "output_tokens")
    creation = usage.get("cache_creation") or {}
    eph5 = get(creation, "ephemeral_5m_input_tokens") if isinstance(creation, dict) else 0
    eph1 = get(creation, "ephemeral_1h_input_tokens") if isinstance(creation, dict) else 0
    return inp, cc, cr, out, eph5, eph1


class Request:
    """One API request: all assistant records that share a message id."""

    __slots__ = ("mid", "ts", "inp", "cc", "cr", "out", "eph5", "eph1", "tools", "user_before")

    def __init__(self, mid, ts):
        self.mid = mid
        self.ts = ts
        self.inp = self.cc = self.cr = self.out = self.eph5 = self.eph1 = 0
        self.tools = []  # list of (tool_use_id, name, input)
        self.user_before = ""

    def set_usage(self, usage):
        nums = usage_numbers(usage)
        if sum(nums[:4]) == 0 and (self.inp + self.cc + self.cr + self.out) > 0:
            return
        self.inp, self.cc, self.cr, self.out, self.eph5, self.eph1 = nums

    @property
    def context(self):
        return self.inp + self.cc + self.cr

    @property
    def uncached(self):
        return self.inp + self.cc + self.out

    def is_rebuild(self):
        """Counting rule: cache-creation tokens exceed half the input tokens."""
        total = self.context
        return total > 0 and self.cc > 0.5 * total


def tool_command(name, tool_input):
    if not isinstance(tool_input, dict):
        return ""
    if name in ("Bash", "Monitor"):
        for key in ("command", "until", "condition"):
            value = tool_input.get(key)
            if isinstance(value, str) and value:
                return value
    return ""


def ci_call_kind(name, tool_input):
    """Return None, 'check', 'watch', 'poll' or 'sleep' for one tool call."""
    cmd = tool_command(name, tool_input)
    if not cmd:
        return None
    if CI_WATCH_RE.search(cmd) and CI_POLL_RE.search(cmd):
        return "watch"
    if CI_POLL_RE.search(cmd):
        if SLEEP_RE.search(cmd) or name == "Monitor":
            return "poll"
        if re.search(r"gh\s+pr\s+checks", cmd, re.I):
            return "check"
        return "poll"
    if name == "Bash" and BARE_SLEEP_RE.match(cmd):
        return "sleep"
    return None


def ci_wait_turns(requests, exempt_first_check=True):
    """Return the list of (index, kind) for CI-wait turns.

    Counting rule: a CI-wait turn is a turn whose only tool call polls CI
    status (a bare sleep counts as a poll). The first single `gh pr checks`
    of a run does not count. The first `gh pr checks` call of the run uses
    up this exemption in any turn shape, so a check in an opening batch of
    several tool calls makes a later lone check count.
    """
    result = []
    first_check_seen = not exempt_first_check
    for index, req in enumerate(requests):
        kinds = [ci_call_kind(name, tool_input) for _, name, tool_input in req.tools]
        exempt = False
        if not first_check_seen and "check" in kinds:
            first_check_seen = True
            exempt = True
        if len(kinds) != 1 or kinds[0] is None or exempt:
            continue
        result.append((index, kinds[0]))
    return result


# --------------------------------------------------------------------------
# Session view (main loop)
# --------------------------------------------------------------------------

_SKILL_BASE_RE = re.compile(r"Base directory for this skill: ([^\n]+)")
_COMMAND_NAME_RE = re.compile(r"<command-name>/?([^<]+)</command-name>")
_CLAUDE_MD_RE = re.compile(r"Contents of [^\n]*CLAUDE\.md")


def skill_name_from_body(text):
    match = _SKILL_BASE_RE.search(text)
    if match:
        return os.path.basename(match.group(1).strip().rstrip("/"))
    match = _COMMAND_NAME_RE.search(text)
    if match:
        return match.group(1).strip()
    return "unknown"


def classify_text(text):
    """Return (category, sub) for user-side text."""
    if "Base directory for this skill:" in text:
        return "skill-body", skill_name_from_body(text)
    if "The following skills were invoked EARLIER in this session" in text:
        return "skill-reinjection", "bundle"
    if text.startswith("(Re-invocation of /"):
        return "skill-reinvocation-stub", "stub"
    if "<command-name>" in text:
        return "slash-command-stub", skill_name_from_body(text)
    if _CLAUDE_MD_RE.search(text):
        return "claude-md", "inline"
    if "memory/MEMORY.md" in text:
        return "memory-index", "inline"
    if "<task-notification>" in text:
        return "task-notification", "task"
    if "Another Claude session sent a message" in text or "<agent-message" in text:
        return "agent-message", "message"
    if "The user hasn't heard from you in a while" in text or "Only you see that command's output" in text:
        return "harness-nudge", "inline"
    if text.startswith("[Image: "):
        return "image", "caption-text"
    if "<local-command-caveat>" in text or "<local-command-stdout>" in text:
        return "local-command", "stdout"
    if "<artifact-content-authored-by-others/>" in text:
        return "artifact-comment", "inbound"
    if "<bash-input>" in text:
        return "user-typed", "bash-passthrough"
    if text.startswith("[Usage limit") or text.startswith("[Earlier usage-limit"):
        return "harness-nudge", "usage-limit"
    if "[Cross-session delivery notice]" in text:
        return "harness-nudge", "delivery-notice"
    if "Skill /" in text and "was loaded earlier" in text:
        return "skill-reinvocation-stub", "loaded-earlier"
    if text.startswith("# Workflow authoring reference") or text.startswith("# /loop"):
        return "skill-body", ("loop" if text.startswith("# /loop") else "workflow-authoring")
    return "user-typed", "text"


_HARNESS_ATTACHMENTS = {
    "total_tokens_reminder", "silent_turn_reminder", "bash_output_audience_note",
    "batching_reminder_sent", "task_reminder", "skill_mention", "ultra_effort_enter",
    "edited_text_file", "diagnostics",
}
_POST_COMPACTION_ATTACHMENTS = {
    "deferred_tools_delta", "agent_listing_delta", "mcp_instructions_delta", "skill_listing",
    "model", "auto_mode", "auto_mode_exit", "remote_session_change", "session_context",
    "date", "credential_org", "plan_mode_exit", "environment",
}


def attachment_category(att_type, rendered):
    if att_type == "nested_memory":
        return "claude-md"
    if att_type == "hook_additional_context":
        return "hook-advisory"
    if att_type == "hook_blocking_error":
        return "hook-blocking-error"
    if att_type in ("hook_success", "hook_non_blocking_error"):
        return "hook-advisory"
    if att_type in _HARNESS_ATTACHMENTS:
        return "harness-nudge"
    if att_type == "queued_command":
        if "<task-notification>" in rendered:
            return "task-notification"
        if "<agent-message" in rendered:
            return "agent-message"
        return "queued-command"
    if att_type in _POST_COMPACTION_ATTACHMENTS:
        return "post-compaction-harness"
    if att_type in ("file", "compact_file_reference"):
        return "post-compaction-file-reinject"
    if att_type == "task_status":
        return "task-notification"
    return "attachment-other"


def rendered_text(record):
    rendered = record.get("rendered")
    if isinstance(rendered, list):
        return "\n".join(
            (item.get("content") or "") if isinstance(item, dict) else str(item) for item in rendered
        )
    if isinstance(rendered, str):
        return rendered
    return json.dumps(rendered)


def tracked_skills(repo_root):
    """Skill names tracked in the framework repo (git ls-files)."""
    try:
        out = subprocess.run(
            ["git", "-C", repo_root, "ls-files", ".claude/skills"],
            check=True, capture_output=True, text=True,
        ).stdout
    except (OSError, subprocess.CalledProcessError):
        return set()
    names = set()
    for line in out.splitlines():
        parts = line.split("/")
        if len(parts) >= 4 and parts[0] == ".claude" and parts[1] == "skills" and parts[3] == "SKILL.md":
            names.add(parts[2])
    return names


class Composition:
    """Context share by category, in context-turns (tokens x turns held)."""

    def __init__(self):
        self.tokens = {}
        self.chunks = {}
        self.context_turns = {}
        self._pend_tok = {}
        self._pend_tok_turn = {}

    def add(self, category, tokens, turn_at):
        self.tokens[category] = self.tokens.get(category, 0) + tokens
        self.chunks[category] = self.chunks.get(category, 0) + 1
        self._pend_tok[category] = self._pend_tok.get(category, 0) + tokens
        self._pend_tok_turn[category] = self._pend_tok_turn.get(category, 0) + tokens * turn_at

    def boundary(self, turn_index):
        for category, tok in self._pend_tok.items():
            held = tok * turn_index - self._pend_tok_turn.get(category, 0)
            self.context_turns[category] = self.context_turns.get(category, 0) + held
        self._pend_tok = {}
        self._pend_tok_turn = {}

    def result(self):
        total = sum(self.context_turns.values()) or 1
        rows = []
        for category in sorted(self.context_turns, key=lambda c: -self.context_turns[c]):
            rows.append({
                "category": category,
                "share_pct": round(100.0 * self.context_turns[category] / total, 2),
                "tokens_est": self.tokens.get(category, 0),
                "chunks": self.chunks.get(category, 0),
            })
        return rows


def measure_session(path, window, skills_tracked, digest=None):
    requests = {}
    order = []
    tool_names = {}
    comp = Composition()
    turn_index = 0
    compactions = []
    skill_bodies = {}
    skill_reinjections = {}
    banners = 0
    versions = set()
    turn_durations_ms = 0
    first_ts = last_ts = None
    compaction_turns = set()

    def skill_bucket(name):
        return name if name in skills_tracked else "other"

    def add_skill_body(name, nbytes):
        bucket = skill_bucket(name)
        entry = skill_bodies.setdefault(bucket, {"injections": 0, "bytes": 0})
        entry["injections"] += 1
        entry["bytes"] += nbytes

    for record, ts in iter_records(path, window, digest):
        if record.get("isSidechain") is True:
            continue
        if record.get("version"):
            versions.add(str(record["version"]))
        if ts is not None and record.get("timestamp"):
            first_ts = first_ts or ts
            last_ts = ts
        rtype = record.get("type")
        if rtype == "system":
            if record.get("subtype") == "compact_boundary":
                comp.boundary(turn_index)
                meta = as_dict(record.get("compactMetadata"))
                compactions.append({"pre": meta.get("preTokens") or 0, "post": meta.get("postTokens") or 0})
                compaction_turns.add(turn_index)
            elif record.get("subtype") == "turn_duration" and isinstance(record.get("durationMs"), (int, float)):
                turn_durations_ms += record["durationMs"]
            continue
        if rtype == "assistant":
            message = as_dict(record.get("message"))
            mid = message.get("id") if isinstance(message.get("id"), str) else None
            for block in as_list(message.get("content")):
                if not isinstance(block, dict):
                    continue
                if block.get("type") == "tool_use":
                    tool_names[block.get("id")] = block.get("name") or "unknown"
                    nbytes = utf8_len(json.dumps(block.get("input") or {}))
                    comp.add("assistant-output", est_tokens(nbytes), turn_index)
                    if mid:
                        req = requests.get(mid)
                        if req is not None:
                            req.tools.append((block.get("id"), block.get("name"), block.get("input") or {}))
                elif block.get("type") == "text":
                    comp.add("assistant-output", est_tokens(utf8_len(block.get("text") or "")), turn_index)
            if mid and mid not in requests:
                req = Request(mid, ts)
                req.set_usage(message.get("usage"))
                for block in as_list(message.get("content")):
                    if isinstance(block, dict) and block.get("type") == "tool_use":
                        req.tools.append((block.get("id"), block.get("name"), block.get("input") or {}))
                requests[mid] = req
                order.append(mid)
                turn_index += 1
            elif mid:
                requests[mid].set_usage(message.get("usage"))
            continue
        if rtype == "user":
            message = as_dict(record.get("message"))
            content = message.get("content")
            if record.get("isCompactSummary"):
                comp.add("compaction-summary", est_tokens(utf8_len(text_of(content))), turn_index)
                continue
            blocks = [content] if isinstance(content, str) else (content if isinstance(content, list) else [])
            for block in blocks:
                if isinstance(block, str):
                    text = block
                    category, sub = classify_text(text)
                elif isinstance(block, dict) and block.get("type") == "text":
                    text = block.get("text") or ""
                    category, sub = classify_text(text)
                elif isinstance(block, dict) and block.get("type") == "image":
                    comp.add("image", IMAGE_TOKENS, turn_index)
                    continue
                elif isinstance(block, dict) and block.get("type") == "tool_result":
                    name = tool_names.get(block.get("tool_use_id"), "unknown")
                    inner = block.get("content")
                    images = 0
                    if isinstance(inner, list):
                        parts = []
                        for item in inner:
                            if isinstance(item, dict) and item.get("type") == "text":
                                parts.append(item.get("text") or "")
                            elif isinstance(item, dict) and item.get("type") == "image":
                                images += 1
                            else:
                                parts.append(json.dumps(item))
                        text = "\n".join(parts)
                    elif isinstance(inner, str):
                        text = inner
                    else:
                        text = json.dumps(inner if inner is not None else "")
                    if re.match(r"^(?:PreToolUse|PostToolUse):[A-Za-z]+ hook", text) or text.startswith("Shell cwd was reset to"):
                        category = "hook-advisory"
                    else:
                        category = "tool-result:mcp" if name.startswith("mcp__") else "tool-result:" + name
                    comp.add(category, est_tokens(utf8_len(text)), turn_index)
                    if images:
                        comp.add("image", IMAGE_TOKENS * images, turn_index)
                    continue
                else:
                    continue
                comp.add(category, est_tokens(utf8_len(text)), turn_index)
                if category == "skill-body":
                    add_skill_body(sub, utf8_len(text))
            continue
        if rtype == "attachment" and "rendered" in record:
            att = as_dict(record.get("attachment"))
            att_type = att.get("type")
            if att_type == "instructions":
                for item in as_list(att.get("files")):
                    if not isinstance(item, dict):
                        continue
                    is_memory = item.get("type") == "AutoMem" or str(item.get("path") or "").endswith("MEMORY.md")
                    nbytes = utf8_len(item.get("content") or "") + 80
                    comp.add("memory-index" if is_memory else "claude-md", est_tokens(nbytes), turn_index)
                continue
            if att_type == "invoked_skills":
                for item in as_list(att.get("skills")):
                    if not isinstance(item, dict):
                        continue
                    bucket = skill_bucket(item.get("name") or "unknown")
                    nbytes = utf8_len(item.get("content") or "") + 60
                    comp.add("skill-reinjection", est_tokens(nbytes), turn_index)
                    entry = skill_reinjections.setdefault(bucket, {"reinjections": 0, "bytes": 0})
                    entry["reinjections"] += 1
                    entry["bytes"] += nbytes - 60
                continue
            text = rendered_text(record)
            if att_type == "hook_blocking_error" and "AUTO CODE REVIEW REQUIRED" in text:
                banners += 1
            comp.add(attachment_category(att_type, text), est_tokens(utf8_len(text)), turn_index)
    comp.boundary(turn_index)

    reqs = [requests[mid] for mid in order]
    contexts = sorted(r.context for r in reqs)
    totals = {
        "input": sum(r.inp for r in reqs),
        "cache_creation": sum(r.cc for r in reqs),
        "cache_read": sum(r.cr for r in reqs),
        "output": sum(r.out for r in reqs),
    }
    # Cache rebuilds after the first request. The first request after a
    # compaction boundary is counted apart, because compaction always rebuilds.
    rebuilds = 0
    rebuilds_after_compaction = 0
    for index, req in enumerate(reqs):
        if index == 0 or not req.is_rebuild():
            continue
        if index in compaction_turns:
            rebuilds_after_compaction += 1
        else:
            rebuilds += 1
    waits = ci_wait_turns(reqs, exempt_first_check=False)
    wait_rebuilds = 0
    for index, _ in waits:
        if index + 1 < len(reqs) and reqs[index + 1].is_rebuild() and (index + 1) not in compaction_turns:
            wait_rebuilds += 1
    skills_out = []
    for name in sorted(set(skill_bodies) | set(skill_reinjections),
                       key=lambda n: -(skill_bodies.get(n, {}).get("bytes", 0) + skill_reinjections.get(n, {}).get("bytes", 0))):
        body = skill_bodies.get(name, {"injections": 0, "bytes": 0})
        rein = skill_reinjections.get(name, {"reinjections": 0, "bytes": 0})
        skills_out.append({
            "skill": name,
            "injections": body["injections"],
            "mean_body_bytes": int(round(body["bytes"] / body["injections"])) if body["injections"] else 0,
            "compaction_reinjections": rein["reinjections"],
            "tokens_est": est_tokens(body["bytes"] + rein["bytes"]),
        })
    pre = [c["pre"] for c in compactions]
    post = [c["post"] for c in compactions]
    wall_s = (last_ts - first_ts).total_seconds() if first_ts and last_ts else 0
    return {
        "api_turns": len(reqs),
        "tokens": totals,
        "context_per_turn": {
            "mean": int(round(mean(contexts))),
            "p50": percentile(contexts, 0.5),
            "p90": percentile(contexts, 0.9),
            "p99": percentile(contexts, 0.99),
            "max": contexts[-1] if contexts else 0,
        },
        "compactions": {
            "count": len(compactions),
            "near_cap": sum(1 for p in pre if p >= NEAR_CAP_TOKENS),
            "mean_pre": int(round(mean(pre))),
            "mean_post": int(round(mean(post))),
        },
        "context_share_by_category": comp.result(),
        "skills": skills_out,
        "auto_code_review_banners": banners,
        "cache": {
            "rebuilds": rebuilds,
            "rebuilds_after_compaction": rebuilds_after_compaction,
            "ci_wait_turns": len(waits),
            "rebuilds_during_ci_wait": wait_rebuilds,
            "requests_with_1h_writes": sum(1 for r in reqs if r.eph1 > 0),
            "requests_with_5m_writes": sum(1 for r in reqs if r.eph5 > 0),
        },
        "time": {
            "wall_hours": round(wall_s / 3600.0, 2),
            "turn_duration_hours": round(turn_durations_ms / 3600000.0, 2),
        },
        "cli_versions": sorted(versions),
    }


# --------------------------------------------------------------------------
# Reviewer view (subagent transcripts)
# --------------------------------------------------------------------------


# A block by the reviewer mutation lock. The hook message is the only
# attribution: the text is fixed in block-reviewer-repo-mutation.sh.
HOOK_ERROR_RE = re.compile(r"\s*PreToolUse:\w+ hook error")
LOCK_BLOCK_RE = re.compile(r"BLOCKED: review-class agent (?:is read-only while an active review|cannot )")
SEGMENT_SPLIT_RE = re.compile(r"[;&|()\n]+")
# Git options that take their value as the next word.
GIT_VALUE_OPTIONS = {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path", "--config-env"}


def git_subcommands(command):
    """Return the git subcommand of each command segment, in order.

    The scan is a single pass over the words of each segment, so a command
    with hundreds of options costs linear time. A regular expression with a
    nested quantifier over the option list backtracks badly instead.
    """
    found = []
    for segment in SEGMENT_SPLIT_RE.split(command):
        words = segment.split()
        index = 0
        while index < len(words) and "=" in words[index] and not words[index].startswith("-"):
            index += 1  # a leading VAR=value assignment
        if index >= len(words) or words[index] != "git":
            continue
        index += 1
        while index < len(words) and words[index].startswith("-"):
            index += 2 if words[index] in GIT_VALUE_OPTIONS else 1
        if index < len(words):
            found.append(words[index])
    return found


def measure_lock_blocks(paths, window):
    """Count hook blocks that the reviewer lock caused, per kind and per day.

    Rule for combining counts across sessions: a block is one tool call, named
    by its tool_use id. Read every transcript of the sessions in the period
    (main loop and subagents), count each id once, and add the counts. A
    resumed session copies earlier records into a new file, so the same id can
    appear twice. The per-day view groups on the UTC date of the result.
    """
    seen = set()
    totals = {"total": 0, "git_commit": 0, "git_push": 0, "other": 0}
    by_day = {}
    files = 0
    for path in paths:
        files += 1
        commands = {}
        for record, ts in iter_records(path, window):
            message = as_dict(record.get("message"))
            content = message.get("content")
            if not isinstance(content, list):
                continue
            for block in content:
                if not isinstance(block, dict):
                    continue
                if block.get("type") == "tool_use":
                    commands[block.get("id")] = tool_command(block.get("name"), block.get("input"))
                elif block.get("type") == "tool_result" and block.get("is_error"):
                    text = text_of(block.get("content"))
                    if not HOOK_ERROR_RE.match(text) or not LOCK_BLOCK_RE.search(text):
                        continue
                    tool_id = block.get("tool_use_id")
                    if tool_id in seen:
                        continue
                    seen.add(tool_id)
                    command = commands.get(tool_id, "")
                    subcommands = git_subcommands(command)
                    if "commit" in subcommands:
                        kind = "git_commit"
                    elif "push" in subcommands:
                        kind = "git_push"
                    else:
                        kind = "other"
                    totals["total"] += 1
                    totals[kind] += 1
                    day = ts.strftime("%Y-%m-%d") if ts else "unknown"
                    entry = by_day.setdefault(day, {"total": 0, "git_commit": 0, "git_push": 0, "other": 0})
                    entry["total"] += 1
                    entry[kind] += 1
    totals["commit_or_push"] = totals["git_commit"] + totals["git_push"]
    return {"transcripts": files, "blocks": totals, "by_day": dict(sorted(by_day.items()))}


def find_subagent_files(directory):
    files = glob.glob(os.path.join(directory, "agent-*.jsonl"))
    files += glob.glob(os.path.join(directory, "workflows", "*", "agent-*.jsonl"))
    return sorted(files)


def agent_type_of(path):
    meta_path = path[: -len(".jsonl")] + ".meta.json"
    try:
        with open(meta_path, "r", encoding="utf-8") as handle:
            meta = json.load(handle)
    except (OSError, ValueError):
        return "unknown"
    if meta.get("isFork"):
        return "fork"
    return str(meta.get("agentType") or "unknown")


def is_hand_back(req):
    """A request ends a run when it has no tool call or calls SubagentHandback."""
    return not req.tools or any(name == "SubagentHandback" for _, name, _ in req.tools)


def measure_run(path, window):
    """Measure one subagent run. Return None when it starts outside the window."""
    requests = {}
    order = []
    results = {}  # tool_use_id -> result timestamp
    last_user_text = ""
    first_ts = last_ts = None
    started = False
    for record, ts in iter_records(path, Window(until=window.until.isoformat() if window.until else None)):
        if not started:
            if record.get("timestamp") is None:
                continue
            if window.since and ts is not None and ts < window.since:
                return None
            started = True
        if record.get("timestamp"):
            first_ts = first_ts or ts
            last_ts = ts
        rtype = record.get("type")
        if rtype == "user":
            content = as_dict(record.get("message")).get("content")
            if isinstance(content, list):
                for block in content:
                    if isinstance(block, dict) and block.get("type") == "tool_result":
                        results[block.get("tool_use_id")] = ts
            text = text_of(content)
            if text.strip():
                last_user_text = text
            continue
        if rtype != "assistant":
            continue
        message = as_dict(record.get("message"))
        mid = message.get("id") if isinstance(message.get("id"), str) else None
        if not mid:
            continue
        req = requests.get(mid)
        if req is None:
            req = Request(mid, ts)
            req.user_before = last_user_text
            last_user_text = ""
            requests[mid] = req
            order.append(mid)
        req.set_usage(message.get("usage"))
        for block in as_list(message.get("content")):
            if isinstance(block, dict) and block.get("type") == "tool_use":
                req.tools.append((block.get("id"), block.get("name"), block.get("input") or {}))
    reqs = [requests[mid] for mid in order]
    if not reqs:
        return None
    waits = ci_wait_turns(reqs, exempt_first_check=True)
    long_waits = 0
    long_wait_rebuilds = 0
    for index, _ in waits:
        tool_id = reqs[index].tools[0][0]
        done = results.get(tool_id)
        start = reqs[index].ts
        if done is None or start is None:
            continue
        if (done - start).total_seconds() >= LONG_WAIT_SECONDS:
            long_waits += 1
            if index + 1 < len(reqs) and reqs[index + 1].is_rebuild():
                long_wait_rebuilds += 1
    rebuilds = 0
    resumes = 0
    resume_rebuilds = 0
    resume_rebuilds_ci_green = 0
    for index, req in enumerate(reqs):
        if index == 0:
            continue
        rebuild = req.is_rebuild()
        if rebuild:
            rebuilds += 1
        if is_hand_back(reqs[index - 1]):
            # The previous request ended the run, so this request is a
            # resume after a hand-back.
            resumes += 1
            if rebuild:
                resume_rebuilds += 1
                msg = re.sub(r"\s+", " ", req.user_before)[:110]
                if CI_GREEN_RE.search(msg) and not CI_GREEN_EXCLUDE_RE.search(msg):
                    resume_rebuilds_ci_green += 1
    duration = (last_ts - first_ts).total_seconds() if first_ts and last_ts else 0
    return {
        "first_turn_context": reqs[0].context,
        "final_context": reqs[-1].context + reqs[-1].out,
        "total_tokens": sum(r.uncached for r in reqs),
        "cache_read_tokens": sum(r.cr for r in reqs),
        "requests": len(reqs),
        "tool_calls": sum(len(r.tools) for r in reqs),
        "ci_wait_turns": len(waits),
        "long_waits": long_waits,
        "long_wait_rebuilds": long_wait_rebuilds,
        "cache_rebuilds": rebuilds,
        "resumes": resumes,
        "resume_rebuilds": resume_rebuilds,
        "resume_rebuilds_ci_green": resume_rebuilds_ci_green,
        "ttl": "1h" if any(r.eph1 > 0 for r in reqs) else "5m",
        "duration_s": int(round(duration)),
    }


def summarize_runs(runs):
    if not runs:
        return {"runs": 0}
    first = [r["first_turn_context"] for r in runs]
    total = [r["total_tokens"] for r in runs]
    return {
        "runs": len(runs),
        "first_turn_context_median": int(median(first)),
        "first_turn_context_max": max(first),
        "total_tokens_sum": sum(total),
        "total_tokens_mean": int(round(mean(total))),
        "total_tokens_median": int(median(total)),
        "cache_read_tokens_sum": sum(r["cache_read_tokens"] for r in runs),
        "tool_calls_mean": round(mean([r["tool_calls"] for r in runs]), 1),
        "ci_wait_turns": sum(r["ci_wait_turns"] for r in runs),
        "runs_with_ci_wait": sum(1 for r in runs if r["ci_wait_turns"]),
        "long_waits": sum(r["long_waits"] for r in runs),
        "long_wait_rebuilds": sum(r["long_wait_rebuilds"] for r in runs),
        "cache_rebuilds": sum(r["cache_rebuilds"] for r in runs),
        "resume_rebuilds": sum(r["resume_rebuilds"] for r in runs),
        "resume_rebuilds_ci_green": sum(r["resume_rebuilds_ci_green"] for r in runs),
        "duration_hours": round(sum(r["duration_s"] for r in runs) / 3600.0, 2),
        "duration_median_s": int(median([r["duration_s"] for r in runs])),
    }


def measure_reviewers(directory, window, only_ids=None):
    by_type = {}
    rows = []
    for path in find_subagent_files(directory):
        agent_id = os.path.basename(path)[len("agent-"): -len(".jsonl")]
        if only_ids is not None and agent_id not in only_ids:
            continue
        run = measure_run(path, window)
        if run is None:
            continue
        run["type"] = agent_type_of(path)
        run["id"] = agent_id
        rows.append(run)
        by_type.setdefault(run["type"], []).append(run)
    reviewers = [r for r in rows if r["type"] in REVIEWER_TYPES]
    total_runs = len(reviewers)
    non_ping = sum(r["resume_rebuilds"] - r["resume_rebuilds_ci_green"] for r in reviewers)
    per_reviewer = {}
    for agent_type in REVIEWER_TYPES:
        runs = by_type.get(agent_type, [])
        entry = summarize_runs(runs)
        entry["by_ttl"] = {
            ttl: summarize_runs([r for r in runs if r["ttl"] == ttl]) for ttl in ("5m", "1h")
        }
        per_reviewer[REVIEWER_NAMES[agent_type]] = entry
    others = {t: summarize_runs(v) for t, v in sorted(by_type.items()) if t not in REVIEWER_TYPES}
    all_rev = summarize_runs(reviewers)
    return {
        "reviewer_runs": total_runs,
        "all_reviewers": all_rev,
        "all_reviewers_by_ttl": {ttl: summarize_runs([r for r in reviewers if r["ttl"] == ttl]) for ttl in ("5m", "1h")},
        "per_reviewer": per_reviewer,
        "resume_rebuilds_per_100_runs": round(100.0 * non_ping / total_runs, 2) if total_runs else 0,
        "resume_rebuilds_excluding_ci_green": non_ping,
        "other_agents": others,
        "runs": [
            {k: r[k] for k in ("id", "type", "ttl", "first_turn_context", "total_tokens", "cache_read_tokens",
                               "tool_calls", "ci_wait_turns", "cache_rebuilds", "resume_rebuilds", "duration_s")}
            for r in reviewers
        ],
    }


# --------------------------------------------------------------------------
# Forge view (me2resh/apexyard only)
# --------------------------------------------------------------------------

_REVIEWER_HEADINGS = (
    ("Rex", re.compile(r"^## Code Review", re.M)),
    ("Hakim", re.compile(r"^## Security Review", re.M)),
    ("Tariq", re.compile(r"^## Design Review", re.M)),
)


def reviewer_of(body):
    for name, pattern in _REVIEWER_HEADINGS:
        if pattern.search(body or ""):
            return name
    return None


def verdict_of(body):
    match = re.search(r"verdict(?: is|:)\s*\**\s*(CHANGES REQUESTED|APPROVED|COMMENT)", body[:1500], re.I)
    if match:
        return match.group(1).upper().replace(" ", "_")
    first = body.strip().split("\n", 1)[0].upper()
    if "CHANGES REQUESTED" in first:
        return "CHANGES_REQUESTED"
    if "APPROVED" in first:
        return "APPROVED"
    head = body[:600].upper()
    if "CHANGES REQUESTED" in head:
        return "CHANGES_REQUESTED"
    if "APPROVED" in head:
        return "APPROVED"
    return "COMMENT"


def is_base_merge(commit, base, pr_oids):
    """A base merge is a merge commit with a parent outside the PR commits.

    When the commit has no parent list (older saved data), a merge headline
    that names the base branch is used instead.
    """
    parents = commit.get("parents")
    if isinstance(parents, list):
        return len(parents) >= 2 and any(p not in pr_oids for p in parents)
    pattern = r"^Merge\s+(?:remote-tracking\s+)?(?:branch\s+)?'?(?:(?:origin|upstream)[/ ])?%s'?(?:\s|$)" % re.escape(base)
    return bool(re.match(pattern, commit.get("messageHeadline") or ""))


def is_records_pr(paths):
    """Records PR: every file is under docs/orbit/, with or without one AgDR."""
    if not paths:
        return False
    agdrs = [p for p in paths if re.match(r"^docs/agdr/AgDR-[^/]+\.md$", p)]
    rest = [p for p in paths if p not in agdrs]
    return len(agdrs) <= 1 and bool(rest) and all(p.startswith("docs/orbit/") for p in rest)


def analyze_pr(pr):
    base = pr.get("baseRefName") or "dev"
    commits = pr.get("commits") or []
    oids = [c.get("oid") for c in commits]
    pr_oids = set(oids)
    index_of = {oid: i for i, oid in enumerate(oids)}
    dated = [(parse_ts(c.get("committedDate")), c.get("oid")) for c in commits]

    def head_at(when):
        best = None
        for stamp, oid in dated:
            if stamp is not None and when is not None and stamp <= when:
                best = oid
        return best or (oids[-1] if oids else None)

    posts = []
    for review in pr.get("reviews") or []:
        body = review.get("body") or ""
        name = reviewer_of(body)
        if not name:
            continue
        head = (review.get("commit") or {}).get("oid")
        posts.append((parse_ts(review.get("submittedAt")), name, verdict_of(body), head))
    for comment in pr.get("comments") or []:
        body = comment.get("body") or ""
        name = reviewer_of(body)
        if not name:
            continue
        when = parse_ts(comment.get("createdAt"))
        posts.append((when, name, verdict_of(body), head_at(when)))
    posts.sort(key=lambda p: p[0] or datetime.datetime.min.replace(tzinfo=datetime.timezone.utc))

    rounds = {"Rex": [], "Hakim": [], "Tariq": []}
    seen = set()
    for when, name, verdict, head in posts:
        key = (name, head, verdict)
        if key in seen:
            continue  # Counting rule: one verdict on one head commit is one round.
        seen.add(key)
        rounds[name].append((when, verdict, head))

    # Refresh events and pure-refresh rounds. A refresh round is a Rex round
    # on a head that differs from the approved head only by a base merge.
    approved = None
    refresh_heads = set()
    pure_refresh_rounds = 0
    for _when, verdict, head in rounds["Rex"]:
        if approved is not None and head != approved and head in index_of and approved in index_of:
            between = commits[index_of[approved] + 1: index_of[head] + 1]
            if between and all(is_base_merge(c, base, pr_oids) for c in between):
                pure_refresh_rounds += 1
        if verdict == "APPROVED":
            approved = head
    # A refresh event is a base-merge commit pushed after a Rex approval,
    # with no other commit between that approval and the merge. Each
    # approval opens its own run of refresh events (the ac3-4 denominator).
    last_approved = None
    for _when, verdict, head in rounds["Rex"]:
        if verdict == "APPROVED" and head in index_of:
            last_approved = head
            for c in commits[index_of[head] + 1:]:
                if is_base_merge(c, base, pr_oids):
                    refresh_heads.add(c.get("oid"))
                else:
                    break
    created = parse_ts(pr.get("createdAt"))
    merged = parse_ts(pr.get("mergedAt"))
    paths = [f.get("path") for f in pr.get("files") or [] if isinstance(f, dict)]
    return {
        "number": pr.get("number"),
        "rex_rounds": len(rounds["Rex"]),
        "hakim_rounds": len(rounds["Hakim"]),
        "tariq_rounds": len(rounds["Tariq"]),
        "rex_changes_requested": sum(1 for r in rounds["Rex"] if r[1] == "CHANGES_REQUESTED"),
        "refresh_events": len(refresh_heads),
        "pure_refresh_rounds": pure_refresh_rounds,
        "hours_open_to_merge": round((merged - created).total_seconds() / 3600.0, 2) if created and merged else None,
        "records_pr": is_records_pr(paths),
        "approved_head_seen": last_approved is not None,
    }


def gh_json(args):
    out = subprocess.run(["gh"] + args, check=True, capture_output=True, text=True).stdout
    return json.loads(out)


def parse_range(text):
    match = re.match(r"^(\d+)-(\d+)$", text or "")
    if not match:
        raise ValueError("expected a range such as 1524-1617, got %r" % text)
    return int(match.group(1)), int(match.group(2))


def fetch_forge(base, last=None, number_range=None, limit=300):
    """Fetch merged PRs of FORGE_REPO with reviews, comments and commit parents."""
    cmd = ["pr", "list", "-R", FORGE_REPO, "--state", "merged", "--limit", str(limit),
           "--json", "number,title,createdAt,mergedAt,baseRefName,files"]
    if base:
        cmd += ["--base", base]
    listing = gh_json(cmd)
    listing.sort(key=lambda p: p.get("mergedAt") or "", reverse=True)
    if number_range:
        low, high = number_range
        listing = [p for p in listing if low <= p["number"] <= high]
    elif last:
        listing = listing[:last]
    prs = []
    for item in listing:
        detail = gh_json(["pr", "view", str(item["number"]), "-R", FORGE_REPO, "--json", "reviews,comments"])
        merged = dict(item)
        for key in ("reviews", "comments"):
            merged[key] = detail.get(key) or []
        for review in merged["reviews"]:
            review.pop("author", None)
        for comment in merged["comments"]:
            comment.pop("author", None)
        rest = gh_json(["api", "--paginate", "--slurp", "repos/%s/pulls/%d/commits" % (FORGE_REPO, item["number"])])
        if rest and isinstance(rest[0], list):
            rest = [c for page in rest for c in page]
        merged["commits"] = [
            {
                "oid": c.get("sha"),
                "committedDate": ((c.get("commit") or {}).get("committer") or {}).get("date"),
                "messageHeadline": ((c.get("commit") or {}).get("message") or "").split("\n", 1)[0],
                "parents": [p.get("sha") for p in c.get("parents") or []],
            }
            for c in rest
        ]
        merged["files"] = [{"path": f.get("path")} for f in merged.get("files") or []]
        prs.append(merged)
    if number_range:
        selection = "--forge-range %d-%d" % number_range
    else:
        selection = "--forge-last %d" % last
    if base:
        selection += " --forge-base %s" % base
    return {"repo": FORGE_REPO, "base": base or "any", "selection": selection, "prs": prs}


def measure_forge(data):
    if data.get("repo") != FORGE_REPO:
        raise ValueError("the forge view reads only %s, not %r" % (FORGE_REPO, data.get("repo")))
    rows = [analyze_pr(pr) for pr in data.get("prs") or []]
    rex = [r["rex_rounds"] for r in rows]
    hours = [r["hours_open_to_merge"] for r in rows if r["hours_open_to_merge"] is not None]
    records = [r for r in rows if r["records_pr"]]
    return {
        "repo": FORGE_REPO,
        "prs": len(rows),
        "pr_numbers": sorted(r["number"] for r in rows),
        "rex_rounds": sum(rex),
        "rex_rounds_per_pr_mean": round(mean(rex), 2),
        "rex_rounds_per_pr_median": round(float(median(rex)), 2),
        "prs_with_2plus_rex_rounds": sum(1 for x in rex if x >= 2),
        "prs_with_3plus_rex_rounds": sum(1 for x in rex if x >= 3),
        "rex_changes_requested": sum(r["rex_changes_requested"] for r in rows),
        "hakim_rounds": sum(r["hakim_rounds"] for r in rows),
        "tariq_rounds": sum(r["tariq_rounds"] for r in rows),
        "hours_open_to_merge_median": round(median(hours), 2),
        "hours_open_to_merge_mean": round(mean(hours), 2),
        "refresh_events": sum(r["refresh_events"] for r in rows),
        "pure_refresh_rounds": sum(r["pure_refresh_rounds"] for r in rows),
        "records_prs": len(records),
        "records_pr_rex_rounds_mean": round(mean([r["rex_rounds"] for r in records]), 2) if records else 0,
        "records_pr_rounds": {str(r["number"]): r["rex_rounds"] for r in records},
        "per_pr": rows,
    }


# --------------------------------------------------------------------------
# Report, metrics and comparison
# --------------------------------------------------------------------------


def script_commit():
    here = os.path.dirname(os.path.abspath(__file__))
    name = os.path.basename(__file__)
    try:
        commit = subprocess.run(
            ["git", "-C", here, "log", "-1", "--format=%H", "--", name],
            check=True, capture_output=True, text=True,
        ).stdout.strip()
        dirty = subprocess.run(
            ["git", "-C", here, "status", "--porcelain", "--", name],
            check=True, capture_output=True, text=True,
        ).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return "unknown"
    if not commit:
        return "uncommitted"
    return commit + ("-dirty" if dirty else "")


def flat_metrics(report):
    """Headline numbers keyed by a stable dotted name, for compare."""
    out = {}
    session = report.get("session")
    if session:
        for key in ("mean", "p50", "p90", "p99", "max"):
            out["session.context_per_turn.%s" % key] = session["context_per_turn"][key]
        out["session.api_turns"] = session["api_turns"]
        out["session.compactions"] = session["compactions"]["count"]
        out["session.compactions_near_cap"] = session["compactions"]["near_cap"]
        out["session.auto_code_review_banners"] = session["auto_code_review_banners"]
        for key, value in session["cache"].items():
            out["session.cache.%s" % key] = value
        for row in session["context_share_by_category"]:
            out["session.share_pct.%s" % row["category"]] = row["share_pct"]
        for row in session["skills"]:
            out["session.skill_injections.%s" % row["skill"]] = row["injections"]
    reviewers = report.get("reviewers")
    if reviewers:
        out["reviewers.reviewer_runs"] = reviewers["reviewer_runs"]
        out["reviewers.resume_rebuilds_per_100_runs"] = reviewers["resume_rebuilds_per_100_runs"]
        for key, value in reviewers["all_reviewers"].items():
            out["reviewers.all.%s" % key] = value
        for name, entry in reviewers["per_reviewer"].items():
            for key, value in entry.items():
                if not isinstance(value, dict):
                    out["reviewers.%s.%s" % (name, key)] = value
    locks = report.get("lock_blocks")
    if locks:
        for key, value in locks["blocks"].items():
            out["lock_blocks.%s" % key] = value
    samples = [report.get("forge")] + list(report.get("forge_samples") or [])
    for number, forge in enumerate(samples, start=1):
        if not forge:
            continue
        prefix = "forge" if number == 1 else "forge.sample%d" % number
        for key, value in forge.items():
            if isinstance(value, (int, float)) and not isinstance(value, bool):
                out["%s.%s" % (prefix, key)] = value
    return out


def compare(before, after):
    a = flat_metrics(before)
    b = flat_metrics(after)
    rows = []
    for key in sorted(set(a) | set(b)):
        x = a.get(key)
        y = b.get(key)
        if x is None or y is None:
            change = None
        elif x == 0:
            change = 0.0 if y == 0 else None
        else:
            change = round(100.0 * (y - x) / abs(x), 1)
        rows.append({"metric": key, "before": x, "after": y, "change_pct": change})
    return rows


def fmt(value):
    if isinstance(value, float):
        return "{:,.2f}".format(value)
    if isinstance(value, int):
        return "{:,}".format(value)
    return str(value)


def markdown_report(report):
    meta = report["meta"]
    lines = []
    add = lines.append
    add("# Token cost baseline %s" % meta.get("label", ""))
    add("")
    add("Produced by `bin/token-cost.py report`. Aggregate numbers only.")
    add("")
    add("| Field | Value |")
    add("|---|---|")
    add("| Window | %s to %s |" % (meta.get("since") or "start", meta.get("until") or "end"))
    add("| Transcript SHA-256 (measured prefix) | `%s` |" % meta.get("transcript_sha256", "n/a"))
    add("| Script commit | `%s` |" % meta.get("script_commit"))
    add("| Claude Code CLI versions in the transcript | %s |" % ", ".join(meta.get("cli_versions") or []))
    add("")
    add("Command:")
    add("")
    add("```bash")
    add(meta.get("command", ""))
    add("```")
    session = report.get("session")
    if session:
        cpt = session["context_per_turn"]
        add("")
        add("## Session view")
        add("")
        add("| Metric | Value |")
        add("|---|---|")
        add("| API turns | %s |" % fmt(session["api_turns"]))
        add("| Context per turn: mean / p50 / p90 / p99 / max | %s / %s / %s / %s / %s |" % tuple(fmt(cpt[k]) for k in ("mean", "p50", "p90", "p99", "max")))
        comp = session["compactions"]
        add("| Compactions (near the cap) | %s (%s) |" % (fmt(comp["count"]), fmt(comp["near_cap"])))
        add("| Compaction mean pre / post tokens | %s / %s |" % (fmt(comp["mean_pre"]), fmt(comp["mean_post"])))
        tok = session["tokens"]
        add("| Input / cache creation / cache read / output | %s / %s / %s / %s |" % tuple(fmt(tok[k]) for k in ("input", "cache_creation", "cache_read", "output")))
        cache = session["cache"]
        add("| Main-loop cache rebuilds (after compaction) | %s (%s) |" % (fmt(cache["rebuilds"]), fmt(cache["rebuilds_after_compaction"])))
        add("| Main-loop CI-wait turns / cache rebuilds during a CI wait | %s / %s |" % (fmt(cache["ci_wait_turns"]), fmt(cache["rebuilds_during_ci_wait"])))
        add("| Requests with 1-hour / 5-minute cache writes | %s / %s |" % (fmt(cache["requests_with_1h_writes"]), fmt(cache["requests_with_5m_writes"])))
        add("| AUTO CODE REVIEW banners | %s |" % fmt(session["auto_code_review_banners"]))
        add("| Wall hours / summed turn hours | %s / %s |" % (fmt(session["time"]["wall_hours"]), fmt(session["time"]["turn_duration_hours"])))
        add("")
        add("Context share by category (context-turns: estimated tokens x turns held before the next compaction):")
        add("")
        add("| Category | Share % | Tokens (est.) |")
        add("|---|---|---|")
        for row in session["context_share_by_category"][:15]:
            add("| %s | %s | %s |" % (row["category"], fmt(row["share_pct"]), fmt(row["tokens_est"])))
        add("")
        add("Skill injections (untracked or private skills are grouped as `other`):")
        add("")
        add("| Skill | Injections | Mean body bytes | Compaction re-injections |")
        add("|---|---|---|---|")
        for row in session["skills"][:12]:
            add("| %s | %s | %s | %s |" % (row["skill"], fmt(row["injections"]), fmt(row["mean_body_bytes"]), fmt(row["compaction_reinjections"])))
    reviewers = report.get("reviewers")
    if reviewers:
        add("")
        add("## Reviewer view")
        add("")
        add("| Metric | All reviewers | Rex | Hakim | Tariq |")
        add("|---|---|---|---|---|")
        cols = [reviewers["all_reviewers"]] + [reviewers["per_reviewer"][n] for n in ("Rex", "Hakim", "Tariq")]
        labels = (
            ("runs", "Runs"),
            ("first_turn_context_median", "First-turn context (median)"),
            ("total_tokens_sum", "Total tokens (uncached input + cache writes + output)"),
            ("total_tokens_median", "Total tokens per review (median)"),
            ("cache_read_tokens_sum", "Cache-read tokens"),
            ("tool_calls_mean", "Tool calls per review (mean)"),
            ("ci_wait_turns", "CI-wait turns"),
            ("runs_with_ci_wait", "Runs with a CI-wait turn"),
            ("long_waits", "CI waits of 300 s or more"),
            ("long_wait_rebuilds", "Of those, followed by a cache rebuild"),
            ("cache_rebuilds", "Cache rebuilds"),
            ("resume_rebuilds", "Resume rebuilds"),
            ("resume_rebuilds_ci_green", "Of those, after a CI-green message"),
            ("duration_hours", "Wall hours"),
        )
        for key, label in labels:
            add("| %s | %s |" % (label, " | ".join(fmt(c.get(key, 0)) for c in cols)))
        add("")
        add("Resume rebuilds per 100 reviewer runs (CI-green messages excluded): %s." % fmt(reviewers["resume_rebuilds_per_100_runs"]))
        add("")
        add("Runs by cache TTL (a run with any 1-hour cache write is a 1-hour run):")
        add("")
        add("| TTL | Runs | First-turn context (median) | Total tokens | Cache rebuilds | CI-wait turns |")
        add("|---|---|---|---|---|---|")
        for ttl in ("5m", "1h"):
            entry = reviewers["all_reviewers_by_ttl"][ttl]
            add("| %s | %s | %s | %s | %s | %s |" % (ttl, fmt(entry.get("runs", 0)), fmt(entry.get("first_turn_context_median", 0)),
                                                      fmt(entry.get("total_tokens_sum", 0)), fmt(entry.get("cache_rebuilds", 0)), fmt(entry.get("ci_wait_turns", 0))))
        if reviewers["other_agents"]:
            add("")
            add("Other agent types:")
            add("")
            add("| Type | Runs | First-turn context (median / max) | Total tokens |")
            add("|---|---|---|---|")
            for name, entry in reviewers["other_agents"].items():
                add("| %s | %s | %s / %s | %s |" % (name, fmt(entry["runs"]), fmt(entry["first_turn_context_median"]),
                                                   fmt(entry["first_turn_context_max"]), fmt(entry["total_tokens_sum"])))
    locks = report.get("lock_blocks")
    if locks:
        blocks = locks["blocks"]
        add("")
        add("## Reviewer lock blocks")
        add("")
        add("| Metric | Value |")
        add("|---|---|")
        add("| Blocked commit or push | %s |" % fmt(blocks["commit_or_push"]))
        add("| Blocked commit / push | %s / %s |" % (fmt(blocks["git_commit"]), fmt(blocks["git_push"])))
        add("| Other blocked commands | %s |" % fmt(blocks["other"]))
        add("| Transcripts read | %s |" % fmt(locks["transcripts"]))
        for day, entry in locks["by_day"].items():
            add("| %s commit or push | %s |" % (day, fmt(entry["git_commit"] + entry["git_push"])))
    for forge in [report.get("forge")] + list(report.get("forge_samples") or []):
        if not forge:
            continue
        nums = forge["pr_numbers"]
        add("")
        add("## Forge view (%s, PRs #%s to #%s)" % (forge["repo"], nums[0] if nums else "-", nums[-1] if nums else "-"))
        add("")
        add("| Metric | Value |")
        add("|---|---|")
        add("| Merged PRs | %s (#%s to #%s) |" % (fmt(forge["prs"]), nums[0] if nums else "-", nums[-1] if nums else "-"))
        add("| Rex rounds (mean / median per PR) | %s (%s / %s) |" % (fmt(forge["rex_rounds"]), fmt(forge["rex_rounds_per_pr_mean"]), fmt(forge["rex_rounds_per_pr_median"])))
        add("| PRs with 2+ / 3+ Rex rounds | %s / %s |" % (fmt(forge["prs_with_2plus_rex_rounds"]), fmt(forge["prs_with_3plus_rex_rounds"])))
        add("| Rex CHANGES REQUESTED rounds | %s |" % fmt(forge["rex_changes_requested"]))
        add("| Hakim / Tariq rounds | %s / %s |" % (fmt(forge["hakim_rounds"]), fmt(forge["tariq_rounds"])))
        add("| Hours from open to merge (median / mean) | %s / %s |" % (fmt(forge["hours_open_to_merge_median"]), fmt(forge["hours_open_to_merge_mean"])))
        add("| Pure-refresh Rex rounds / refresh events | %s / %s |" % (fmt(forge["pure_refresh_rounds"]), fmt(forge["refresh_events"])))
        add("| Records PRs (Rex rounds per records PR, mean) | %s (%s) |" % (fmt(forge["records_prs"]), fmt(forge["records_pr_rex_rounds_mean"])))
        if forge.get("records_pr_rounds"):
            add("| Rex rounds per records PR | %s |" % ", ".join("#%s: %s" % (n, r) for n, r in sorted(forge["records_pr_rounds"].items())))
    add("")
    return "\n".join(lines)


def build_command(args):
    parts = ["python3 bin/token-cost.py report"]
    if args.transcript:
        parts.append("--transcript <session.jsonl>")
    if args.subagents:
        parts.append("--subagents <session-dir>/subagents")
    if args.since:
        parts.append("--since %s" % args.since)
    if args.until:
        parts.append("--until %s" % args.until)
    for path in getattr(args, "forge_from", None) or []:
        # A saved forge file records the selection that fetched it, so the
        # command shows the fetch form, which needs no local file.
        try:
            with open(path, "r", encoding="utf-8") as handle:
                selection = json.load(handle).get("selection")
        except (OSError, ValueError, AttributeError):
            selection = None
        safe = isinstance(selection, str) and re.match(r"^--forge-(?:range \d+-\d+|last \d+)(?: --forge-base [\w./-]+)?$", selection)
        parts.append(selection if safe else "--forge-from <forge.json>")
    for item in getattr(args, "forge_range", None) or []:
        parts.append("--forge-range %s" % item)
    if getattr(args, "forge_last", None):
        parts.append("--forge-last %d" % args.forge_last)
    if getattr(args, "label", None):
        parts.append("--label %s" % args.label)
    parts.append("--format %s" % args.format)
    return " \\\n  ".join(parts)


def lock_paths(transcripts, subagent_dirs):
    paths = list(transcripts)
    for directory in subagent_dirs:
        paths += find_subagent_files(directory)
    return paths


def repo_root():
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def load_ids(path):
    if not path:
        return None
    with open(path, "r", encoding="utf-8") as handle:
        return {line.strip() for line in handle if line.strip()}


def load_forge_samples(args):
    """Return one forge data set per --forge-from, --forge-range or --forge-last."""
    samples = []
    fetched = []
    for path in args.forge_from or []:
        with open(path, "r", encoding="utf-8") as handle:
            samples.append(json.load(handle))
    for item in args.forge_range or []:
        data = fetch_forge(args.forge_base, number_range=parse_range(item))
        samples.append(data)
        fetched.append(data)
    if args.forge_last:
        data = fetch_forge(args.forge_base, last=args.forge_last)
        samples.append(data)
        fetched.append(data)
    if args.save:
        if len(fetched) != 1:
            raise ValueError("--save needs exactly one fetched sample (--forge-range or --forge-last)")
        with open(args.save, "w", encoding="utf-8") as handle:
            json.dump(fetched[0], handle, indent=1)
    return samples


def emit(obj, fmt_name):
    if fmt_name == "md":
        sys.stdout.write(markdown_report(obj))
    else:
        json.dump(obj, sys.stdout, indent=1)
        sys.stdout.write("\n")


def add_window_args(parser):
    parser.add_argument("--since", help="ISO-8601 start of the window (inclusive)")
    parser.add_argument("--until", help="ISO-8601 end of the window (inclusive)")


def add_forge_args(parser):
    parser.add_argument("--forge-from", action="append", help="read forge data saved with --save (repeatable)")
    parser.add_argument("--forge-range", action="append", help="merged PR numbers A-B, for example 1524-1617 (repeatable)")
    parser.add_argument("--forge-last", type=int, help="the last N merged PRs")
    parser.add_argument("--forge-base", help="count only PRs merged into this base branch (default: every base)")
    parser.add_argument("--save", help="save the fetched forge data to this file")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="cmd")

    p_session = sub.add_parser("session", help="main-loop view of one transcript")
    p_session.add_argument("--transcript", required=True)
    add_window_args(p_session)

    p_rev = sub.add_parser("reviewers", help="reviewer view of the subagent transcripts")
    p_rev.add_argument("--subagents", required=True, help="the <session-id>/subagents directory")
    p_rev.add_argument("--agent-ids", help="count only the agent ids listed in this file (one per line)")
    add_window_args(p_rev)

    p_locks = sub.add_parser("locks", help="reviewer-lock blocks of commit and push commands")
    p_locks.add_argument("--transcript", action="append", default=[], help="a main-loop transcript (repeatable)")
    p_locks.add_argument("--subagents", action="append", default=[], help="a <session-id>/subagents directory (repeatable)")
    add_window_args(p_locks)

    p_forge = sub.add_parser("forge", help="forge view of merged %s PRs" % FORGE_REPO)
    add_forge_args(p_forge)

    p_report = sub.add_parser("report", help="all views in one document")
    p_report.add_argument("--transcript")
    p_report.add_argument("--subagents")
    p_report.add_argument("--agent-ids")
    p_report.add_argument("--label", default="", help="a short label for the Markdown title, for example 2026-10-10")
    p_report.add_argument("--format", choices=("json", "md"), default="json")
    add_window_args(p_report)
    add_forge_args(p_report)

    p_cmp = sub.add_parser("compare", help="relative change between two JSON reports")
    p_cmp.add_argument("before")
    p_cmp.add_argument("after")

    args = parser.parse_args(argv)
    if args.cmd is None:
        parser.print_help()
        return 2
    try:
        if args.cmd == "session":
            window = Window(args.since, args.until)
            emit(measure_session(args.transcript, window, tracked_skills(repo_root())), "json")
        elif args.cmd == "reviewers":
            window = Window(args.since, args.until)
            emit(measure_reviewers(args.subagents, window, load_ids(args.agent_ids)), "json")
        elif args.cmd == "locks":
            window = Window(args.since, args.until)
            emit(measure_lock_blocks(lock_paths(args.transcript, args.subagents), window), "json")
        elif args.cmd == "forge":
            if not (args.forge_from or args.forge_range or args.forge_last):
                parser.error("forge needs --forge-from, --forge-range or --forge-last")
            samples = load_forge_samples(args)
            if len(samples) != 1:
                parser.error("forge takes one sample; use report for several")
            emit(measure_forge(samples[0]), "json")
        elif args.cmd == "report":
            window = Window(args.since, args.until)
            report = {"meta": {
                "label": args.label,
                "since": args.since,
                "until": args.until,
                "script_commit": script_commit(),
                "command": build_command(args),
            }}
            if args.transcript:
                digest = hashlib.sha256()
                report["session"] = measure_session(args.transcript, window, tracked_skills(repo_root()), digest)
                report["meta"]["transcript_sha256"] = digest.hexdigest()
                report["meta"]["cli_versions"] = report["session"]["cli_versions"]
            if args.subagents:
                report["reviewers"] = measure_reviewers(args.subagents, window, load_ids(args.agent_ids))
                if args.format == "md":
                    report["reviewers"].pop("runs", None)
            if args.transcript or args.subagents:
                report["lock_blocks"] = measure_lock_blocks(
                    lock_paths([args.transcript] if args.transcript else [], [args.subagents] if args.subagents else []), window)
            if args.forge_from or args.forge_range or args.forge_last:
                samples = [measure_forge(data) for data in load_forge_samples(args)]
                report["forge"] = samples[0]
                if len(samples) > 1:
                    report["forge_samples"] = samples[1:]
            report["metrics"] = flat_metrics(report)
            emit(report, args.format)
        elif args.cmd == "compare":
            with open(args.before, "r", encoding="utf-8") as handle:
                before = json.load(handle)
            with open(args.after, "r", encoding="utf-8") as handle:
                after = json.load(handle)
            emit(compare(before, after), "json")
    except (OSError, ValueError, subprocess.CalledProcessError) as exc:
        sys.stderr.write("token-cost: %s\n" % exc)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
