// ApexYard approval pane (AgDR-0295). Opt-in. It sits behind the hooks.
//
// The pane lists the PRs that Rex approved and that wait for a human merge
// approval. Each row shows the repo, the PR, the head SHA, the CI state and
// the Rex verdict, with Approve and Not yet. Approve opens the engine's own
// AskUserQuestion menu with the AgDR-0234 question for the exact head SHA
// shown. The menu hook in .claude/hooks writes the record. This plugin never
// writes a file, never merges, and registers no tool or settings hook.
import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { GateRow, GateView } from '../types'
import {
  approveFlow,
  blocker,
  candidatesFrom,
  ciLabel,
  markerSha,
  parsePrView,
  prViewArgv,
  rexVerdict,
  validRepo,
} from './approve'
import type { Deps, PrView, Shown } from './approve'

export const PANE = 'gate-approvals'
export const COMMAND = 'gate-approve'
const GH_TIMEOUT_MS = 5000

const view = atom({ plugin: 'apexyard-gate', key: 'view' } as const, null)

async function readText($: EngineInterface, path: string): Promise<string | null> {
  try {
    return await $.fs.read(path)
  } catch {
    return null
  }
}

async function exists($: EngineInterface, path: string): Promise<boolean> {
  try {
    return await $.fs.exists(path)
  } catch {
    return false
  }
}

// Same anchors as resolve_ops_root_walk in .claude/hooks/_lib-ops-root.sh.
async function isOpsFork($: EngineInterface, dir: string): Promise<boolean> {
  if (await exists($, `${dir}/.apexyard-fork`)) return true
  return (await exists($, `${dir}/onboarding.yaml`)) && (await exists($, `${dir}/apexyard.projects.yaml`))
}

// The ops fork: the session pin first, then a walk up from the working directory.
async function opsRoot($: EngineInterface): Promise<string | null> {
  const sid = await $.session.id()
  const home = await $.env.get('HOME')
  const pinDir = (await $.env.get('APEXYARD_OPS_PIN_DIR')) || (home ? `${home}/.claude/apexyard` : '')
  const pinOff = (await $.env.get('APEXYARD_OPS_DISABLE_PIN')) === '1'
  const pin = pinDir && !pinOff ? (await readText($, `${pinDir}/ops-root-${sid}`))?.split('\n')[0]?.trim() ?? '' : ''
  if (pin.startsWith('/') && (await isOpsFork($, pin))) return pin.replace(/\/+$/, '') || '/'
  let dir = (await $.session.cwd()).replace(/\/+$/, '')
  while (dir) {
    if (await isOpsFork($, dir)) return dir
    dir = dir.slice(0, dir.lastIndexOf('/'))
  }
  return null
}

export async function lookupPr($: EngineInterface, repo: string, pr: number): Promise<PrView | null> {
  if (!validRepo(repo)) return null
  try {
    const r = await $.process.run(prViewArgv(repo, pr), { timeoutMs: GH_TIMEOUT_MS })
    return r.exitCode === 0 ? parsePrView(r.stdout) : null
  } catch {
    return null
  }
}

function recordPath(root: string, repo: string, pr: number): string {
  return `${root}/.claude/session/reviews/${repo.replace(/\//g, '__')}__${pr}-ceo.approved`
}

let windowDays = 3
// Rows the operator answered "Not yet" for in this pane, by "repo#pr@sha".
const deferred = new Set<string>()
let running = false

export async function refresh($: EngineInterface): Promise<void> {
  const now = await $.clock.now()
  const root = await opsRoot($)
  if (!root) {
    await update($, view, () => ({ inFork: false, rows: [], busy: false, updatedAt: now }))
    return
  }
  const reviews = `${root}/.claude/session/reviews`
  let entries: { name: string; mtimeMs: number }[] = []
  try {
    entries = await $.fs.list(reviews)
  } catch { /* No reviews folder: no rows. */ }
  const old = (await read($, view))?.rows ?? []
  const rows: GateRow[] = []
  for (const c of candidatesFrom(entries, now, windowDays)) {
    const rexSha = markerSha(await readText($, `${reviews}/${c.name}`))
    const pr = await lookupPr($, c.repo, c.number)
    if (pr && !pr.open) continue
    if (pr && deferred.has(`${c.repo}#${c.number}@${pr.head}`)) continue
    const prev = old.find(r => r.repo === c.repo && r.number === c.number)
    rows.push({
      repo: c.repo,
      number: c.number,
      title: pr?.title ?? '',
      head: pr?.head ?? null,
      rexSha,
      ci: pr?.ci ?? 'unknown',
      open: pr ? pr.open : null,
      note: prev && prev.head === (pr?.head ?? null) ? prev.note : null,
    })
  }
  await update($, view, () => ({ inFork: true, rows, busy: false, updatedAt: now }))
}

function setNote($: EngineInterface, row: Shown, note: string) {
  return update($, view, v => v && ({
    ...v,
    rows: v.rows.map(r => (r.repo === row.repo && r.number === row.number ? { ...r, note } : r)),
  }))
}

// Runs only from the Approve button's press handler: a human key press.
export async function pressApprove($: EngineInterface, row: Shown): Promise<void> {
  if (running) {
    await setNote($, row, 'Another approval is open. Answer it first.')
    return
  }
  running = true
  await update($, view, v => v && { ...v, busy: true })
  try {
    const root = await opsRoot($)
    if (!root) {
      await setNote($, row, 'No ops fork found. Nothing was asked.')
      return
    }
    const deps: Deps = {
      lookup: (repo, pr) => lookupPr($, repo, pr),
      ask: (question, options) => $.ui.ask(question, { options, header: 'Merge' }),
      readRecord: (repo, pr) => readText($, recordPath(root, repo, pr)),
      sleep: ms => $.clock.sleep(ms),
    }
    const out = await approveFlow(deps, row)
    if (out.kind === 'not-yet' && row.head) deferred.add(`${row.repo}#${row.number}@${row.head}`)
    await setNote($, row, out.note)
    if (out.kind === 'recorded') $.ui.toast(`${row.repo}#${row.number}: approval recorded.`)
  } finally {
    running = false
    await update($, view, v => v && { ...v, busy: false })
  }
}

// "Not yet" in the pane: hide the row for this head. Nothing is asked or written.
export async function pressNotYet($: EngineInterface, row: Shown): Promise<void> {
  if (row.head) deferred.add(`${row.repo}#${row.number}@${row.head}`)
  await update($, view, v => v && ({
    ...v,
    rows: v.rows.filter(r => !(r.repo === row.repo && r.number === row.number)),
  }))
  $.ui.toast(`${row.repo}#${row.number}: not yet. Nothing was recorded.`)
}

export const register: Register = (on, options) => {
  const w = Number(options?.waiting_window_days)
  windowDays = Number.isFinite(w) && w >= 0 ? w : 3

  on('session.start', async ($, e, next) => {
    await $.command.register({ name: COMMAND, description: 'Open the ApexYard approval pane (human approval only)' }).catch(() => {})
    return next(e)
  })

  on('command.run', { command: COMMAND }, async $ => {
    await $.ui.open({ id: PANE, title: 'ApexYard approvals' })
    void refresh($).catch(() => {})
    return { text: 'Approval pane opened. Only your key press in the menu approves.' }
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Text, Button } = $.ui.resolve(e)
    const v: GateView | null = await read($, view)
    if (!v) return <Text dimColor>Loading the PRs that wait for your approval…</Text>
    if (!v.inFork) return <Text color="yellow">No ApexYard ops fork found from this session.</Text>
    return (
      <Box flexDirection="column">
        <Text color="cyan">Waiting for your merge approval: {v.rows.length}</Text>
        <Text dimColor>Approve opens the menu. Your choice there records the approval through the menu hook.</Text>
        <Box flexDirection="row">
          <Button key="refresh" plain hotkey="r" label="[r] Refresh" onPress={() => refresh($)} />
        </Box>
        <Text> </Text>
        {v.rows.length === 0 ? <Text dimColor>Nothing waits for your approval.</Text> : null}
        {v.rows.map(r => {
          const id = `${r.repo}#${r.number}`
          const why = blocker(r)
          return (
            <Box key={id} flexDirection="column">
              <Text>{id} <Text dimColor>{r.title}</Text></Text>
              <Text dimColor>  head {r.head ?? '(unknown)'}</Text>
              <Text>  <Text color={r.ci === 'pass' ? 'green' : r.ci === 'fail' ? 'red' : 'yellow'}>{ciLabel(r.ci)}</Text> · {rexVerdict(r)}</Text>
              {why ? <Text color="yellow">  {why}</Text> : null}
              <Box flexDirection="row">
                <Text>  </Text>
                {why || v.busy ? null : <Button key={`approve-${id}`} label="Approve" onPress={() => pressApprove($, r)} />}
                <Text> </Text>
                <Button key={`notyet-${id}`} label="Not yet" onPress={() => pressNotYet($, r)} />
              </Box>
              {r.note ? <Text color="magenta">  {r.note}</Text> : null}
              <Text> </Text>
            </Box>
          )
        })}
      </Box>
    )
  })
}
