// Pure ORBIT summary logic: same rules as `orbit progress` (achieved 1, partly 0.5).
import type { OrbitOutcome, OrbitSummary, SliceLinks } from '../types'

type Json = Record<string, unknown>

const str = (v: unknown): string => (typeof v === 'string' ? v : '')
const arr = (v: unknown): unknown[] => (Array.isArray(v) ? v : [])

export type CriterionStatus = 'not-verified' | 'partially-verified' | 'achieved' | 'contradicted'

// Merge records read from several branches. A later list wins for the same
// record id and revision, so pass the branches oldest-first (main, then dev).
export function mergeRecords(lists: Json[][]): Json[] {
  const out = new Map<string, Json>()
  for (const list of lists) {
    for (const r of list) {
      const id = str(r.id)
      if (!id) continue
      out.set(`${id}@${typeof r.revision === 'number' ? r.revision : ''}`, r)
    }
  }
  return [...out.values()]
}

export function pickPlan(plans: Json[]): Json | null {
  let best: Json | null = null
  for (const p of plans) {
    const rev = typeof p.revision === 'number' ? p.revision : 0
    const bestRev = best && typeof best.revision === 'number' ? best.revision : -1
    if (!best || rev > bestRev) best = p
  }
  return best
}

export function pickReconciliation(recs: Json[], planId: string): Json | null {
  let best: Json | null = null
  for (const r of recs) {
    if (str(r.planId) !== planId) continue
    if (!best || str(r.reconciledAt) > str(best.reconciledAt)) best = r
  }
  return best
}

export function summarize(plan: Json, rec: Json | null, slices: Json[]): OrbitSummary {
  const planId = str(plan.id)
  const status = new Map<string, CriterionStatus>()
  for (const a of arr(rec?.criterionAssessments)) {
    const o = a as Json
    const s = str(o.status) as CriterionStatus
    status.set(str(o.criterionId), s || 'not-verified')
  }
  const criteria = arr(plan.acceptanceCriteria).map(c => c as Json)
  const outcomes: OrbitOutcome[] = arr(plan.outcomes).map(raw => {
    const o = raw as Json
    const id = str(o.id)
    const own = criteria.filter(c => str(c.outcomeId) === id).map(c => {
      const { statement, shownBy } = splitShownBy(str(c.statement))
      return { id: str(c.id), status: status.get(str(c.id)) ?? 'not-verified', statement, shownBy }
    })
    const achieved = own.filter(c => c.status === 'achieved').length
    const partly = own.filter(c => c.status === 'partially-verified').length
    const contradicted = own.filter(c => c.status === 'contradicted').length
    const total = own.length
    const pct = total === 0 ? 0 : Math.round(((achieved + partly * 0.5) / total) * 100)
    return { id, title: str(o.title), pct, achieved, partly, contradicted, total, criteria: own }
  })
  const all = outcomes.flatMap(o => o.criteria)
  return {
    title: str(plan.title),
    checkedAt: null,
    planId,
    revision: typeof plan.revision === 'number' ? plan.revision : 0,
    reconciledAt: rec ? str(rec.reconciledAt) : null,
    outcomes,
    slices: slices
      .filter(s => str(s.planId) === planId)
      .map(s => ({ id: str(s.id), contributesTo: arr(s.contributesTo).map(str) }))
      .sort((a, b) => a.id.localeCompare(b.id, undefined, { numeric: true })),
    totals: {
      achieved: all.filter(c => c.status === 'achieved').length,
      partly: all.filter(c => c.status === 'partially-verified').length,
      contradicted: all.filter(c => c.status === 'contradicted').length,
      total: all.length,
    },
  }
}

// "Do X. Shown by: a test." -> { statement: "Do X.", shownBy: "a test." }
export function splitShownBy(text: string): { statement: string; shownBy: string } {
  const i = text.indexOf(' Shown by:')
  if (i < 0) return { statement: text.trim(), shownBy: '' }
  return { statement: text.slice(0, i).trim(), shownBy: text.slice(i + ' Shown by:'.length).trim() }
}

// A one-line label: the first sentence of the statement.
export function shortLabel(statement: string, max = 70): string {
  const m = statement.match(/^(.+?[.?!])(\s|$)/)
  const head = (m?.[1] ?? statement).trim().replace(/[.]$/, '')
  return clip(head, max)
}

export function clip(text: string, width: number): string {
  if (width < 4 || text.length <= width) return text
  return `${text.slice(0, width - 1).trimEnd()}…`
}

export function bar(pct: number, width = 12): string {
  const filled = Math.round((Math.max(0, Math.min(100, pct)) / 100) * width)
  return '█'.repeat(filled) + '░'.repeat(width - filled)
}

export function statusColor(s: string): string {
  if (s === 'achieved') return 'green'
  if (s === 'partially-verified') return 'yellow'
  if (s === 'contradicted') return 'red'
  return 'gray'
}

export function statusMark(s: string): string {
  if (s === 'achieved') return '✓'
  if (s === 'partially-verified') return '½'
  if (s === 'contradicted') return '×'
  return '·'
}

export function bandText(s: OrbitSummary): string {
  const t = s.totals
  const parts = [`${s.planId} r${s.revision}`, `${t.achieved}/${t.total} achieved`]
  if (t.partly) parts.push(`${t.partly} partly`)
  if (t.contradicted) parts.push(`${t.contradicted} contradicted`)
  return parts.join(' · ')
}

// Outcomes with unmet criteria that no slice contributes to. The pane flags
// them so a missing slice is visible, not only an unused number.
export function uncoveredOutcomes(s: OrbitSummary): OrbitOutcome[] {
  const covered = new Set(s.slices.flatMap(sl => sl.contributesTo))
  return s.outcomes.filter(o => o.pct < 100 && !o.criteria.some(c => covered.has(c.id)))
}

// Only no-change entries inside Checks count. Compare dates, not file order.
export function checksDate(notes: string): string | null {
  let inside = false
  let latest: string | null = null
  for (const line of notes.split('\n')) {
    if (/^##\s+Checks\s*$/.test(line)) { inside = true; continue }
    if (/^#{1,2}\s/.test(line)) inside = false
    if (!inside) continue
    const date = line.match(/^\s*(?:-\s*)?(\d{4}-\d{2}-\d{2}),\s*[^:]+:\s*checked, no change\.\s*$/)?.[1]
    if (date && (!latest || date > latest)) latest = date
  }
  return latest
}

export function inFlightText(links: Array<SliceLinks | undefined>): string {
  if (links.some(l => !l || l.status === 'error')) return 'in flight (offline)'
  if (links.some(l => l?.status === 'loading')) return 'in flight: loading…'
  const issues = new Map<string, SliceLinks['issues'][number]>()
  const prs = new Map<string, SliceLinks['issues'][number]['prs'][number]>()
  let last = ''
  for (const l of links) for (const i of l?.issues ?? []) {
    if (i.updatedAt && i.updatedAt > last) last = i.updatedAt
    if (i.state === 'open') issues.set(`${i.repo}#${i.number}`, i)
    for (const pr of i.prs) {
      if (pr.updatedAt && pr.updatedAt > last) last = pr.updatedAt
      if (i.state === 'open' && pr.state === 'open') prs.set(`${pr.repo}#${pr.number}`, pr)
    }
  }
  const approved = [...prs.values()].filter(p => p.approved).length
  const ready = [...prs.values()].filter(p => p.ready).length
  return `in flight: ${issues.size} open tickets · ${prs.size} open PRs · ${approved} approved · ${ready} ready · last activity ${last || 'none'}`
}
