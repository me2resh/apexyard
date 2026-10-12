import type { OrbitPlanView, OrbitView, SliceLink, SliceLinks } from '../types'
import { bar, clip, mergeRecords, pickPlan, shortLabel, pickReconciliation, statusColor, statusMark, summarize, uncoveredOutcomes, checksDate, inFlightText } from './orbit'
import { GH_CACHE_MS } from './band'
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

const orbit = atom({ plugin: 'apexyard-status', key: 'orbit' } as const, null)
const ORBIT_PANE = 'orbit-progress'
const ORBIT_REFRESH_MS = 2 * 60 * 1000
const sliceLinks = atom({ plugin: 'apexyard-status', key: 'sliceLinks' } as const, {})
const expanded = atom({ plugin: 'apexyard-status', key: 'expanded' } as const, {})

const orbitState: { lastRun: number | null; root: string | null; repo: string | null } = {
  lastRun: null, root: null, repo: null,
}

// "name/repo/workspace" triples from the portfolio registry (simple line parser).
export function parseRegistry(yaml: string): { repo: string; workspace: string }[] {
  const out: { repo: string; workspace: string }[] = []
  let repo = '', ws = ''
  const flush = () => { if (repo && ws) out.push({ repo, workspace: ws }); repo = ''; ws = '' }
  for (const line of yaml.split('\n')) {
    if (/^\s*- name:/.test(line)) flush()
    const r = line.match(/^\s+repo:\s*["']?([^"'\s#]+)/)
    if (r?.[1]) repo = r[1]
    const w = line.match(/^\s+workspace:\s*["']?([^"'\s#]+)/)
    if (w?.[1]) ws = w[1]
  }
  flush()
  return out
}

// Branches the ORBIT pane reads, oldest first. Framework repos merge to dev
// and release to main, so dev records appear before a release.
const ORBIT_BRANCHES = ['main', 'dev']

async function gitShow($: EngineInterface, clone: string, ref: string, path: string): Promise<unknown | null> {
  try {
    const r = await $.process.run(['git', '-C', clone, 'show', `origin/${ref}:${path}`], { timeoutMs: 5000 })
    return r.exitCode === 0 ? JSON.parse(r.stdout) : null
  } catch {
    return null
  }
}

async function gitList($: EngineInterface, clone: string, ref: string, dir: string): Promise<string[]> {
  try {
    const r = await $.process.run(['git', '-C', clone, 'ls-tree', '--name-only', `origin/${ref}`, `${dir}/`], { timeoutMs: 5000 })
    return r.exitCode === 0 ? r.stdout.split('\n').filter(l => l.endsWith('.json')) : []
  } catch {
    return []
  }
}

async function loadRecords($: EngineInterface, clone: string, dir: string) {
  const lists: Record<string, unknown>[][] = []
  for (const ref of ORBIT_BRANCHES) {
    const out: Record<string, unknown>[] = []
    for (const f of await gitList($, clone, ref, `docs/orbit/${dir}`)) {
      const j = await gitShow($, clone, ref, f)
      if (j && typeof j === 'object') out.push(j as Record<string, unknown>)
    }
    lists.push(out)
  }
  return mergeRecords(lists)
}

export async function refreshOrbit($: EngineInterface, root: string, activeRepo: string | null, force = false) {
  const now = await $.clock.now()
  if (!force && root === orbitState.root && activeRepo === orbitState.repo && orbitState.lastRun !== null && now - orbitState.lastRun < ORBIT_REFRESH_MS) return
  orbitState.lastRun = now
  orbitState.repo = activeRepo
  orbitState.root = root
  let registry = `${root}/apexyard.projects.yaml`
  try {
    const config = JSON.parse(await $.fs.read(`${root}/.claude/project-config.json`))
    const path = config.portfolio?.registry
    if (typeof path === 'string') registry = path.startsWith('/') ? path : `${root}/${path}`
  } catch { /* Missing config uses the single-fork registry. */ }
  const portfolio = registry.slice(0, registry.lastIndexOf('/'))
  let entries: { repo: string; workspace: string }[] = []
  try { entries = parseRegistry(await $.fs.read(registry)) } catch { /* A missing registry produces an empty pane. */ }
  const plans: OrbitPlanView[] = []
  for (const e of entries) {
    const clone = e.workspace.startsWith('/') ? e.workspace : `${portfolio}/${e.workspace}`
    if (!(await exists($, clone))) continue
    const all = await loadRecords($, clone, 'plans')
    if (all.length === 0) continue
    const recs = await loadRecords($, clone, 'reconciliations')
    const slices = await loadRecords($, clone, 'slices')
    const ids = [...new Set(all.map(p => (typeof p.id === 'string' ? p.id : '')))].filter(Boolean).sort()
    for (const id of ids) {
      const plan = pickPlan(all.filter(p => p.id === id))
      if (!plan) continue
      const summary = summarize(plan, pickReconciliation(recs, id), slices)
      for (const ref of ORBIT_BRANCHES) {
        try {
          const r = await $.process.run(['git', '-C', clone, 'show', `origin/${ref}:docs/orbit/plans/${id}.notes.md`], { timeoutMs: GH_TIMEOUT_MS })
          const date = r.exitCode === 0 ? checksDate(r.stdout) : null
          if (date && (!summary.checkedAt || date > summary.checkedAt)) summary.checkedAt = date
        } catch { /* Notes are optional. */ }
      }
      for (const sl of summary.slices) await lookupSlice($, e.repo, sl.id)
      plans.push({ key: `${e.repo}#${id}`, repo: e.repo, summary })
    }
  }
  plans.sort((x, y) => (x.repo === activeRepo ? -1 : y.repo === activeRepo ? 1 : x.key.localeCompare(y.key)))
  const view: OrbitView = { activeRepo, plans, updatedAt: now }
  await update($, orbit, () => view)
}


const queryCache = new Map<string, { at: number; value: unknown[] | null }>()
export async function ghJson($: EngineInterface, argv: string[]): Promise<unknown[] | null> {
  const key = JSON.stringify(argv)
  const now = await $.clock.now()
  const hit = queryCache.get(key)
  if (hit && now - hit.at < GH_CACHE_MS) return hit.value
  let value: unknown[] | null = null
  try {
    const r = await $.process.run(['gh', ...argv], { timeoutMs: GH_TIMEOUT_MS })
    const v: unknown = r.exitCode === 0 ? JSON.parse(r.stdout) : null
    if (Array.isArray(v)) value = v
  } catch { /* Failed queries remain offline until the cache expires. */ }
  queryCache.set(key, { at: now, value })
  return value
}

// True when the text contains the slice ID as a whole token (slice-t1 does not match slice-t10).
export function namesSlice(text: string, sliceId: string): boolean {
  const escaped = sliceId.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
  return new RegExp(`(^|[^A-Za-z0-9_-])${escaped}($|[^A-Za-z0-9_-])`).test(text)
}

// Issues whose body names the slice id, and PRs whose title or body names "#<n>".
export async function lookupSlice($: EngineInterface, owner: string, sliceId: string) {
  const key = `${owner}/${sliceId}`
  const found = await ghJson($, ['search', 'issues', `"${sliceId}"`, '--repo', owner,
    '--json', 'repository,number,title,state,body,updatedAt', '--limit', '20'])
  const issues: SliceLinks['issues'] = []
  let offline = found === null
  for (const raw of found ?? []) {
    const i = raw as { repository?: { nameWithOwner?: string }; number?: number; title?: string; state?: string; body?: string; updatedAt?: string }
    if (!namesSlice(i.body ?? '', sliceId)) continue
    const repo = i.repository?.nameWithOwner ?? owner
    if (typeof i.number !== 'number') continue
    const prsRaw = await ghJson($, ['pr', 'list', '--repo', repo, '--state', 'all',
      '--search', `#${i.number} in:title,body`, '--json', 'number,title,body,state,updatedAt,reviewDecision,mergeStateStatus,isDraft', '--limit', '20'])
    if (prsRaw === null) offline = true
    const prs: SliceLink[] = []
    for (const rawPr of prsRaw ?? []) {
      const pr = rawPr as { number?: number; title?: string; body?: string; state?: string; updatedAt?: string; reviewDecision?: string; mergeStateStatus?: string; isDraft?: boolean }
      if (typeof pr.number !== 'number' || !new RegExp(`#${i.number}(?![0-9])`).test(`${pr.title ?? ''} ${pr.body ?? ''}`)) continue
      prs.push({ repo, number: pr.number, title: pr.title ?? '', state: (pr.state ?? '').toLowerCase(),
        updatedAt: pr.updatedAt, approved: pr.reviewDecision === 'APPROVED', ready: pr.mergeStateStatus === 'CLEAN' && pr.isDraft === false })
    }
    issues.push({ repo, number: i.number, title: i.title ?? '', state: (i.state ?? '').toLowerCase(), updatedAt: i.updatedAt, prs })
  }
  issues.sort((a, b) => a.state === b.state ? b.number - a.number : a.state === 'open' ? -1 : 1)
  const done: SliceLinks = { status: offline ? 'error' : 'done', issues }
  await update($, sliceLinks, cur => ({ ...cur, [key]: done }))
}


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

function markerRepo(text: string | null): string | null {
  return text?.match(/^repo=(.+)$/m)?.[1]?.trim() ?? null
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
    await update($, orbit, () => null)
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
  await refreshOrbit($, root, markerRepo(marker))
}

export const register: Register = (on, options) => {

  on('command.run', { command: 'orbit-progress' }, async $ => {
    await $.ui.open({ id: ORBIT_PANE, title: 'ORBIT initiatives' })
    return { text: 'ORBIT initiatives pane opened (read-only).' }
  })

  on('ui.render', { component: 'Pane', requestId: ORBIT_PANE }, async ($, e) => {
    const { Box, Text, Button } = $.ui.resolve(e)
    const v = await read($, orbit)
    const open = await read($, expanded)
    const links_ = await read($, sliceLinks)
    if (!v) return <Text dimColor>Loading ORBIT initiatives…</Text>
    if (v.plans.length === 0) return <Text color="yellow">No ORBIT initiatives found in the registered repos (docs/orbit on origin/main and origin/dev).</Text>
    const isOpen = (key: string, dflt: boolean) => open[key] ?? dflt
    const toggle = (key: string, dflt: boolean) => () => update($, expanded, cur => ({ ...cur, [key]: !(cur[key] ?? dflt) }))
    const repos = new Set(v.plans.map(p => p.repo)).size
    const width = e.props.bodyColumns ?? e.viewport?.columns ?? 100
    // Column widths: size each label column to its longest entry so bars line up.
    const planLabel = (p: (typeof v.plans)[number]) => `${p.repo} · ${p.summary.title || "Untitled initiative"}`
    const planW = Math.min(Math.max(...v.plans.map(p => planLabel(p).length)), Math.max(30, width - 40))
    const outcomeW = Math.min(Math.max(20, ...v.plans.flatMap(p => p.summary.outcomes.map(o => o.id.length))), Math.max(20, width - 40))
    return (
      <Box flexDirection="column">
        <Text color="cyan">ORBIT initiatives · {v.plans.length} in {repos} repos · press 1–9 or click ▸ to expand</Text>
        <Text dimColor>read-only · origin/main + origin/dev · refreshes every 2 minutes</Text>
        <Text> </Text>
        {v.plans.map((p, i) => {
          const s = p.summary
          const planDefault = p.repo === v.activeRepo && i === 0
          const planOpen = isOpen(p.key, planDefault)
          const t = s.totals
          const pct = t.total === 0 ? 0 : Math.round(((t.achieved + t.partly * 0.5) / t.total) * 100)
          return (
            <Box key={p.key} flexDirection="column">
              <Box flexDirection="row">
                <Button
                  key={`plan-${p.key}`}
                  plain
                  hotkey={i < 9 ? String(i + 1) : undefined}
                  label={`${planOpen ? '▾' : '▸'} ${clip(planLabel(p), planW).padEnd(planW)}`}
                  onPress={toggle(p.key, planDefault)}
                />
                <Text>  </Text>
                <Text color={t.contradicted ? 'red' : 'cyan'}>{bar(pct, 10)}</Text>
                <Text> {String(pct).padStart(3)}%  {`${t.achieved}/${t.total}`.padStart(5)}{t.partly ? ` · ${t.partly} partly` : ''}{t.contradicted ? ` · ${t.contradicted} contradicted` : ''}</Text>
              </Box>
              <Text dimColor>  {inFlightText(s.slices.map(sl => links_[`${p.repo}/${sl.id}`]))}</Text>
              {planOpen ? (
                <Box flexDirection="column">
                  <Text dimColor>    {s.planId} r{s.revision} · reconciled {s.reconciledAt ?? 'never'} · checked {s.checkedAt ?? 'never'}</Text>
                  {s.outcomes.map(o => {
                    const noSlice = uncoveredOutcomes(s).some(u => u.id === o.id)
                    const okey = `${p.key}/${o.id}`
                    const oOpen = isOpen(okey, false)
                    return (
                      <Box key={okey} flexDirection="column">
                        <Box flexDirection="row">
                          <Text>    </Text>
                          <Button key={`o-${okey}`} plain label={`${oOpen ? '▾' : '▸'} ${clip(o.id, outcomeW).padEnd(outcomeW)}`} onPress={toggle(okey, false)} />
                          <Text color={o.pct >= 100 ? 'green' : o.contradicted ? 'red' : 'cyan'}>  {bar(o.pct, 10)}</Text>
                          <Text> {String(o.pct).padStart(3)}%  {`${o.achieved}/${o.total}`.padStart(5)}</Text>
                          {noSlice ? <Text dimColor>  · no slice</Text> : null}
                        </Box>
                        {oOpen ? (
                          <Box flexDirection="column">
                            {o.title ? <Text dimColor>        {clip(o.title, width - 8)}</Text> : null}
                            {o.criteria.map(c => {
                              const ckey = `${okey}/${c.id}`
                              const cOpen = isOpen(ckey, false)
                              return (
                                <Box key={c.id} flexDirection="column" paddingLeft={8}>
                                  <Box flexDirection="row">
                                    <Text color={statusColor(c.status)}>{statusMark(c.status)} </Text>
                                    <Button
                                      key={`c-${ckey}`}
                                      plain
                                      label={`${c.id.padEnd(6)} ${shortLabel(c.statement, Math.max(30, width - 20))}`}
                                      onPress={toggle(ckey, false)}
                                    />
                                  </Box>
                                  {c.shownBy ? (
                                    <Box paddingLeft={9}>
                                      <Text dimColor>proof: {clip(c.shownBy, Math.max(20, width - 26))}</Text>
                                    </Box>
                                  ) : null}
                                  {cOpen ? (
                                    <Box flexDirection="column" paddingLeft={9} width={Math.max(20, width - 10)}>
                                      <Text dimColor>{c.statement}</Text>
                                    </Box>
                                  ) : null}
                                </Box>
                              )
                            })}
                          </Box>
                        ) : null}
                      </Box>
                    )
                  })}
                  {s.slices.map(sl => {
                    const skey = `${p.key}/slice/${sl.id}`
                    const sOpen = isOpen(skey, false)
                    const links = links_[`${p.repo}/${sl.id}`]
                    const owner = p.repo
                    return (
                      <Box key={skey} flexDirection="column" paddingLeft={4}>
                        <Button
                          key={`s-${skey}`}
                          plain
                          label={`${sOpen ? '▾' : '▸'} ⬡ ${sl.id} → ${sl.contributesTo.join(', ')}`}
                          onPress={async () => {
                            await toggle(skey, false)()
                            if (!sOpen) await lookupSlice($, owner, sl.id)
                          }}
                        />
                        {sOpen ? (
                          <Box flexDirection="column" paddingLeft={4}>
                            {!links || links.status === 'loading' ? <Text dimColor>{links?.issues.length ? 'refreshing…' : 'looking up issues…'}</Text> : null}
                            {links?.status === 'error' ? <Text dimColor>(offline)</Text> : null}
                            {links && links.status === 'done' && links.issues.length === 0 ? <Text dimColor>no issues mention this slice yet</Text> : null}
                            {links ? links.issues.map(i => (
                              <Box key={`${i.repo}#${i.number}`} flexDirection="column">
                                <Text>
                                  <Text color={i.state === 'open' ? 'green' : 'gray'}>{i.state === 'open' ? '●' : '○'} </Text>
                                  {i.repo}#{i.number} <Text dimColor>{clip(i.title, Math.max(20, width - i.repo.length - 20))}</Text>
                                </Text>
                                {i.prs.map(pr => (
                                  <Text key={`pr-${pr.number}`} dimColor>
                                    {'    '}↳ PR #{pr.number} [{pr.state}] {clip(pr.title, Math.max(20, width - 30))}
                                  </Text>
                                ))}
                              </Box>
                            )) : null}
                          </Box>
                        ) : null}
                      </Box>
                    )
                  })}
                  <Text> </Text>
                </Box>
              ) : null}
            </Box>
          )
        })}
        <Text dimColor>✓ achieved  ½ partly  × contradicted  · not verified</Text>
      </Box>
    )
  })


  settings = readSettings(options)

  on('session.start', async ($, e, next) => {
    await $.command.register({ name: 'orbit-progress', description: 'Show ORBIT initiatives (display only)' })
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
