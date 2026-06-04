// Hook smoke test — exercises all three blocking hooks via the adapter
import { spawnSync } from "node:child_process"
import { existsSync, mkdtempSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { toClaudeInput } from "../shared/hooks/_adapter.ts"

const ROOT = join(import.meta.dir, "..")

interface Case {
  name: string
  hook: string
  tool: string
  args: any
  expect: number
}

const cases: Case[] = [
  // require-active-ticket
  { name: "edit .ts no ticket", hook: "require-active-ticket", tool: "edit", args: { filePath: "src/foo.ts" }, expect: 2 },
  { name: "edit .md exempt", hook: "require-active-ticket", tool: "edit", args: { filePath: "README.md" }, expect: 0 },
  // block-main-push
  { name: "git push main", hook: "block-main-push", tool: "bash", args: { command: "git push origin main" }, expect: 2 },
  { name: "git push feature", hook: "block-main-push", tool: "bash", args: { command: "git push origin feature/foo" }, expect: 0 },
  // block-git-add-all
  { name: "git add -A", hook: "block-git-add-all", tool: "bash", args: { command: "git add -A" }, expect: 2 },
  { name: "git add specific", hook: "block-git-add-all", tool: "bash", args: { command: "git add src/foo.ts" }, expect: 0 },
]

console.log(`Test: ${cases.length} cases across 3 hooks via OpenCode→Claude adapter`)

const tmpDir = mkdtempSync(join(tmpdir(), "apexyard-hook-test-"))
console.log(`Using isolated dir: ${tmpDir}`)

let passed = 0
let failed = 0
const failedNames: string[] = []

for (const c of cases) {
  const script = join(ROOT, ".claude", "hooks", `${c.hook}.sh`)
  if (!existsSync(script)) {
    console.log(`  ✗ ${c.name}: script not found: ${script}`)
    failed++
    failedNames.push(c.name)
    continue
  }
  const payload = JSON.stringify(toClaudeInput(c.tool, c.args))
  const result = spawnSync("bash", [script], {
    input: payload,
    encoding: "utf-8",
    cwd: tmpDir,
    maxBuffer: 50 * 1024 * 1024,
  })
  const status = result.status ?? -1
  const ok = status === c.expect
  if (ok) {
    passed++
    console.log(`  ✓ ${c.name}: exit ${status}`)
  } else {
    failed++
    failedNames.push(c.name)
    console.log(`  ✗ ${c.name}: exit ${status} (expected ${c.expect})`)
    if (result.stderr) console.log(`    stderr: ${result.stderr.slice(0, 150)}`)
  }
}

rmSync(tmpDir, { recursive: true, force: true })

console.log(`\n${passed} passed, ${failed} failed`)
if (failed > 0) {
  console.log(`Failed: ${failedNames.join(", ")}`)
  process.exit(1)
}

console.log("\nThe adapter + bash hooks all work. The OpenCode plugin will:")
console.log("  1. Receive tool.execute.before with tool='edit'/'bash', args={filePath:...}/{command:...}")
console.log("  2. Call toClaudeInput(tool, args) → { tool_name: 'Edit'/'Bash', tool_input: {...} }")
console.log("  3. spawnSync the bash script with the translated payload")
console.log("  4. Exit 0 → allow, exit 2 → throw error → block")
