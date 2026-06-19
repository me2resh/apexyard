import * as fs from "node:fs";
import * as path from "node:path";
import { spawnSync } from "node:child_process";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const CLAUDE_TO_PI_SKILL_DIR = path.join(".claude", "skills");
const HOOK_TIMEOUT_MS = 30_000;

const sessionHooks = [
  "pin-ops-root.sh",
  "onboarding-check.sh",
  "check-upstream-drift.sh",
  "check-jq-installed.sh",
  "check-portfolio-config.sh",
  "clear-bootstrap-marker.sh",
  "clear-issue-skill-marker.sh",
  "link-custom-skills.sh",
  "apply-agent-routing.sh",
  "remind-mcp-tools.sh",
];

const bashHookRules: Array<{ script: string; test?: (command: string) => boolean }> = [
  { script: "block-git-add-all.sh", test: (c) => /(^|\s)git\s+add\s+(-A|--all|\.)(\s|$)/.test(c) },
  { script: "block-main-push.sh", test: (c) => /(^|[;&|]\s*)git\s+push\b/.test(c) },
  { script: "validate-branch-name.sh", test: (c) => /(^|[;&|]\s*)git\s+push\b/.test(c) },
  { script: "check-secrets.sh", test: (c) => /(^|[;&|]\s*)git\s+commit\b/.test(c) },
  { script: "block-onboarding-in-git.sh", test: (c) => /(^|[;&|]\s*)git\s+commit\b/.test(c) },
  { script: "verify-commit-refs.sh", test: (c) => /(^|[;&|]\s*)git\s+commit\b/.test(c) },
  { script: "validate-commit-format.sh", test: (c) => /(^|[;&|]\s*)git\s+commit\b/.test(c) },
  { script: "require-agdr-for-arch-changes.sh", test: (c) => /(^|[;&|]\s*)git\s+commit\b/.test(c) },
  { script: "pre-push-gate.sh", test: (c) => /(^|[;&|]\s*)git\s+push\b/.test(c) },
  { script: "block-agent-routing-drift.sh", test: (c) => /(^|[;&|]\s*)git\s+(commit|push)\b/.test(c) },
  { script: "warn-bootstrap-scope.sh", test: (c) => /(^|[;&|]\s*)git\s+commit\b/.test(c) },
  { script: "require-skill-for-issue-create.sh" },
  { script: "suggest-ticket-template.sh", test: (c) => /(^|[;&|]\s*)gh\s+issue\s+create\b/.test(c) },
  { script: "validate-issue-structure.sh", test: (c) => /(^|[;&|]\s*)gh\s+issue\s+create\b/.test(c) },
  { script: "validate-pr-create.sh", test: (c) => /(^|[;&|]\s*)gh\s+pr\s+create\b/.test(c) },
  { script: "require-agdr-for-arch-pr.sh", test: (c) => /(^|[;&|]\s*)gh\s+pr\s+create\b/.test(c) },
  { script: "block-private-refs-in-public-repos.sh", test: (c) => /(^|[;&|]\s*)gh\s+(issue\s+(create|comment)|pr\s+(create|comment)|api\b)/.test(c) },
  { script: "block-unreviewed-merge.sh", test: (c) => /(^|[;&|]\s*)gh\s+(pr\s+merge|api\b)/.test(c) },
  { script: "require-design-review-for-ui.sh", test: (c) => /(^|[;&|]\s*)gh\s+(pr\s+merge|api\b)/.test(c) },
  { script: "block-merge-on-red-ci.sh", test: (c) => /(^|[;&|]\s*)gh\s+(pr\s+merge|api\b)/.test(c) },
  { script: "require-architecture-review.sh", test: (c) => /(^|[;&|]\s*)gh\s+(pr\s+merge|api\b)/.test(c) },
  { script: "require-migration-ticket.sh" },
  { script: "require-active-ticket.sh" },
  { script: "detect-role-trigger.sh" },
  { script: "suggest-mcp-reindex-after-clone.sh", test: (c) => /(^|[;&|]\s*)git\s+clone\b/.test(c) },
  { script: "suggest-mcp-reindex-after-pull.sh", test: (c) => /(^|[;&|]\s*)git\s+pull\b/.test(c) },
  { script: "suggest-mcp-search.sh" },
];

function exists(file: string): boolean {
  try {
    return fs.existsSync(file);
  } catch {
    return false;
  }
}

function findMarkdownFiles(dir: string): string[] {
  if (!exists(dir)) return [];
  const out: string[] = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) out.push(...findMarkdownFiles(full));
    if (entry.isFile() && entry.name.endsWith(".md")) out.push(full);
  }
  return out;
}

function readText(file: string): string {
  return fs.readFileSync(file, "utf8");
}

function findOpsRoot(start: string): string {
  let current = path.resolve(start);
  while (current && current !== path.dirname(current)) {
    if (exists(path.join(current, ".apexyard-fork")) || exists(path.join(current, "CLAUDE.md"))) {
      if (exists(path.join(current, ".claude", "hooks"))) return current;
    }
    current = path.dirname(current);
  }
  return path.resolve(start);
}

function skillMeta(skillFile: string): { name: string; description: string } | undefined {
  const text = readText(skillFile);
  const match = text.match(/^---\n([\s\S]*?)\n---/);
  if (!match) return undefined;
  const name = match[1].match(/^name:\s*(.+)$/m)?.[1]?.trim().replace(/^['"]|['"]$/g, "");
  const description = match[1].match(/^description:\s*(.+)$/m)?.[1]?.trim().replace(/^['"]|['"]$/g, "");
  if (!name || !description) return undefined;
  return { name, description };
}

function hookPayload(toolName: string, input: Record<string, unknown>, event = "PreToolUse") {
  return JSON.stringify({ hook_event_name: event, tool_name: toolName, tool_input: input });
}

function runHook(cwd: string, script: string, payload: string, sessionId: string) {
  const hookPath = path.join(cwd, ".claude", "hooks", script);
  if (!exists(hookPath)) return { ok: true, output: "" };

  const result = spawnSync(hookPath, {
    cwd,
    input: payload,
    encoding: "utf8",
    timeout: HOOK_TIMEOUT_MS,
    env: {
      ...process.env,
      CLAUDE_CODE_SESSION_ID: process.env.CLAUDE_CODE_SESSION_ID || sessionId,
      APEXYARD_PI_SESSION_ID: sessionId,
    },
  });

  const output = [result.stdout, result.stderr].filter(Boolean).join("\n").trim();
  if (result.error) {
    return { ok: false, output: `${script}: ${result.error.message}${output ? `\n${output}` : ""}` };
  }
  return { ok: (result.status ?? 0) === 0, output };
}

function piToolToClaude(event: { toolName: string; input: any }) {
  if (event.toolName === "bash") return { name: "Bash", input: { command: event.input.command } };
  if (event.toolName === "read") return { name: "Read", input: { path: event.input.path } };
  if (event.toolName === "write") return { name: "Write", input: { file_path: event.input.path, path: event.input.path } };
  if (event.toolName === "edit") return { name: "Edit", input: { file_path: event.input.path, path: event.input.path } };
  return undefined;
}

export default function apexyardPiExtension(pi: ExtensionAPI) {
  let advisories: string[] = [];
  const sessionId = `pi-${process.pid}-${Date.now()}`;
  const registeredSkillAliases = new Set<string>();

  function registerSkillAliases(root: string) {
    const skillRoot = path.join(root, CLAUDE_TO_PI_SKILL_DIR);
    for (const skillFile of findMarkdownFiles(skillRoot).filter((f) => path.basename(f) === "SKILL.md")) {
      const meta = skillMeta(skillFile);
      if (!meta || registeredSkillAliases.has(meta.name)) continue;
      registeredSkillAliases.add(meta.name);
      pi.registerCommand(meta.name, {
        description: meta.description,
        handler: async (args, ctx) => {
          const content = readText(skillFile);
          const relative = path.relative(root, skillFile);
          pi.sendUserMessage(`Run the ApexYard slash command /${meta.name}${args ? ` ${args}` : ""}.\n\nLoad and follow this skill exactly from ${relative}:\n\n${content}\n\nUser arguments: ${args || "(none)"}`);
        },
      });
    }
  }

  pi.on("resources_discover", async (_event, ctx) => {
    const root = findOpsRoot(ctx.cwd);
    return { skillPaths: [path.join(root, CLAUDE_TO_PI_SKILL_DIR)] };
  });

  pi.on("session_start", async (_event, ctx) => {
    const root = findOpsRoot(ctx.cwd);
    registerSkillAliases(root);
    if (!exists(path.join(root, ".claude", "hooks"))) return;
    for (const script of sessionHooks) {
      const result = runHook(root, script, JSON.stringify({ hook_event_name: "SessionStart" }), sessionId);
      if (result.output) advisories.push(`[${script}]\n${result.output}`);
    }
    ctx.ui.notify("ApexYard Pi adapter loaded: CLAUDE.md, skills, slash aliases, and hook gates are active.", "info");
  });

  pi.on("before_agent_start", async (event, ctx) => {
    const root = findOpsRoot(ctx.cwd);
    const claudePath = path.join(root, "CLAUDE.md");
    const rulesDir = path.join(root, ".claude", "rules");
    const rolesDir = path.join(root, "roles");
    const rules = findMarkdownFiles(rulesDir).map((f) => `- ${path.relative(root, f)}`).join("\n");
    const roles = findMarkdownFiles(rolesDir).map((f) => `- ${path.relative(root, f)}`).join("\n");
    const pending = advisories.splice(0).map((a) => `\n${a}`).join("\n");
    const claude = exists(claudePath) ? readText(claudePath) : "";

    return {
      systemPrompt: `${event.systemPrompt}\n\n## ApexYard framework instructions (CLAUDE.md)\n\n${claude}\n\n## ApexYard rule files available\n${rules || "- none"}\n\n## ApexYard role files available\n${roles || "- none"}\n\nWhen a task matches a rule or role trigger, read the relevant file before continuing. If a role activates, print the ApexYard activation marker.\n${pending ? `\n## ApexYard hook advisories from previous tool calls\n${pending}\n` : ""}`,
    };
  });

  pi.on("tool_call", async (event, ctx) => {
    const mapped = piToolToClaude(event as any);
    const root = findOpsRoot(ctx.cwd);
    if (!mapped || !exists(path.join(root, ".claude", "hooks"))) return undefined;

    const hooks: string[] = [];
    if (mapped.name === "Read") hooks.push("suggest-mcp-search.sh");
    if (mapped.name === "Write") hooks.push("require-migration-ticket.sh", "require-active-ticket.sh", "detect-role-trigger.sh", "warn-review-marker-write.sh");
    if (mapped.name === "Edit") hooks.push("require-migration-ticket.sh", "require-active-ticket.sh", "detect-role-trigger.sh");
    if (mapped.name === "Bash") {
      const command = String(mapped.input.command || "");
      for (const rule of bashHookRules) {
        if (!rule.test || rule.test(command)) hooks.push(rule.script);
      }
    }

    for (const script of hooks) {
      const result = runHook(root, script, hookPayload(mapped.name, mapped.input), sessionId);
      if (result.output) advisories.push(`[${script}]\n${result.output}`);
      if (!result.ok) {
        return { block: true, reason: result.output || `${script} blocked the tool call` };
      }
    }

    return undefined;
  });
}
