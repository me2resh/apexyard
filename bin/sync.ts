#!/usr/bin/env bun
/**
 * apexyard sync — single source of truth → OpenCode + Codex CLI
 *
 * Reads from shared/ and generates:
 *   .opencode/opencode.json
 *   .opencode/agent/<name>.md
 *   .opencode/skill/<name>/SKILL.md
 *   .opencode/plugin/apexyard-hooks.ts
 *   .opencode/instructions/
 *   .codex/config.toml
 *   .codex/AGENTS.md
 *   .codex/hooks/<name>.sh
 *
 * Usage:
 *   bun run bin/sync.ts            # write all
 *   bun run bin/sync.ts --check    # exit 1 if any file would change
 *   bun run bin/sync.ts --clean    # remove .opencode/ and .codex/ first
 */

import { readFile, writeFile, mkdir, rm, readdir, stat } from "node:fs/promises"
import { existsSync } from "node:fs"
import { join, dirname, relative, basename, extname } from "node:path"
import { load as parseYaml, dump as stringifyYaml } from "js-yaml"
import Ajv2020 from "ajv/dist/2020.js"
import addFormats from "ajv-formats"

const ROOT = join(import.meta.dir, "..")
const SHARED = join(ROOT, "shared")
const OPENCODE_DIR = join(ROOT, ".opencode")
const CODEX_DIR = join(ROOT, ".codex")
const INSTRUCTIONS_FILE = join(ROOT, "INSTRUCTIONS.md")

const args = process.argv.slice(2)
const CHECK_MODE = args.includes("--check")
const CLEAN_MODE = args.includes("--clean")

const log = (msg: string) => console.log(`[sync] ${msg}`)
const warn = (msg: string) => console.warn(`[sync] WARN: ${msg}`)
const err = (msg: string) => console.error(`[sync] ERROR: ${msg}`)

interface Role {
  name: string
  persona?: string
  department: string
  model: string
  fallback_model?: string
  description: string
  mode: "primary" | "subagent" | "all"
  permission?: {
    edit?: "allow" | "ask" | "deny"
    bash?: "allow" | "ask" | "deny"
    webfetch?: "allow" | "ask" | "deny"
    websearch?: "allow" | "ask" | "deny"
  }
  prompt_file?: string
  body_file?: string
  body?: string
}

interface Skill {
  name: string
  description: string
  effort?: "low" | "medium" | "high"
  argument_hint?: string
  body_file?: string
  body?: string
}

interface Config {
  providers: Record<string, any>
  default_model: string
  default_small_model?: string
  tiered_agents: Record<string, string>
  gates: Record<string, boolean>
  permissions: Record<string, "allow" | "ask" | "deny">
  openai_model_aliases?: Record<string, string>
  opencode_model_aliases?: Record<string, string>
}

async function readFileOrFail(path: string): Promise<string> {
  try {
    return await readFile(path, "utf-8")
  } catch (e: any) {
    if (e.code === "ENOENT") throw new Error(`File not found: ${path}`)
    throw e
  }
}

function stripFrontmatter(content: string): string {
  const lines = content.split("\n")
  if (lines[0]?.trim() !== "---") return content
  const end = lines.findIndex((l, i) => i > 0 && l.trim() === "---")
  if (end === -1) return content
  return lines.slice(end + 1).join("\n").trimStart()
}

async function fileExists(path: string): Promise<boolean> {
  try {
    await stat(path)
    return true
  } catch {
    return false
  }
}

async function listFiles(dir: string, ext?: string): Promise<string[]> {
  if (!existsSync(dir)) return []
  const entries = await readdir(dir, { withFileTypes: true })
  return entries
    .filter((e) => e.isFile() && (!ext || e.name.endsWith(ext)))
    .map((e) => join(dir, e.name))
    .sort()
}

async function listDirs(dir: string): Promise<string[]> {
  if (!existsSync(dir)) return []
  const entries = await readdir(dir, { withFileTypes: true })
  return entries.filter((e) => e.isDirectory()).map((e) => join(dir, e.name)).sort()
}

async function writeIfChanged(path: string, content: string): Promise<"created" | "updated" | "unchanged"> {
  const existed = await fileExists(path)
  let previous = ""
  if (existed) previous = await readFileOrFail(path)
  if (previous === content) return "unchanged"
  if (CHECK_MODE) {
    err(`would ${existed ? "update" : "create"}: ${relative(ROOT, path)}`)
    return existed ? "updated" : "created"
  }
  await mkdir(dirname(path), { recursive: true })
  await writeFile(path, content, "utf-8")
  return existed ? "updated" : "created"
}

let changesCount = 0
function trackChange(status: "created" | "updated" | "unchanged") {
  if (status !== "unchanged") changesCount++
}

function yamlHeader(yaml: object): string {
  return "---\n" + stringifyYaml(yaml, { lineWidth: -1 }).trim() + "\n---\n\n"
}

// ============================================================================
// LOADERS
// ============================================================================

async function loadRoles(): Promise<Role[]> {
  const roles: Role[] = []
  const depts = await listDirs(join(SHARED, "roles"))
  for (const dept of depts) {
    const files = await listFiles(dept, ".yaml")
    for (const file of files) {
      const raw = await readFileOrFail(file)
      const role = parseYaml(raw) as Role
      if (!role.name) throw new Error(`Role missing 'name' in ${file}`)
      if (role.body) continue
      if (role.prompt_file) {
        const bodyPath = join(ROOT, role.prompt_file)
        if (await fileExists(bodyPath)) {
          role.body = stripFrontmatter(await readFileOrFail(bodyPath))
        } else {
          warn(`Role ${role.name} prompt_file not found: ${bodyPath}`)
          role.body = `# ${role.persona || role.name}\n\nNo prompt file found.`
        }
      } else {
        role.body = `# ${role.persona || role.name}\n\nNo body.`
      }
      roles.push(role)
    }
  }
  return roles
}

async function loadSkills(): Promise<Skill[]> {
  const skills: Skill[] = []
  const files = await listFiles(join(SHARED, "skills"), ".yaml")
  for (const file of files) {
    const raw = await readFileOrFail(file)
    const skill = parseYaml(raw) as Skill
    if (!skill.name) throw new Error(`Skill missing 'name' in ${file}`)
    if (skill.body) continue
    if (skill.body_file) {
      const bodyPath = join(ROOT, skill.body_file)
      if (await fileExists(bodyPath)) {
        skill.body = stripFrontmatter(await readFileOrFail(bodyPath))
      } else {
        warn(`Skill ${skill.name} body_file not found: ${bodyPath}`)
        skill.body = `# /${skill.name}\n\nNo body.`
      }
    } else {
      skill.body = `# /${skill.name}\n\nNo body.`
    }
    skills.push(skill)
  }
  return skills
}

async function loadConfig(): Promise<Config> {
  const raw = await readFileOrFail(join(SHARED, "config/defaults.json"))
  return JSON.parse(raw) as Config
}

async function loadHookFiles(): Promise<{ name: string; path: string }[]> {
  const hooksDir = join(SHARED, "hooks")
  const files = await listFiles(hooksDir, ".ts")
  return files
    .filter((f) => !basename(f).startsWith("_") && !basename(f).startsWith("."))
    .map((f) => ({ name: basename(f, ".ts"), path: f }))
}

async function loadRuleFiles(): Promise<{ name: string; content: string }[]> {
  const files = await listFiles(join(SHARED, "rules"), ".md")
  const result: { name: string; content: string }[] = []
  for (const f of files) {
    const content = await readFileOrFail(f)
    result.push({ name: basename(f, ".md"), content })
  }
  return result
}

// ============================================================================
// GENERATORS — OpenCode
// ============================================================================

function renderOpencodeAgent(role: Role): string {
  const frontmatter: Record<string, any> = {
    description: role.description,
    mode: role.mode,
  }
  if (role.model) frontmatter.model = role.model
  if (role.permission) frontmatter.permission = role.permission
  return yamlHeader(frontmatter) + role.body + "\n"
}

function renderOpencodeSkill(skill: Skill): string {
  const frontmatter: Record<string, any> = {
    name: skill.name,
    description: skill.description,
  }
  let body = skill.body || `# /${skill.name}\n\nNo body.`
  if (skill.argument_hint) {
    body = `<!-- argument-hint: ${skill.argument_hint} -->\n` + body
  }
  if (skill.effort) {
    body = `<!-- effort: ${skill.effort} -->\n` + body
  }
  return yamlHeader(frontmatter) + body + "\n"
}

function renderOpencodeInstructions(instructionsDir: string, ruleFiles: { name: string; content: string }[]): string {
  let content = `# apexyard — Generated Instructions Index\n\n`
  content += `This file is generated by \`bin/sync.ts\` from INSTRUCTIONS.md and shared/rules/.\n\n`
  for (const rule of ruleFiles) {
    content += `## ${rule.name}\n\nSee \`${rule.name}.md\` for full content.\n\n`
  }
  return content
}

async function buildOpencodeInstructions(roles: Role[], ruleFiles: { name: string; content: string }[]): Promise<void> {
  const dir = join(OPENCODE_DIR, "instructions")
  if (!CHECK_MODE) await mkdir(dir, { recursive: true })
  const indexContent = renderOpencodeInstructions(dir, ruleFiles)
  trackChange(await writeIfChanged(join(dir, "INDEX.md"), indexContent))
  for (const rule of ruleFiles) {
    trackChange(await writeIfChanged(join(dir, `${rule.name}.md`), rule.content))
  }
}

async function buildOpencodeAgents(roles: Role[]): Promise<void> {
  const dir = join(OPENCODE_DIR, "agent")
  if (!CHECK_MODE) await mkdir(dir, { recursive: true })
  for (const role of roles) {
    const content = renderOpencodeAgent(role)
    trackChange(await writeIfChanged(join(dir, `${role.name}.md`), content))
  }
}

async function buildOpencodeSkills(skills: Skill[]): Promise<void> {
  const baseDir = join(OPENCODE_DIR, "skill")
  if (!CHECK_MODE) await mkdir(baseDir, { recursive: true })
  for (const skill of skills) {
    const dir = join(baseDir, skill.name)
    if (!CHECK_MODE) await mkdir(dir, { recursive: true })
    const content = renderOpencodeSkill(skill)
    trackChange(await writeIfChanged(join(dir, "SKILL.md"), content))
  }
}

function composeOpencodePlugin(hookFiles: { name: string; path: string }[]): string {
  const banner = `// GENERATED by bin/sync.ts — do not edit by hand.
// Source: shared/hooks/*.ts
// Each hook exports a default function. The composed plugin re-exports them
// under unique keys for OpenCode's plugin loader.
import type { Plugin } from "@opencode-ai/plugin"
`
  const imports: string[] = []
  const registry: string[] = []
  hookFiles.forEach((hook, idx) => {
    const varName = `_hook_${idx}`
    imports.push(`import ${varName} from "../../shared/hooks/${hook.name}.ts"`)
    registry.push(`  ${JSON.stringify(hook.name)}: ${varName},`)
  })
  const body = `
const hooks = {
${registry.join("\n")}
}

export const ApexyardHooks: Plugin = async (ctx) => {
  // Collect handlers from every hook, grouped by event name. We then wrap
  // each event in a single function that runs the handlers in registration
  // order — OpenCode expects each event to be ONE function, not an array.
  const handlersByEvent: Record<string, Array<{ name: string; handler: any }>> = {}
  for (const [name, hook] of Object.entries(hooks)) {
    const result = await hook(ctx)
    if (result && typeof result === "object") {
      for (const [event, handler] of Object.entries(result)) {
        if (typeof handler === "function") {
          ;(handlersByEvent[event] ||= []).push({ name, handler })
        }
      }
    }
  }
  const exported: Record<string, any> = {}
  for (const [event, handlers] of Object.entries(handlersByEvent)) {
    exported[event] = async (input: any, output: any) => {
      for (const { name, handler } of handlers) {
        try {
          await handler(input, output)
        } catch (err) {
          // Re-throw with hook name so the error trace identifies the gate
          const msg = err instanceof Error ? err.message : String(err)
          throw new Error(\`[apexyard/\${name}] \${msg}\`)
        }
      }
    }
  }
  return exported
}

export default ApexyardHooks
`
  return banner + "\n" + imports.join("\n") + "\n" + body
}

async function buildOpencodePlugin(hookFiles: { name: string; path: string }[]): Promise<void> {
  const dir = join(OPENCODE_DIR, "plugins")
  if (!CHECK_MODE) await mkdir(dir, { recursive: true })
  const content = composeOpencodePlugin(hookFiles)
  trackChange(await writeIfChanged(join(dir, "apexyard-hooks.ts"), content))
}

function renderOpencodeConfig(roles: Role[], config: Config): string {
  const oc: Record<string, any> = {
    $schema: "https://opencode.ai/config.json",
    model: config.default_model,
    default_agent: "build",
    instructions: [".opencode/instructions/INDEX.md"],
    provider: {},
    agent: {},
    permission: config.permissions,
    mcp: {},
  }
  if (config.default_small_model) oc.small_model = config.default_small_model
  for (const [name, opts] of Object.entries(config.providers)) {
    if (name === "opencode") oc.provider[name] = {}
    else if (name === "openai") {
      const apiKey = opts.apiKey || "{env:OPENAI_API_KEY}"
      oc.provider[name] = { options: { apiKey } }
    } else {
      oc.provider[name] = opts
    }
  }
  for (const role of roles) {
    const model = resolveModelForRole(role, config)
    const entry: Record<string, any> = { model }
    if (role.mode) entry.mode = role.mode
    if (role.permission) entry.permission = role.permission
    oc.agent[role.name] = entry
  }
  return JSON.stringify(oc, null, 2) + "\n"
}

function resolveModelForRole(role: Role, config: Config): string {
  for (const [pattern, model] of Object.entries(config.tiered_agents)) {
    if (pattern.endsWith("*")) {
      const prefix = pattern.slice(0, -1)
      if (role.name.startsWith(prefix)) return model
    } else if (pattern === role.name) {
      return model
    }
  }
  return role.model || config.default_model
}

async function buildOpencodeConfig(roles: Role[], config: Config): Promise<void> {
  const content = renderOpencodeConfig(roles, config)
  trackChange(await writeIfChanged(join(OPENCODE_DIR, "opencode.json"), content))
}

// ============================================================================
// GENERATORS — Codex CLI
// ============================================================================

function renderCodexConfigToml(roles: Role[], config: Config): string {
  // Codex CLI only ships with OpenAI providers. We use gpt-5.5 as the default
  // (high-quality general model); subagents in .codex/agents/*.toml can pick
  // gpt-5.4-mini for cheaper fast tasks. The OpenCode free-tier model
  // (opencode/minimax-m3-free) is NOT a Codex option — Codex has no free tier.
  //
  // Codex v0.137 rejects provider settings in project-local config.toml.
  // Keep provider selection in the user-level ~/.codex/config.toml and only
  // ship project-scoped model / sandbox / hook settings here.
  // Hook format: inline [[hooks.<Event>]] with `matcher` + nested `hooks` array.
  // Supported matchers:
  //   ^Bash$                  - intercepts Bash tool calls
  //   apply_patch|Edit|Write  - intercepts Codex's native file-edits
  // Hook input: JSON on stdin with {tool_name, tool_input, cwd, ...}
  // Hook output: exit 0 = ok, exit 2 + stderr = blocked, or JSON decision.
  //
  // Trust: non-managed hooks need user trust (--dangerously-bypass-hook-trust
  // or /hooks in the TUI). See INSTRUCTIONS.md → "Codex hooks trust".
  const codexDefaultModel = "gpt-5.5"
  let toml = `# GENERATED by bin/sync.ts — do not edit by hand.
# Codex CLI config — see https://developers.openai.com/codex/config-basic
model = "${codexDefaultModel}"
model_reasoning_effort = "medium"
approval_policy = "on-request"
sandbox_mode = "workspace-write"

# apexyard workflow gates, enforced via inline hooks (see below). Codex has
# no project-level permission table the way OpenCode does; sandbox_mode
# and approval_policy are the global guardrails.
`
  toml += `
# ============================================================================
# Hooks
# ============================================================================
# Each hook invokes a bash wrapper at .codex/hooks/<name>.sh. The wrapper
# reads JSON from stdin, calls into the canonical TS implementation in
# shared/hooks/<name>.ts (which itself shells out to the bash script in
# .claude/hooks/<name>.sh), and propagates the exit code (0 = allow, 2 = block).
#
# For .codex/hooks/<name>.sh to run, the user must trust it once per session
# (run '/hooks' in the TUI) OR pass --dangerously-bypass-hook-trust.
# ============================================================================

# Ticket-first gate: block Edit/Write/apply_patch + Bash writes without an
# active ticket. Use the apply_patch|Edit|Write alias for the file-edit
# matcher (Codex's native file edit tool is apply_patch, and it accepts
# Edit/Write aliases for matcher purposes).
[[hooks.PreToolUse]]
matcher = "apply_patch|Edit|Write"

  [[hooks.PreToolUse.hooks]]
  type = "command"
  command = "bash .codex/hooks/require-active-ticket.sh"
  timeout = 30
  statusMessage = "Checking active ticket"

# Ticket-first gate also fires for Bash writes (echo > file, tee, sed -i).
# The bash hook auto-extracts the target path from the command and applies
# the same .claude/ docs / .md exemptions.
[[hooks.PreToolUse]]
matcher = "^Bash$"

  [[hooks.PreToolUse.hooks]]
  type = "command"
  command = "bash .codex/hooks/require-active-ticket.sh"
  timeout = 30
  statusMessage = "Checking active ticket"

# Branch-name format enforcement on 'git checkout -b' and 'git switch -c'.
[[hooks.PreToolUse]]
matcher = "^Bash$"

  [[hooks.PreToolUse.hooks]]
  type = "command"
  command = "bash .codex/hooks/validate-branch-name.sh"
  timeout = 10
  statusMessage = "Validating branch name"

# Two-marker merge gate + protected branch push block.
[[hooks.PreToolUse]]
matcher = "^Bash$"

  [[hooks.PreToolUse.hooks]]
  type = "command"
  command = "bash .codex/hooks/block-main-push.sh"
  timeout = 10
  statusMessage = "Checking protected branch"

# No 'git add -A' / 'git add .' (forces explicit staging).
[[hooks.PreToolUse]]
matcher = "^Bash$"

  [[hooks.PreToolUse.hooks]]
  type = "command"
  command = "bash .codex/hooks/block-git-add-all.sh"
  timeout = 10
  statusMessage = "Checking git add"

# Secret scanning on commit-time (post-tool-use).
[[hooks.PostToolUse]]
matcher = "^Bash$"

  [[hooks.PostToolUse.hooks]]
  type = "command"
  command = "bash .codex/hooks/check-secrets.sh"
  timeout = 30
  statusMessage = "Scanning for secrets"

# SessionStart: print the active ticket at session start so the model sees
# it in its developer context. The hook reads from .claude/session/current-ticket
# or .claude/session/tickets/<project>.
[[hooks.SessionStart]]
matcher = "startup|resume|clear"

  [[hooks.SessionStart.hooks]]
  type = "command"
  command = "bash .codex/hooks/clear-bootstrap-marker.sh"
  timeout = 5
  statusMessage = "Initialising session"

# Subagent settings — concurrent threads, nesting depth, and per-job timeout.
[agents]
max_threads = 6
max_depth = 1
job_max_runtime_seconds = 1800
`
  // Per-role [agents.<name>] entries: description tells Codex WHEN to invoke
  // the role; config_file points at the TOML with model + sandbox + instructions.
  // See https://developers.openai.com/codex/subagents
  for (const role of roles) {
    toml += `\n[agents.${role.name}]\n`
    toml += `description = "${tomlEscape(role.description)}"\n`
    toml += `config_file = "agents/${role.name}.toml"\n`
  }
  return toml
}

function renderCodexHookWrapper(hookName: string, hookBody: string): string {
  return `#!/usr/bin/env bash
# GENERATED by bin/sync.ts — do not edit by hand.
# Codex hook wrapper for: ${hookName}
# Reads JSON from stdin (Codex hook protocol) and shells out to the canonical
# TypeScript implementation in shared/hooks/${hookName}.ts.
set -euo pipefail
PAYLOAD=$(cat)
PAYLOAD_FILE=$(mktemp)
echo "$PAYLOAD" > "$PAYLOAD_FILE"
trap 'rm -f "$PAYLOAD_FILE"' EXIT
exec bun run "shared/hooks/${hookName}.ts" "$PAYLOAD_FILE"
`
}

async function buildCodexConfig(roles: Role[], config: Config, hookFiles: { name: string; path: string }[]): Promise<void> {
  const toml = renderCodexConfigToml(roles, config)
  trackChange(await writeIfChanged(join(CODEX_DIR, "config.toml"), toml))
  const hooksDir = join(CODEX_DIR, "hooks")
  if (!CHECK_MODE) await mkdir(hooksDir, { recursive: true })
  for (const hook of hookFiles) {
    const content = renderCodexHookWrapper(hook.name, "")
    const path = join(hooksDir, `${hook.name}.sh`)
    trackChange(await writeIfChanged(path, content))
    if (!CHECK_MODE) {
      const { chmod } = await import("node:fs/promises")
      await chmod(path, 0o755)
    }
  }
}

async function buildCodexAgentsMd(roles: Role[], config: Config): Promise<void> {
  // Codex reads AGENTS.md from the project root for instructions. We write
  // a slim version that points back at INSTRUCTIONS.md rather than copying
  // the full text — Codex's instruction-loading convention walks the tree
  // and concatenates, so the canonical INSTRUCTIONS.md is the source of truth.
  let content = `# apexyard — Codex CLI Instructions (Generated)\n\n`
  content += `This file is generated by bin/sync.ts. Codex reads project instructions\n`
  content += `from \`AGENTS.md\` at the project root.\n\n`
  content += `## Defaults\n\n`
  content += `- Default model: \`gpt-5.5\` (Codex only ships OpenAI providers; the\n`
  content += `  OpenCode free-tier model \`opencode/minimax-m3-free\` is not available\n`
  content += `  in Codex. See INSTRUCTIONS.md for the tiered model strategy.)\n\n`
  content += `## Source of truth\n\n`
  content += `The canonical instructions live in \`INSTRUCTIONS.md\` at the repo root.\n`
  content += `That file is harness-agnostic; this \`AGENTS.md\` is a Codex-specific\n`
  content += `projection. If you change \`INSTRUCTIONS.md\`, run \`bun run sync\` to\n`
  content += `regenerate this file.\n\n`
  if (existsSync(INSTRUCTIONS_FILE)) {
    const instructions = await readFileOrFail(INSTRUCTIONS_FILE)
    content += `---\n\n## From INSTRUCTIONS.md\n\n${instructions}\n`
  } else {
    content += `> INSTRUCTIONS.md not found at the repo root. Create it before first use.\n`
  }
  trackChange(await writeIfChanged(join(CODEX_DIR, "AGENTS.md"), content))
}

// ---- Codex agent TOML files ----
//
// In Codex, custom agents are TOML files in `.codex/agents/<name>.toml`,
// NOT entries in config.toml. The schema is documented at
// https://developers.openai.com/codex/subagents.
//
// Required: name, description, instructions
// Optional: model, model_reasoning_effort, sandbox_mode, mcp_servers,
//           nickname_candidates
//
// We map our role YAMLs to this schema:
//   - critical (head-of-*, code-reviewer, security-reviewer) → gpt-5.5
//   - default → gpt-5.5 (matches the top-level model)
//   - read-only agents (auditor, reviewer) → sandbox_mode = "read-only"
//
// The body_file in the role YAML points to the canonical markdown, which
// we read and embed as `instructions`. If body_file is missing,
// we fall back to the role's `description`.

function tomlEscape(s: string): string {
  // TOML basic-string escaping: backslash, double quote, and control chars.
  return s
    .replace(/\\/g, "\\\\")
    .replace(/"/g, '\\"')
    .replace(/\n/g, "\\n")
    .replace(/\r/g, "\\r")
    .replace(/\t/g, "\\t")
}

function tomlLiteralMultiline(s: string): string {
  // TOML literal strings do not interpret backslash escapes, which keeps
  // embedded Bash / regex examples valid in agent instructions.
  return s.replace(/'''/g, "''\\'")
}

function resolveCodexModel(role: Role, config: Config): string {
  // Codex only has OpenAI models. We map our tiered_agents (which may name
  // OpenCode free-tier models or openai/gpt-5) to Codex equivalents:
  //   openai/gpt-5.5    → gpt-5.5
  //   openai/gpt-5      → gpt-5.5
  //   opencode/<x>      → gpt-5.4-mini
  //   anything else     → gpt-5.5
  const resolved = resolveModelForRole(role, config)
  if (resolved === "openai/gpt-5.5" || resolved === "gpt-5.5") return "gpt-5.5"
  if (resolved === "openai/gpt-5" || resolved === "gpt-5") return "gpt-5.5"
  if (resolved.startsWith("openai/gpt-5-mini") || resolved.includes("mini")) return "gpt-5.4-mini"
  if (resolved.startsWith("opencode/")) return "gpt-5.4-mini"
  // already a Codex-style bare model name? pass through
  if (resolved.startsWith("gpt-") || resolved.startsWith("o")) return resolved
  return "gpt-5.5"
}

function resolveCodexSandbox(role: Role): string {
  // Reviewers / auditors stay read-only. Anything that edits code uses
  // workspace-write so the parent session can hand off implementation work.
  const readOnly = new Set([
    "code-reviewer",
    "security-reviewer",
    "penetration-tester",
    "dependency-auditor",
    "data-analyst",
  ])
  return readOnly.has(role.name) ? "read-only" : "workspace-write"
}

function renderCodexAgentToml(role: Role, body: string, config: Config): string {
  const model = resolveCodexModel(role, config)
  const sandbox = resolveCodexSandbox(role)
  const description = tomlEscape(role.description)
  const instructions = tomlLiteralMultiline(body.trim())
  // Per Codex v0.137 schema, agent files use a top-level `instructions`
  // string. A TOML table here is ignored as "invalid type: map, expected a
  // string" during startup.
  let toml = `# GENERATED by bin/sync.ts — do not edit by hand.
# Source: shared/roles/${role.name}.yaml (via ${role.body_file || role.prompt_file || "<inline>"})
# Schema: https://developers.openai.com/codex/subagents#custom-agent-file-schema
name = "${role.name}"
description = "${description}"
model = "${model}"
model_reasoning_effort = "medium"
sandbox_mode = "${sandbox}"

instructions = '''
${instructions}
'''
`
  return toml
}

async function buildCodexAgentFiles(roles: Role[], config: Config): Promise<void> {
  const agentsDir = join(CODEX_DIR, "agents")
  if (!CHECK_MODE) await mkdir(agentsDir, { recursive: true })
  let count = 0
  for (const role of roles) {
    const body = await loadRoleBody(role)
    const toml = renderCodexAgentToml(role, body, config)
    const out = join(agentsDir, `${role.name}.toml`)
    trackChange(await writeIfChanged(out, toml))
    count++
  }
  log(`  wrote ${count} agent TOML files to .codex/agents/`)
}

async function loadRoleBody(role: Role): Promise<string> {
  // Priority: body_file → prompt_file → fallback to description
  const ref = role.body_file || role.prompt_file
  if (ref) {
    const p = join(ROOT, ref)
    if (existsSync(p)) {
      const raw = await readFile(p, "utf-8")
      // Strip frontmatter — Codex reads the file as plain text instructions.
      return raw.replace(/^---[\s\S]*?---\s*/m, "").trim()
    }
    warn(`Role ${role.name} body file not found: ${ref}`)
  }
  return role.description || "(no body content)"
}

// ============================================================================
// MAIN
// ============================================================================

async function clean() {
  if (CHECK_MODE) return
  log("cleaning .opencode/ and .codex/")
  await rm(OPENCODE_DIR, { recursive: true, force: true })
  await rm(CODEX_DIR, { recursive: true, force: true })
}

async function main() {
  if (CLEAN_MODE) await clean()

  log("loading shared/...")
  const config = await loadConfig()
  const roles = await loadRoles()
  const skills = await loadSkills()
  const hooks = await loadHookFiles()
  const rules = await loadRuleFiles()

  log(`  ${roles.length} roles, ${skills.length} skills, ${hooks.length} hooks, ${rules.length} rules`)

  log("generating .opencode/...")
  await buildOpencodeConfig(roles, config)
  await buildOpencodeAgents(roles)
  await buildOpencodeSkills(skills)
  await buildOpencodePlugin(hooks)
  await buildOpencodeInstructions(roles, rules)

  log("generating .codex/...")
  await buildCodexConfig(roles, config, hooks)
  await buildCodexAgentFiles(roles, config)
  await buildCodexAgentsMd(roles, config)

  log(`done. ${changesCount} file(s) ${CHECK_MODE ? "would change" : "changed"}.`)
  if (CHECK_MODE && changesCount > 0) {
    process.exit(1)
  }
}

main().catch((e) => {
  err(e.message)
  if (process.env.DEBUG) console.error(e)
  process.exit(1)
})
