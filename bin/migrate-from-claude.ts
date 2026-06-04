#!/usr/bin/env bun
/**
 * migrate-from-claude.ts
 *
 * One-shot migration from .claude/ Claude Code layout → shared/ canonical form.
 *
 * Reads:
 *   .claude/agents/*.md       (23 agent frontmatter)
 *   .claude/skills/<name>/SKILL.md (53 skill frontmatter)
 *   .claude/hooks/<name>.sh   (31 hook shell scripts)
 *   .claude/rules/<name>.md   (11 rule markdown files)
 *
 * Writes:
 *   shared/roles/{dept}/*.yaml
 *   shared/skills/*.yaml
 *   shared/hooks/*.ts          (shell-out wrappers around the .sh files)
 *   shared/rules/*.md          (verbatim copy)
 *
 * Idempotent: safe to re-run; only writes if content changes.
 *
 * Usage:
 *   bun run bin/migrate-from-claude.ts
 *   bun run bin/migrate-from-claude.ts --dry-run
 */

import { readFile, writeFile, mkdir, readdir } from "node:fs/promises"
import { existsSync } from "node:fs"
import { join, basename } from "node:path"
import { load as parseYaml, dump as stringifyYaml } from "js-yaml"

const ROOT = join(import.meta.dir, "..")
const CLAUDE = join(ROOT, ".claude")
const SHARED = join(ROOT, "shared")

const args = process.argv.slice(2)
const DRY_RUN = args.includes("--dry-run")

const log = (msg: string) => console.log(`[migrate] ${msg}`)
const warn = (msg: string) => console.warn(`[migrate] WARN: ${msg}`)

function stripFrontmatter(content: string): { fm: Record<string, any>; body: string } {
  const lines = content.split("\n")
  if (lines[0]?.trim() !== "---") return { fm: {}, body: content }
  const end = lines.findIndex((l, i) => i > 0 && l.trim() === "---")
  if (end === -1) return { fm: {}, body: content }
  const fmText = lines.slice(1, end).join("\n")
  const body = lines.slice(end + 1).join("\n").trimStart()
  let fm: Record<string, any> = {}
  try {
    fm = parseYaml(fmText) as Record<string, any>
  } catch (e: any) {
    warn(`Failed to parse frontmatter: ${e.message}`)
  }
  return { fm, body }
}

function basenameNoExt(path: string): string {
  return basename(path).replace(/\.[^.]+$/, "")
}

async function readFileOrNull(path: string): Promise<string | null> {
  try {
    return await readFile(path, "utf-8")
  } catch {
    return null
  }
}

async function writeIfChanged(path: string, content: string): Promise<boolean> {
  const existing = await readFileOrNull(path)
  if (existing === content) return false
  if (DRY_RUN) {
    log(`would write: ${path.replace(ROOT + "/", "")}`)
    return true
  }
  await mkdir(join(path, ".."), { recursive: true })
  await writeFile(path, content, "utf-8")
  return true
}

// ============================================================================
// Department inference
// ============================================================================

const ROLE_DEPT: Record<string, string> = {
  "backend-engineer": "engineering",
  "frontend-engineer": "engineering",
  "qa-engineer": "engineering",
  "platform-engineer": "engineering",
  "sre": "engineering",
  "tech-lead": "engineering",
  "head-of-engineering": "engineering",
  "code-reviewer": "engineering",
  "product-manager": "product",
  "product-analyst": "product",
  "head-of-product": "product",
  "ui-designer": "design",
  "ux-designer": "design",
  "head-of-design": "design",
  "security-reviewer": "security",
  "penetration-tester": "security",
  "head-of-security": "security",
  "data-analyst": "data",
  "data-engineer": "data",
  "head-of-data": "data",
  // utility agents — no specific dept, place in engineering for now
  "ticket-manager": "engineering",
  "pr-manager": "engineering",
  "dependency-auditor": "engineering",
}

const TIERED_OVERRIDE: Record<string, string> = {
  "code-reviewer": "openai/gpt-5",
  "security-reviewer": "openai/gpt-5",
  "penetration-tester": "openai/gpt-5",
  "tech-lead": "openai/gpt-5",
  "head-of-engineering": "openai/gpt-5",
  "head-of-product": "openai/gpt-5",
  "head-of-design": "openai/gpt-5",
  "head-of-security": "openai/gpt-5",
  "head-of-data": "openai/gpt-5",
}

// ============================================================================
// Agents
// ============================================================================

async function migrateAgents(): Promise<number> {
  const agentsDir = join(CLAUDE, "agents")
  if (!existsSync(agentsDir)) return 0
  const files = (await readdir(agentsDir))
    .filter((f) => f.endsWith(".md"))
    .filter((f) => f !== "README.md")
    .map((f) => join(agentsDir, f))
  let count = 0
  for (const file of files) {
    const name = basenameNoExt(file)
    const dept = ROLE_DEPT[name] || "engineering"
    const raw = await readFile(file, "utf-8")
    const { fm } = stripFrontmatter(raw)
    if (!fm.name) fm.name = name
    const yaml: Record<string, any> = {
      name: fm.name,
      department: dept,
      description: fm.description || `Migrated from .claude/agents/${name}.md`,
      mode: "subagent",
      model: TIERED_OVERRIDE[name] || "opencode/minimax-m3-free",
      permission: {
        edit: fm["disallowedTools"]?.includes("Edit") ? "deny" : "allow",
        bash: "ask",
        webfetch: fm["disallowedTools"]?.includes("WebFetch") ? "deny" : "allow",
        websearch: "allow",
      },
      prompt_file: `.claude/agents/${name}.md`,
    }
    if (fm.persona_name) yaml.persona = fm.persona_name
    if (TIERED_OVERRIDE[name] === "opencode/minimax-m3-free") {
      yaml.fallback_model = "openai/gpt-5"
    }
    const out = join(SHARED, "roles", dept, `${name}.yaml`)
    const content = stringifyYaml(yaml, { lineWidth: -1 })
    if (await writeIfChanged(out, content)) count++
  }
  return count
}

// ============================================================================
// Skills
// ============================================================================

async function migrateSkills(): Promise<number> {
  const skillsDir = join(CLAUDE, "skills")
  if (!existsSync(skillsDir)) return 0
  const dirs = (await readdir(skillsDir, { withFileTypes: true }))
    .filter((e) => e.isDirectory())
    .filter((d) => !d.name.startsWith("_"))
    .map((d) => join(skillsDir, d.name))
  let count = 0
  for (const dir of dirs) {
    const name = basename(dir)
    const skillFile = join(dir, "SKILL.md")
    if (!existsSync(skillFile)) continue
    const raw = await readFile(skillFile, "utf-8")
    const { fm } = stripFrontmatter(raw)
    if (!fm.name) fm.name = name
    const yaml: Record<string, any> = {
      name: fm.name,
      description: fm.description || `Migrated from .claude/skills/${name}/SKILL.md`,
    }
    if (fm.argument_hint) yaml.argument_hint = fm.argument_hint
    if (fm.effort) yaml.effort = fm.effort
    yaml.body_file = `.claude/skills/${name}/SKILL.md`
    const out = join(SHARED, "skills", `${name}.yaml`)
    const content = stringifyYaml(yaml, { lineWidth: -1 })
    if (await writeIfChanged(out, content)) count++
  }
  return count
}

// ============================================================================
// Hooks (shell-out wrappers around the existing .sh files)
// ============================================================================

function makeHookWrapper(name: string): string {
  return `#!/usr/bin/env bun
/**
 * ${name} hook — auto-generated wrapper.
 *
 * Wraps the original bash implementation in .claude/hooks/${name}.sh as an
 * OpenCode TypeScript plugin. The bash logic is the source of truth (100%
 * preserved); this wrapper just shells out to it and bridges the JSON I/O.
 *
 * OpenCode plugin event: tool.execute.before
 */

import { spawnSync } from "node:child_process"
import { existsSync } from "node:fs"
import { join, dirname } from "node:path"
import type { Plugin } from "@opencode-ai/plugin"

const REPO_ROOT = join(import.meta.dir, "..", "..")
const BASH_SCRIPT = join(REPO_ROOT, ".claude", "hooks", "${name}.sh")

interface BashInput {
  tool: string
  args: Record<string, any>
}

function runBashHook(input: BashInput): { ok: boolean; stderr: string } {
  if (!existsSync(BASH_SCRIPT)) {
    return { ok: true, stderr: \`[${name}] bash script not found, skipping\` }
  }
  const payload = JSON.stringify({ tool_name: input.tool, tool_input: input.args })
  const result = spawnSync("bash", [BASH_SCRIPT], {
    input: payload,
    encoding: "utf-8",
    maxBuffer: 50 * 1024 * 1024,
  })
  if (result.status === 0) return { ok: true, stderr: "" }
  if (result.status === 2) {
    return { ok: false, stderr: result.stderr || "blocked" }
  }
  return { ok: true, stderr: result.stderr }
}

const ${name.replace(/-/g, "_")}: Plugin = async () => {
  return {
    "tool.execute.before": async (input, output) => {
      const r = runBashHook({ tool: input.tool, args: output.args || {} })
      if (!r.ok) {
        throw new Error(\`BLOCKED by ${name} hook:\\n\${r.stderr}\`)
      }
    },
  }
}

export default ${name.replace(/-/g, "_")}
`
}

async function migrateHooks(): Promise<number> {
  const hooksDir = join(CLAUDE, "hooks")
  if (!existsSync(hooksDir)) return 0
  const files = (await readdir(hooksDir))
    .filter((f) => f.endsWith(".sh"))
    .filter((f) => !f.startsWith("_"))
    .map((f) => join(hooksDir, f))
  let count = 0
  for (const file of files) {
    const name = basenameNoExt(file)
    const out = join(SHARED, "hooks", `${name}.ts`)
    const content = makeHookWrapper(name)
    if (await writeIfChanged(out, content)) count++
  }
  return count
}

// ============================================================================
// Rules (verbatim copy)
// ============================================================================

async function migrateRules(): Promise<number> {
  const rulesDir = join(CLAUDE, "rules")
  if (!existsSync(rulesDir)) return 0
  const files = (await readdir(rulesDir))
    .filter((f) => f.endsWith(".md"))
    .map((f) => join(rulesDir, f))
  let count = 0
  for (const file of files) {
    const name = basename(file)
    const out = join(SHARED, "rules", name)
    const content = await readFile(file, "utf-8")
    if (await writeIfChanged(out, content)) count++
  }
  return count
}

// ============================================================================
// Main
// ============================================================================

async function main() {
  log(DRY_RUN ? "DRY RUN — no files will be written" : "migrating from .claude/ → shared/")

  const agents = await migrateAgents()
  const skills = await migrateSkills()
  const hooks = await migrateHooks()
  const rules = await migrateRules()

  log(`done. ${agents} agents, ${skills} skills, ${hooks} hooks, ${rules} rules ${DRY_RUN ? "would be " : ""}written/updated.`)
  log("next: bun run bin/sync.ts to regenerate .opencode/ and .codex/")
}

main().catch((e) => {
  console.error(`[migrate] ERROR: ${e.message}`)
  if (process.env.DEBUG) console.error(e)
  process.exit(1)
})
