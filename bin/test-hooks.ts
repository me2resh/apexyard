// Hook smoke test — direct bash invocation with Claude-Code-format payloads
import { spawnSync } from "node:child_process"
import { mkdtempSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

const ROOT = join(import.meta.dir, "..")

// Run in an isolated temp dir so the hook can't see this repo's
// .claude/session/current-ticket marker and accidentally allow edits.
const tmpDir = mkdtempSync(join(tmpdir(), "apexyard-hook-test-"))

const cases: { name: string; tool: string; args: any; hook: string; expect: number }[] = [
  { name: "edit .ts no ticket", tool: "Edit", args: { file_path: "src/foo.ts" }, hook: "require-active-ticket", expect: 2 },
  { name: "edit .md (exempt)", tool: "Edit", args: { file_path: "README.md" }, hook: "require-active-ticket", expect: 0 },
  { name: "git push main", tool: "Bash", args: { command: "git push origin main" }, hook: "block-main-push", expect: 2 },
  { name: "git push feature", tool: "Bash", args: { command: "git push origin feature/foo" }, hook: "block-main-push", expect: 0 },
  { name: "git add -A", tool: "Bash", args: { command: "git add -A" }, hook: "block-git-add-all", expect: 2 },
  { name: "git add specific", tool: "Bash", args: { command: "git add src/foo.ts" }, hook: "block-git-add-all", expect: 0 },
]

let passed = 0
let failed = 0
for (const c of cases) {
  const result = spawnSync("bash", [join(ROOT, ".claude/hooks", `${c.hook}.sh`)], {
    input: JSON.stringify({ tool_name: c.tool, tool_input: c.args }),
    encoding: "utf-8",
    cwd: tmpDir,
  })
  const status = result.status ?? -1
  const ok = status === c.expect
  if (ok) {
    passed++
    console.log(`  ✓ ${c.name}: exit ${status} (expected ${c.expect})`)
  } else {
    failed++
    console.log(`  ✗ ${c.name}: exit ${status} (expected ${c.expect})`)
    if (result.stderr) console.log(`    stderr: ${result.stderr.slice(0, 200)}`)
  }
}
rmSync(tmpDir, { recursive: true, force: true })
console.log(`\n${passed} passed, ${failed} failed`)
process.exit(failed > 0 ? 1 : 0)
