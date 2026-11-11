// Pure rules for the ApexYard approval pane (AgDR-0296). No engine calls
// here, so the tests can drive every rule with plain values.
//
// The pane never writes a file and never merges. It asks the question that
// the AgDR-0234 menu hook reads. The hook, not the pane, writes the record.

import type { CiState, GateRow } from '../types'

// The exact approve label and question shape that the AgDR-0234 menu hook
// accepts for a merge approval. See .claude/hooks/_lib-menu-approval.sh.
export const APPROVE_LABEL = 'Approve and merge'
export const NOT_YET_LABEL = 'Not yet'

const FULL_SHA = /^[0-9a-f]{40}$/

export function approvalQuestion(repo: string, pr: number, sha: string): string {
  return `${APPROVE_LABEL} ${repo}#${pr} at ${sha}?`
}

// A GitHub owner/repo slug. Anything else is never passed to gh.
export function validRepo(repo: string): boolean {
  return /^[A-Za-z0-9_.][A-Za-z0-9_.-]*\/[A-Za-z0-9_.][A-Za-z0-9_.-]*$/.test(repo) && !repo.split('/').some(p => p === '.' || p === '..')
}

export type Entry = { name: string; mtimeMs: number }
export type Candidate = { name: string; repo: string; number: number }

// AgDR-0060 marker name: <owner>__<repo>__<pr>-<role>.approved
const MARKER = /^(.+)__(.+)__(\d+)-(rex|ceo)\.approved$/
const DAY_MS = 24 * 60 * 60 * 1000

// Rex markers newer than the window that have no CEO marker.
export function candidatesFrom(entries: Entry[], now: number, windowDays: number): Candidate[] {
  const names = new Set(entries.map(e => e.name))
  const windowMs = Math.max(0, windowDays) * DAY_MS
  const out: Candidate[] = []
  for (const e of entries) {
    const m = e.name.match(MARKER)
    if (!m || m[4] !== 'rex') continue
    if (now - e.mtimeMs > windowMs) continue
    if (names.has(e.name.replace(/-rex\.approved$/, '-ceo.approved'))) continue
    const repo = `${m[1]}/${m[2]}`
    if (!validRepo(repo)) continue
    out.push({ name: e.name, repo, number: Number(m[3]) })
  }
  return out.sort((x, y) => `${x.repo}#${x.number}`.localeCompare(`${y.repo}#${y.number}`))
}

// The reviewed commit in a Rex marker (AgDR-0161: the bare SHA), or null.
export function markerSha(text: string | null): string | null {
  const t = text?.trim().split('\n')[0]?.trim() ?? ''
  return /^[0-9a-f]{7,40}$/i.test(t) ? t.toLowerCase() : null
}

// The SHA in an approval record (`sha=<40-hex>` line), or null. Read only.
export function recordSha(text: string | null): string | null {
  const m = text?.match(/^sha=([0-9a-f]{40})$/m)
  return m?.[1] ?? null
}

// The statusCheckRollup list from gh -> one CI word.
export function ciState(rollup: unknown): CiState {
  if (!Array.isArray(rollup)) return 'unknown'
  if (rollup.length === 0) return 'none'
  let pending = false
  for (const raw of rollup) {
    const c = (raw ?? {}) as { status?: unknown; conclusion?: unknown; state?: unknown }
    const word = String(c.conclusion ?? c.state ?? '').toUpperCase()
    if (['FAILURE', 'CANCELLED', 'TIMED_OUT', 'ERROR', 'ACTION_REQUIRED', 'STARTUP_FAILURE'].includes(word)) return 'fail'
    if (c.state !== undefined && c.conclusion === undefined) {
      if (word !== 'SUCCESS') pending = true
      continue
    }
    const status = String(c.status ?? 'COMPLETED').toUpperCase()
    if (status !== 'COMPLETED' || !['SUCCESS', 'NEUTRAL', 'SKIPPED'].includes(word)) pending = true
  }
  return pending ? 'pending' : 'pass'
}

export type PrView = { open: boolean; head: string; title: string; ci: CiState }

// The read-only gh call for one PR. An argument array, no shell.
export function prViewArgv(repo: string, pr: number): string[] {
  return ['gh', 'pr', 'view', String(pr), '--repo', repo, '--json', 'state,headRefOid,title,statusCheckRollup']
}

export function parsePrView(stdout: string): PrView | null {
  let v: { state?: unknown; headRefOid?: unknown; title?: unknown; statusCheckRollup?: unknown }
  try {
    v = JSON.parse(stdout)
  } catch {
    return null
  }
  if (!v || typeof v !== 'object' || typeof v.headRefOid !== 'string') return null
  const head = v.headRefOid.toLowerCase()
  if (!FULL_SHA.test(head)) return null
  return { open: v.state === 'OPEN', head, title: typeof v.title === 'string' ? v.title : '', ci: ciState(v.statusCheckRollup) }
}

// The Rex verdict line for a row.
export function rexVerdict(row: Pick<GateRow, 'rexSha' | 'head'>): string {
  if (!row.rexSha) return 'Rex: no reviewed SHA in the marker'
  if (row.head && row.head.startsWith(row.rexSha)) return `Rex: approved at ${row.rexSha.slice(0, 7)}`
  return `Rex: reviewed ${row.rexSha.slice(0, 7)}, head moved, re-review needed`
}

// Why the pane does not offer Approve for this row, or null when it does.
export function blocker(row: Pick<GateRow, 'open' | 'head' | 'rexSha' | 'ci'>): string | null {
  if (row.open !== true) return 'The PR state is not known to be open.'
  if (!row.head || !FULL_SHA.test(row.head)) return 'The head SHA is not known.'
  if (!row.rexSha || !row.head.startsWith(row.rexSha)) return 'Rex did not approve this head.'
  if (row.ci === 'fail') return 'CI fails on this head.'
  return null
}

export type Shown = Pick<GateRow, 'repo' | 'number' | 'head' | 'rexSha' | 'ci' | 'open'>

export type Deps = {
  // A fresh, uncached read of the PR. Null when gh fails.
  lookup: (repo: string, pr: number) => Promise<PrView | null>
  // The engine's AskUserQuestion dialog ($.ui.ask). Rejects with no answer.
  ask: (question: string, options: readonly string[]) => Promise<string>
  // Read the CEO record that the menu hook writes. Null when it is absent.
  readRecord: (repo: string, pr: number) => Promise<string | null>
  sleep: (ms: number) => Promise<void>
}

export type Outcome = {
  kind: 'refused' | 'stale' | 'no-answer' | 'not-yet' | 'recorded' | 'not-recorded'
  note: string
}

const RECORD_POLLS = 5
const RECORD_POLL_MS = 400

// The approval flow. Only a pane key press calls it. It asks the AgDR-0234
// question for the exact SHA the pane showed, and then reads back what the
// hook recorded. It writes nothing.
export async function approveFlow(deps: Deps, shown: Shown): Promise<Outcome> {
  const why = blocker(shown)
  if (why) return { kind: 'refused', note: `${why} Nothing was asked.` }
  const head = shown.head as string
  const short = head.slice(0, 7)
  const live = await deps.lookup(shown.repo, shown.number)
  if (!live) return { kind: 'refused', note: 'Could not read the PR from GitHub. Nothing was asked.' }
  if (!live.open) return { kind: 'refused', note: 'The PR is not open. Nothing was asked.' }
  if (live.head !== head) {
    return { kind: 'stale', note: `The head moved from ${short} to ${live.head.slice(0, 7)} after the pane showed it. Refresh, check again, and press again. Nothing was asked.` }
  }
  if (live.ci === 'fail') return { kind: 'refused', note: 'CI fails on this head. Nothing was asked.' }
  let answer: string
  try {
    answer = await deps.ask(approvalQuestion(shown.repo, shown.number, head), [APPROVE_LABEL, NOT_YET_LABEL])
  } catch {
    return { kind: 'no-answer', note: 'The menu closed with no answer. Nothing was recorded.' }
  }
  if (answer !== APPROVE_LABEL) return { kind: 'not-yet', note: 'Not yet. Nothing was recorded.' }
  for (let i = 0; i < RECORD_POLLS; i++) {
    if (recordSha(await deps.readRecord(shown.repo, shown.number)) === head) {
      const after = await deps.lookup(shown.repo, shown.number)
      if (after && after.head !== head) {
        return { kind: 'recorded', note: `The menu hook recorded ${short}, but the head is now ${after.head.slice(0, 7)}. The merge gate will refuse the old SHA.` }
      }
      return { kind: 'recorded', note: `The menu hook recorded your approval for ${short}. Ask Claude to merge. The merge gate checks the record.` }
    }
    await deps.sleep(RECORD_POLL_MS)
  }
  return { kind: 'not-recorded', note: `The menu hook wrote no record for ${short}. Use /approve-merge instead.` }
}

export function ciLabel(ci: CiState): string {
  return ci === 'none' ? 'CI: no checks' : `CI: ${ci}`
}
