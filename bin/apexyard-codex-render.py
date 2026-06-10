#!/usr/bin/env python3
"""Render the Codex-native ApexYard adapter from the framework sources."""

from __future__ import annotations

import json
import os
import re
import shutil
import stat
import sys
from pathlib import Path


def repo_root() -> Path:
    return Path(__file__).resolve().parents[1]


ROOT = repo_root()


def is_text(path: Path) -> bool:
    try:
        path.read_text(encoding="utf-8")
        return True
    except UnicodeDecodeError:
        return False


def transform_text(text: str) -> str:
    text = text.replace(".claude/skills", ".agents/skills")
    text = text.replace(".claude/agents", ".codex/agents")
    text = re.sub(r"(\.codex/agents/[A-Za-z0-9_-]+)\.md\b", r"\1.toml", text)
    text = text.replace(".claude/hooks", ".codex/hooks")
    text = text.replace(".claude/session", ".codex/session")
    text = text.replace(".claude/project-config", ".codex/project-config")
    text = text.replace(".claude/rules", ".codex/rules")
    text = text.replace(".claude/registries", ".codex/registries")
    text = text.replace(".claude/", ".codex/")
    text = text.replace("CLAUDE.md", "AGENTS.md")
    text = text.replace("Claude Code", "Codex")
    return text


def copy_tree(src: Path, dst: Path, transform: bool = True) -> None:
    if dst.exists():
        shutil.rmtree(dst)
    shutil.copytree(src, dst, symlinks=True)
    if not transform:
        return
    for path in dst.rglob("*"):
        if path.is_file() and is_text(path):
            rel = path.relative_to(dst).as_posix()
            if rel in {
                "tests/test_settings_wrappers_silent_noop.sh",
                "tests/test_site_counts.sh",
                "tests/test_subpack_extraction.sh",
                "tests/test_token_efficiency_wave1.sh",
            }:
                continue
            text = transform_text(path.read_text(encoding="utf-8"))
            if rel == "tests/test_agent_routing_sync_and_drift.sh":
                text = transform_agent_routing_test(text)
            path.write_text(text, encoding="utf-8")


def parse_frontmatter(path: Path) -> tuple[dict[str, str], str]:
    text = path.read_text(encoding="utf-8")
    if not text.startswith("---\n"):
        return {}, text
    end = text.find("\n---", 4)
    if end == -1:
        return {}, text
    raw = text[4:end].strip("\n")
    body = text[end + len("\n---") :].lstrip("\n")
    data: dict[str, str] = {}
    for line in raw.splitlines():
        if not line.strip() or line.lstrip().startswith("#") or ":" not in line:
            continue
        key, value = line.split(":", 1)
        data[key.strip()] = value.strip().strip('"').strip("'")
    return data, body


def toml_string(value: str) -> str:
    return json.dumps(value, ensure_ascii=False)


def toml_multiline(value: str) -> str:
    # TOML multiline basic strings can contain quotes; escape only the triple
    # quote terminator and backslashes that would otherwise alter content.
    value = value.replace("\\", "\\\\").replace('"""', '\\"\\"\\"')
    return f'"""\n{value.rstrip()}\n"""'


def markdown_agent_fixture_to_toml(body: str) -> str:
    if not body.startswith("---\n") or "\n---\n" not in body[4:]:
        return body

    raw_fm, instructions = body[4:].split("\n---\n", 1)
    fm: dict[str, str] = {}
    comments: list[str] = []
    for line in raw_fm.splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        if stripped.startswith("#"):
            comments.append(stripped)
            continue
        if ":" not in line:
            continue
        key, value = line.split(":", 1)
        fm[key.strip()] = value.strip().strip('"').strip("'")

    lines: list[str] = []
    lines.extend(comments)
    if fm.get("name"):
        lines.append(f"name = {toml_string(fm['name'])}")
    if fm.get("description"):
        lines.append(f"description = {toml_string(fm['description'])}")
    if fm.get("model"):
        lines.append(f"model = {toml_string(fm['model'])}")
    tools = fm.get("allowed-tools", fm.get("tools", ""))
    if tools and "Write" not in tools and "Edit" not in tools and "MultiEdit" not in tools:
        lines.append('sandbox_mode = "read-only"')
    lines.append(f"developer_instructions = {toml_multiline(instructions)}")
    return "\n".join(lines)


def transform_agent_routing_test(text: str) -> str:
    text = text.replace(
        """read_model_line() {
  awk '/^---/{count++; next} count==1 && /^model:/ {sub(/^model:[[:space:]]*/, ""); print; exit}' "$1"
}
""",
        """read_model_line() {
  case "$1" in
    *.toml)
      awk '
        /^[[:space:]]*model[[:space:]]*=/ {
          sub(/^[[:space:]]*model[[:space:]]*=[[:space:]]*/, "")
          gsub(/^"|"$/, "")
          print
          exit
        }
      ' "$1"
      ;;
    *)
      awk '/^---/{count++; next} count==1 && /^model:/ {sub(/^model:[[:space:]]*/, ""); print; exit}' "$1"
      ;;
  esac
}
""",
    )

    def repl(match: re.Match[str]) -> str:
        prefix = match.group(1)
        body = match.group(2)
        return f"{prefix}'TOML'\n{markdown_agent_fixture_to_toml(body)}\nTOML"

    return re.sub(
        r"(cat > [^\n]*\.codex/agents/[A-Za-z0-9_-]+\.toml <<)'MD'\n(.*?)\nMD",
        repl,
        text,
        flags=re.S,
    )


def render_agents() -> None:
    src_dir = ROOT / ".claude" / "agents"
    dst_dir = ROOT / ".codex" / "agents"
    if dst_dir.exists():
        shutil.rmtree(dst_dir)
    dst_dir.mkdir(parents=True, exist_ok=True)

    for src in sorted(src_dir.glob("*.md")):
        fm, body = parse_frontmatter(src)
        name = fm.get("name", src.stem)
        desc = fm.get("description", "")
        tools = fm.get("allowed-tools", fm.get("tools", ""))
        body = transform_text(body)
        lines = [
            f"name = {toml_string(name)}",
            f"description = {toml_string(desc)}",
        ]
        if tools and "Write" not in tools and "Edit" not in tools and "MultiEdit" not in tools:
            lines.append('sandbox_mode = "read-only"')
        lines.append(f"developer_instructions = {toml_multiline(body)}")
        dst = dst_dir / f"{src.stem}.toml"
        dst.write_text("\n".join(lines) + "\n", encoding="utf-8")


def write_executable(path: Path, text: str) -> None:
    path.write_text(text, encoding="utf-8")
    mode = path.stat().st_mode
    path.chmod(mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


def write_codex_wrappers() -> None:
    hook_dir = ROOT / ".codex" / "hooks"
    write_executable(
        hook_dir / "codex-session-start.sh",
        """#!/bin/bash
set -u
INPUT_FILE=$(mktemp)
trap 'rm -f "$INPUT_FILE"' EXIT
cat > "$INPUT_FILE"
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
run() {
  local hook="$1"
  [ -x "$HOOK_DIR/$hook" ] || [ -f "$HOOK_DIR/$hook" ] || return 0
  "$HOOK_DIR/$hook" < "$INPUT_FILE" || exit $?
}
run pin-ops-root.sh
run onboarding-check.sh
run check-upstream-drift.sh
run check-jq-installed.sh
run check-portfolio-config.sh
run clear-bootstrap-marker.sh
run clear-issue-skill-marker.sh
run link-custom-skills.sh
run apply-agent-routing.sh
run remind-mcp-tools.sh
""",
    )
    write_executable(
        hook_dir / "codex-pre-bash.sh",
        """#!/bin/bash
set -u
INPUT_FILE=$(mktemp)
trap 'rm -f "$INPUT_FILE"' EXIT
cat > "$INPUT_FILE"
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
run() {
  local hook="$1"
  [ -x "$HOOK_DIR/$hook" ] || [ -f "$HOOK_DIR/$hook" ] || return 0
  "$HOOK_DIR/$hook" < "$INPUT_FILE" || exit $?
}
run block-git-add-all.sh
run block-main-push.sh
run validate-branch-name.sh
run check-secrets.sh
run block-onboarding-in-git.sh
run verify-commit-refs.sh
run validate-commit-format.sh
run require-agdr-for-arch-changes.sh
run pre-push-gate.sh
run block-agent-routing-drift.sh
run warn-bootstrap-scope.sh
run require-skill-for-issue-create.sh
run suggest-ticket-template.sh
run validate-issue-structure.sh
run block-private-refs-in-public-repos.sh
run validate-pr-create.sh
run require-agdr-for-arch-pr.sh
run block-unreviewed-merge.sh
run require-design-review-for-ui.sh
run block-merge-on-red-ci.sh
run require-architecture-review.sh
run require-migration-ticket.sh
run require-active-ticket.sh
run suggest-mcp-search.sh
run warn-review-marker-write.sh
run detect-role-trigger.sh
""",
    )
    write_executable(
        hook_dir / "codex-pre-edit.sh",
        """#!/bin/bash
set -u
INPUT=$(cat)
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"

payloads_for_input() {
  local tool
  tool=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
  case "$tool" in
    apply_patch|Edit|Write|MultiEdit) ;;
    *) printf '%s' "$INPUT" | jq -c . 2>/dev/null || printf '%s\\n' "$INPUT"; return 0 ;;
  esac

  local direct
  direct=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // empty' 2>/dev/null)
  if [ -n "$direct" ]; then
    printf '%s' "$INPUT" | jq -c . 2>/dev/null || printf '%s\\n' "$INPUT"
    return 0
  fi

  local patch paths
  patch=$(printf '%s' "$INPUT" | jq -r '.tool_input.patch // .tool_input.input // empty' 2>/dev/null)
  paths=$(printf '%s\\n' "$patch" | awk '
    /^\\*\\*\\* (Add|Update|Delete) File: / { sub(/^\\*\\*\\* (Add|Update|Delete) File: /, ""); print; next }
    /^\\*\\*\\* Move to: / { sub(/^\\*\\*\\* Move to: /, ""); print; next }
  ' | sort -u)
  if [ -n "$paths" ]; then
    while IFS= read -r path; do
      [ -n "$path" ] || continue
      jq -nc --arg path "$path" '{tool_name:"Write", tool_input:{file_path:$path}}'
    done <<EOF_PATHS
$paths
EOF_PATHS
    return 0
  fi

  printf '%s' "$INPUT" | jq -c . 2>/dev/null || printf '%s\\n' "$INPUT"
}

run_for_payload() {
  local payload="$1" hook
  for hook in require-migration-ticket.sh require-active-ticket.sh detect-role-trigger.sh warn-review-marker-write.sh; do
    [ -x "$HOOK_DIR/$hook" ] || [ -f "$HOOK_DIR/$hook" ] || continue
    printf '%s' "$payload" | "$HOOK_DIR/$hook" || return $?
  done
}

set -o pipefail
payloads_for_input | while IFS= read -r payload; do
  [ -n "$payload" ] || continue
  run_for_payload "$payload" || exit $?
done
""",
    )
    write_executable(
        hook_dir / "codex-post-bash.sh",
        """#!/bin/bash
set -u
INPUT_FILE=$(mktemp)
trap 'rm -f "$INPUT_FILE"' EXIT
cat > "$INPUT_FILE"
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
run() {
  local hook="$1"
  [ -x "$HOOK_DIR/$hook" ] || [ -f "$HOOK_DIR/$hook" ] || return 0
  "$HOOK_DIR/$hook" < "$INPUT_FILE" || exit $?
}
run auto-code-review.sh
run warn-stale-review-markers.sh
run suggest-mcp-reindex-after-clone.sh
run suggest-mcp-reindex-after-pull.sh
""",
    )


def hook_command(script: str) -> str:
    return (
        "bash -c 'root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0; "
        f"exec \"$root/.codex/hooks/{script}\"'"
    )


def write_hooks_json() -> None:
    hooks = {
        "hooks": {
            "SessionStart": [
                {
                    "matcher": "startup|resume|clear|compact",
                    "hooks": [
                        {
                            "type": "command",
                            "command": hook_command("codex-session-start.sh"),
                            "statusMessage": "Starting ApexYard session checks",
                        }
                    ],
                }
            ],
            "PreToolUse": [
                {
                    "matcher": "Bash",
                    "hooks": [
                        {
                            "type": "command",
                            "command": hook_command("codex-pre-bash.sh"),
                            "statusMessage": "Checking ApexYard Bash gates",
                        }
                    ],
                },
                {
                    "matcher": "apply_patch|Edit|Write|MultiEdit",
                    "hooks": [
                        {
                            "type": "command",
                            "command": hook_command("codex-pre-edit.sh"),
                            "statusMessage": "Checking ApexYard edit gates",
                        }
                    ],
                },
                {
                    "matcher": "Read|Glob|Grep",
                    "hooks": [
                        {
                            "type": "command",
                            "command": hook_command("suggest-mcp-search.sh"),
                            "statusMessage": "Checking ApexYard search guidance",
                        }
                    ],
                },
            ],
            "PostToolUse": [
                {
                    "matcher": "Bash",
                    "hooks": [
                        {
                            "type": "command",
                            "command": hook_command("codex-post-bash.sh"),
                            "statusMessage": "Running ApexYard post-Bash checks",
                        }
                    ],
                }
            ],
            "UserPromptSubmit": [
                {
                    "hooks": [
                        {
                            "type": "command",
                            "command": hook_command("detect-role-trigger.sh"),
                        }
                    ]
                }
            ],
        }
    }
    (ROOT / ".codex" / "hooks.json").write_text(json.dumps(hooks, indent=2) + "\n", encoding="utf-8")


def write_config() -> None:
    (ROOT / ".codex").mkdir(exist_ok=True)
    (ROOT / ".codex" / "config.toml").write_text(
        'project_doc_max_bytes = 65536\n\n[features]\nhooks = true\n',
        encoding="utf-8",
    )


def main() -> int:
    copy_tree(ROOT / ".claude" / "skills", ROOT / ".agents" / "skills")
    copy_tree(ROOT / ".claude" / "rules", ROOT / ".codex" / "rules")
    copy_tree(ROOT / ".claude" / "hooks", ROOT / ".codex" / "hooks")
    if (ROOT / ".claude" / "registries").exists():
        copy_tree(ROOT / ".claude" / "registries", ROOT / ".codex" / "registries")
    if (ROOT / ".claude" / "migrations").exists():
        copy_tree(ROOT / ".claude" / "migrations", ROOT / ".codex" / "migrations")
    shutil.copy2(ROOT / ".claude" / "project-config.defaults.json", ROOT / ".codex" / "project-config.defaults.json")
    p = ROOT / ".codex" / "project-config.defaults.json"
    p.write_text(transform_text(p.read_text(encoding="utf-8")), encoding="utf-8")
    src_override = ROOT / ".claude" / "project-config.json"
    dst_override = ROOT / ".codex" / "project-config.json"
    if src_override.exists():
        shutil.copy2(src_override, dst_override)
        dst_override.write_text(transform_text(dst_override.read_text(encoding="utf-8")), encoding="utf-8")
    elif dst_override.exists():
        dst_override.unlink()
    render_agents()
    write_codex_wrappers()
    write_hooks_json()
    write_config()
    print("Rendered Codex adapter: .agents/skills, .codex/hooks, .codex/rules, .codex/registries, .codex/agents, .codex/hooks.json")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
