// ApexYard status band. Display only: it reads files under the ops fork and
// draws one line above the prompt. It never writes a file and never replaces
// a shell hook. All gates stay in .claude/hooks/.
import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { Band } from '../types'
import {
  countBuilds,
  findOpsRoot,
  gitDirFromFile,
  lockLabel,
  markerRef,
  newestTicket,
  newMarkers,
  parentDir,
  rexMarkers,
  safeSessionId,
  waitingFrom,
  waitingText,
} from './band'

const band = atom({ plugin: 'apexyard-status', key: 'band' } as const, null)

const REFRESH_MS = 30_000

type Settings = { pattern: string; windowDays: number }

export function readSettings(options: Readonly<Record<string, unknown>> | undefined): Settings {
  const p = options?.build_process_pattern
  const w = options?.waiting_window_days
  const days = typeof w === 'number' ? w : Number(w)
  return {
    pattern: typeof p === 'string' ? p : '',
    windowDays: Number.isFinite(days) && days >= 0 ? days : 3,
  }
}

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

// The per-tree ticket marker (AgDR-0222) of the working tree that holds `cwd`.
async function treeTicket($: EngineInterface, cwd: string): Promise<string | null> {
  let dir: string | null = cwd
  while (dir) {
    const dotGit = `${dir}/.git`
    if (await exists($, dotGit)) {
      let gitDir: string | null = dotGit
      try {
        const st = await $.fs.stat(dotGit)
        if (st.kind === 'file') gitDir = gitDirFromFile((await readText($, dotGit)) ?? '', dir)
      } catch {
        gitDir = null
      }
      return gitDir ? readText($, `${gitDir}/apexyard-ticket`) : null
    }
    dir = parentDir(dir)
  }
  return null
}

// The old-layout markers under <ops>/.claude/session/: current-ticket and tickets/**.
async function legacyTickets($: EngineInterface, session: string): Promise<string[]> {
  const texts: string[] = []
  const current = await readText($, `${session}/current-ticket`)
  if (current) texts.push(current)
  try {
    for (const p of await $.fs.list(`${session}/tickets`)) {
      const path = `${session}/tickets/${p.name}`
      if (p.kind === 'file') {
        const t = await readText($, path)
        if (t) texts.push(t)
      } else if (p.kind === 'dir') {
        for (const b of await $.fs.list(path)) {
          if (b.kind !== 'file') continue
          const t = await readText($, `${path}/${b.name}`)
          if (t) texts.push(t)
        }
      }
    }
  } catch {}
  return texts
}

type Seen = { rex: Set<string> | null; builds: number | null }

// Module state. A reload of the module starts these over, so the first
// refresh after a reload seeds them and does not toast.
const seen: Seen = { rex: null, builds: null }
let settings: Settings = readSettings(undefined)
let busy = false

async function refresh($: EngineInterface) {
  if (busy) return
  busy = true
  try {
    await refreshOnce($)
  } finally {
    busy = false
  }
}

async function refreshOnce($: EngineInterface) {
  const cwd = await $.session.cwd()
  const sid = await $.session.id()
  const home = await $.env.get('HOME')
  const pinDir = (await $.env.get('APEXYARD_OPS_PIN_DIR')) || (home ? `${home}/.claude/apexyard` : '')
  const pinned = pinDir ? await readText($, `${pinDir}/ops-root-${sid}`) : null
  const root = await findOpsRoot(pinned, cwd, p => exists($, p))
  if (!root) {
    await update($, band, () => null)
    return
  }
  const session = `${root}/.claude/session`

  const own = await treeTicket($, cwd)
  const ticket = newestTicket(own ? [own] : []) ?? newestTicket(await legacyTickets($, session))

  let waiting: string[] = []
  let rexNow = new Set<string>()
  try {
    const entries = await $.fs.list(`${session}/reviews`)
    waiting = waitingFrom(entries, await $.clock.now(), settings.windowDays)
    rexNow = rexMarkers(entries)
  } catch {}

  const lockText = await readText($, `${session}/active-reviewer.${safeSessionId(sid)}`)
  const reviewLock = lockText ? lockLabel(lockText) : null

  let builds: number | null = null
  if (settings.pattern.trim()) {
    try {
      const r = await $.process.run(['ps', '-axo', 'command='], { timeoutMs: 5000 })
      if (r.exitCode === 0) builds = countBuilds(r.stdout, settings.pattern)
    } catch {}
  }

  for (const name of newMarkers(seen.rex, rexNow)) {
    $.ui.toast(`Rex approved ${markerRef(name) ?? name}. It waits for your /approve-merge.`)
  }
  if (seen.builds !== null && builds !== null && builds < seen.builds) {
    const ended = seen.builds - builds
    $.ui.toast(`${ended} build process${ended === 1 ? '' : 'es'} ended. ${builds} still running.`)
  }
  seen.rex = rexNow
  seen.builds = builds

  const next: Band = { ticket, waiting, reviewLock, builds }
  await update($, band, () => next)
}

export const register: Register = (on, options) => {
  settings = readSettings(options)

  on('session.start', async ($, e, next) => {
    const result = await next(e)
    await refresh($)
    $.clock.every(REFRESH_MS, () => {
      void refresh($)
    })
    return result
  })

  on('turn.complete', async ($, e, next) => {
    const result = await next(e)
    await refresh($)
    return result
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const b = await read($, band)
    if (e.props.hasSurvey || b === null) return next(e)
    const { Box, Text } = $.ui.resolve(e)
    return (
      <Box flexDirection="row" flexWrap="wrap">
        <Text key="brand" color="cyan">ApexYard </Text>
        <Text key="ticket">{b.ticket ?? 'no active ticket'}</Text>
        <Text key="sep1" dimColor> · </Text>
        <Text key="waiting" color={b.waiting.length ? 'yellow' : undefined} dimColor={b.waiting.length === 0}>
          {waitingText(b.waiting)}
        </Text>
        {b.reviewLock ? <Text key="sep2" dimColor> · </Text> : null}
        {b.reviewLock ? <Text key="lock" color="magenta">review lock: {b.reviewLock}</Text> : null}
        {b.builds !== null ? <Text key="sep3" dimColor> · </Text> : null}
        {b.builds !== null ? (
          <Text key="builds" dimColor={b.builds === 0}>
            {b.builds} build{b.builds === 1 ? '' : 's'} running
          </Text>
        ) : null}
      </Box>
    )
  })
}
