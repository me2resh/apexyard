#!/usr/bin/env python3
"""Shadow evaluation for the optional Jev routing spike (issue #1341).

This script never changes framework routing. It compares the existing advisory
hooks with Jev on a small, versioned corpus and records only aggregate results.
The API key is read from the local secrets file and is never printed.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


ROOT = Path(__file__).resolve().parents[1]
SECRET_FILE = Path.home() / ".config/codex/secrets/trading.env"
ENDPOINT = "https://api.typesafe.ai/v1/systemone"


CORPUS = [
    {"id": "skill_bug", "prompt": "Please report a reproducible bug for the 500 error after deploy.", "skill": "bug", "role": "none", "ceremony": "standard"},
    {"id": "skill_spec", "prompt": "Draft a product requirements document for the export flow.", "skill": "write-spec", "role": "product-manager", "ceremony": "standard"},
    {"id": "skill_security", "prompt": "Run an OWASP review of the new authentication endpoint.", "skill": "security-review", "role": "security-auditor", "ceremony": "heavy"},
    {"id": "skill_decide", "prompt": "Make a technical decision between SQS and EventBridge and record it.", "skill": "decide", "role": "tech-lead", "ceremony": "standard"},
    {"id": "skill_launch", "prompt": "Check whether this service is ready for production release.", "skill": "launch-check", "role": "qa-engineer", "ceremony": "heavy"},
    {"id": "skill_threat", "prompt": "Map threats and trust boundaries for the upload service.", "skill": "threat-model", "role": "security-auditor", "ceremony": "heavy"},
    {"id": "role_backend", "prompt": "Act as the backend engineer and review this repository layer.", "skill": "none", "role": "backend-engineer", "ceremony": "standard"},
    {"id": "role_frontend", "prompt": "As the frontend engineer, inspect the accessibility of this page.", "skill": "accessibility-audit", "role": "frontend-engineer", "ceremony": "standard"},
    {"id": "role_qa", "prompt": "Put on your QA engineer hat and verify the acceptance criteria.", "skill": "none", "role": "qa-engineer", "ceremony": "standard"},
    {"id": "role_security", "prompt": "Please act as a security auditor for this secrets change.", "skill": "none", "role": "security-auditor", "ceremony": "heavy"},
    {"id": "role_architecture", "prompt": "Review this migration as the solution architect.", "skill": "none", "role": "solution-architect", "ceremony": "heavy"},
    {"id": "role_product", "prompt": "As the product manager, refine the acceptance criteria.", "skill": "none", "role": "product-manager", "ceremony": "standard"},
    {"id": "ceremony_lean", "prompt": "Change one README sentence and update its link.", "skill": "none", "role": "none", "ceremony": "lean"},
    {"id": "ceremony_heavy", "prompt": "Migrate production authentication and rotate its credentials.", "skill": "none", "role": "security-auditor", "ceremony": "heavy"},
    {"id": "negative", "prompt": "Show the current git status and recent commit.", "skill": "none", "role": "none", "ceremony": "lean"},
]


def read_key() -> str:
    if not SECRET_FILE.exists():
        raise RuntimeError(f"secret file not found: {SECRET_FILE}")
    for raw in SECRET_FILE.read_text().splitlines():
        match = re.match(r"^\s*(?:export\s+)?JEV_API_KEY\s*=\s*(.*?)\s*$", raw)
        if match:
            value = match.group(1).strip().strip("'\"")
            if value:
                return value
    raise RuntimeError("JEV_API_KEY is missing from the local secret file")


def hook_labels(hook: str, prompt: str) -> list[str]:
    payload = json.dumps({"hook_event_name": "UserPromptSubmit", "prompt": prompt})
    env = os.environ.copy()
    env["CLAUDE_CODE_SESSION_ID"] = f"jev-eval-{os.getpid()}"
    completed = subprocess.run(
        [str(ROOT / ".claude/hooks" / hook)],
        input=payload,
        text=True,
        capture_output=True,
        cwd=ROOT,
        env=env,
        check=False,
    )
    if hook == "detect-skill-intent.sh":
        return re.findall(r"matches the /([^\s]+) skill", completed.stderr)
    return re.findall(r"ROLE TRIGGER: ([^—]+?) owns this kind of work", completed.stderr)


def jev_request(key: str, item: dict) -> tuple[dict, float]:
    choices = {
        "skill": ["bug", "write-spec", "security-review", "decide", "launch-check", "threat-model", "accessibility-audit", "none"],
        "role": ["backend-engineer", "frontend-engineer", "security-auditor", "solution-architect", "qa-engineer", "product-manager", "tech-lead", "none"],
        "ceremony": ["lean", "standard", "heavy"],
    }
    questions = {
        name: {
            "type": "choice",
            "criteria": {choice: f"The {choice} classification is correct" for choice in values},
            "instructions": instruction,
        }
        for name, values, instruction in [
            ("skill", choices["skill"], "Select the single shipped framework skill that best matches the user's intent. Use none when no skill is requested."),
            ("role", choices["role"], "Select the single framework role that should own the work. Use none when no role is explicitly activated or clearly required."),
            ("ceremony", choices["ceremony"], "Classify the smallest appropriate framework ceremony: lean, standard, or heavy."),
        ]
    }
    body = json.dumps({"model": "jev-latest", "state": item["prompt"], "questions": questions}).encode()
    request = Request(ENDPOINT, data=body, headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"})
    started = time.perf_counter()
    try:
        with urlopen(request, timeout=30) as response:
            result = json.loads(response.read())
    except HTTPError as error:
        raise RuntimeError(f"Jev HTTP {error.code}") from None
    except URLError as error:
        raise RuntimeError(f"Jev network error: {error.reason}") from None
    return result, (time.perf_counter() - started) * 1000


def answer_value(answer: dict) -> str:
    return str(answer.get("choice", ""))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--live", action="store_true", help="call Jev; without this flag only the deterministic baseline runs")
    parser.add_argument("--output", type=Path, help="write JSON results to this path")
    args = parser.parse_args()

    rows = []
    key = read_key() if args.live else ""
    for item in CORPUS:
        row = {"id": item["id"], "expected": {k: item[k] for k in ("skill", "role", "ceremony")}}
        row["skill_baseline"] = hook_labels("detect-skill-intent.sh", item["prompt"])
        row["role_baseline"] = hook_labels("detect-role-trigger.sh", item["prompt"])
        if args.live:
            try:
                response, latency_ms = jev_request(key, item)
                answers = response.get("answers", {})
                row["jev"] = {name: answer_value(answers.get(name, {})) for name in ("skill", "role", "ceremony")}
                row["jev_confidence"] = {name: answers.get(name, {}).get("confidence") for name in ("skill", "role", "ceremony")}
                row["usage"] = response.get("usage", {})
                row["latency_ms"] = round(latency_ms, 1)
            except RuntimeError as error:
                row["jev_error"] = str(error)
        rows.append(row)

    summary = {"corpus_size": len(rows), "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "rows": rows}
    if args.live:
        successful = [r for r in rows if "jev" in r]
        summary["jev_successes"] = len(successful)
        summary["jev_failures"] = len(rows) - len(successful)
        summary["jev_latency_ms"] = {
            "mean": round(sum(r["latency_ms"] for r in successful) / len(successful), 1) if successful else None,
            "p50": sorted(r["latency_ms"] for r in successful)[len(successful) // 2] if successful else None,
        }
        summary["jev_accuracy"] = {
            field: round(sum(r["jev"].get(field) == r["expected"][field] for r in successful) / len(successful), 3) if successful else None
            for field in ("skill", "role", "ceremony")
        }
        summary["total_tokens"] = {
            key: sum((r.get("usage") or {}).get(key, 0) for r in successful)
            for key in ("input_tokens", "output_tokens")
        }
    if args.output:
        args.output.write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps({k: v for k, v in summary.items() if k != "rows"}, indent=2))
    return 0 if not args.live or summary.get("jev_failures") == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
