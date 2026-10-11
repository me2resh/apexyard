// ApexYard status band. Display only: it reads files under the ops fork,
// runs read-only commands (the ticket resolver, one cached open-PR list per
// repo, and ps when a build pattern is set) and draws one line above the
// prompt. It never writes a file and never replaces a shell hook. All gates
// stay in .claude/hooks/.
import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { Band } from '../types'
import {
  candidatesFrom,
  classify,
  countBuilds,
  GH_TIMEOUT_MS,
  markerSha,
  openPrsFor,
  reReviewText,
  findOpsRoot,
  lockLabels,
  markerRef,
  newMarkers,
  rexMarkers,
  safeSessionId,
  ticketLabel,
  waitingText,
} from './band'
import type { GhCache, OpenPrs } from './band'

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

// The resolver command. It sources the framework's ticket-marker resolver
// (_lib-active-ticket.sh, AgDR-0222) from the ops fork and prints the marker
// that governs the working directory. The resolver applies the location rules
// (the marker in the git dir of the working tree first, then the old layout)
// and validates the tree. Read only: init and lookup write nothing.
export const RESOLVE_TICKET =
  '. "$1/.claude/hooks/_lib-active-ticket.sh" && active_ticket_init "$2" && active_ticket_lookup "$2" && cat "$REPLY"'

// The text of the ticket marker that governs `cwd`, or null.
async function resolvedTicket($: EngineInterface, root: string, cwd: string): Promise<string | null> {
  if (!(await exists($, `${root}/.claude/hooks/_lib-active-ticket.sh`))) return null
  try {
    const r = await $.process.run(['bash', '-c', RESOLVE_TICKET, '_', root, cwd], { cwd, timeoutMs: 5000 })
    return r.exitCode === 0 && r.stdout.trim() ? r.stdout : null
  } catch {
    return null
  }
}

type Seen = { rex: Set<string> | null; builds: number | null }

// Module state. A reload of the module starts these over, so the first
// refresh after a reload seeds them and does not toast.
const seen: Seen = { rex: null, builds: null }
// Open PRs per repo, in memory only. openPrsFor refreshes an entry at most
// once every GH_CACHE_MS.
const ghCache: GhCache = new Map()
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
  // APEXYARD_OPS_DISABLE_PIN=1 ignores the pin, as resolve_ops_root does.
  const pinOff = (await $.env.get('APEXYARD_OPS_DISABLE_PIN')) === '1'
  const pinned = pinDir && !pinOff ? await readText($, `${pinDir}/ops-root-${sid}`) : null
  const root = await findOpsRoot(pinned, cwd, p => exists($, p))
  if (!root) {
    await update($, band, () => null)
    return
  }
  const session = `${root}/.claude/session`

  const marker = await resolvedTicket($, root, cwd)
  const ticket = marker ? ticketLabel(marker) : null

  let waiting: string[] = []
  let reReview: string[] = []
  let offline = false
  let rexNow = new Set<string>()
  try {
    const reviews = `${session}/reviews`
    const entries = await $.fs.list(reviews)
    const now = await $.clock.now()
    rexNow = rexMarkers(entries)
    const cands = candidatesFrom(entries, now, settings.windowDays)
    const shas = new Map<string, string | null>()
    const open = new Map<string, OpenPrs | null>()
    for (const c of cands) {
      shas.set(c.name, markerSha(await readText($, `${reviews}/${c.name}`)))
      if (!open.has(c.repo)) {
        open.set(c.repo, await openPrsFor(ghCache, c.repo, now, argv => $.process.run(argv, { timeoutMs: GH_TIMEOUT_MS })))
      }
    }
    const q = classify(cands, shas, open)
    waiting = q.waiting
    reReview = q.reReview
    offline = q.offline
  } catch {}

  // One marker file per review (me2resh/apexyard#1649), plus the legacy single
  // file that is still read during the transition.
  const safeSid = safeSessionId(sid)
  const lockTexts: Array<string | null> = []
  try {
    const setDir = `${session}/active-reviewers/${safeSid}`
    for (const name of await $.fs.list(setDir)) lockTexts.push(await readText($, `${setDir}/${name}`))
  } catch {}
  lockTexts.push(await readText($, `${session}/active-reviewer.${safeSid}`))
  const reviewLock = lockLabels(lockTexts)

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

  const next: Band = { ticket, waiting, reReview, offline, reviewLock, builds }
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
          {waitingText(b.waiting, b.offline)}
        </Text>
        {b.reReview.length ? <Text key="sep4" dimColor> · </Text> : null}
        {b.reReview.length ? <Text key="rereview" color="magenta">{reReviewText(b.reReview)}</Text> : null}
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
