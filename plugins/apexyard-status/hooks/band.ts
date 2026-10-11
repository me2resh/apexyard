// Pure helpers for the ApexYard status band. No engine calls here, so the
// tests can drive every rule with plain values.

const DAY_MS = 24 * 60 * 60 * 1000
const TITLE_MAX = 48

export type Entry = { name: string; mtimeMs: number }

// AgDR-0060 marker name: <owner>__<repo>__<pr>-<role>.approved
const MARKER = /^(.+)__(.+)__(\d+)-(rex|ceo)\.approved$/

// "me2resh__apexyard__1541-rex.approved" -> "me2resh/apexyard#1541".
// Returns null for a name that does not follow AgDR-0060.
export function markerRef(name: string): string | null {
  const m = name.match(MARKER)
  if (!m) return null
  return `${m[1]}/${m[2]}#${m[3]}`
}

export type Candidate = { name: string; ref: string; repo: string; number: number }

// The Rex markers newer than the window that have no CEO marker. These are
// candidates only: a marker stays after a PR merges outside /approve-merge.
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
    out.push({ name: e.name, ref: `${repo}#${m[3]}`, repo, number: Number(m[3]) })
  }
  return out.sort((x, y) => x.ref.localeCompare(y.ref))
}

// A GitHub owner/repo slug. Anything else is never passed to gh.
export function validRepo(repo: string): boolean {
  return /^[A-Za-z0-9_.][A-Za-z0-9_.-]*\/[A-Za-z0-9_.][A-Za-z0-9_.-]*$/.test(repo) && !repo.split('/').some(p => p === '.' || p === '..')
}

// The reviewed commit in a Rex marker (AgDR-0161: the bare SHA), or null.
export function markerSha(text: string | null): string | null {
  const t = text?.trim().split('\n')[0]?.trim() ?? ''
  return /^[0-9a-f]{7,40}$/i.test(t) ? t.toLowerCase() : null
}

export type OpenPrs = Map<number, string>

// The JSON list of open PRs ({ number, headRefOid } each) -> PR number to
// head SHA. Null when the output is not that shape.
export function parseOpenPrs(stdout: string): OpenPrs | null {
  let v: unknown
  try {
    v = JSON.parse(stdout)
  } catch {
    return null
  }
  if (!Array.isArray(v)) return null
  const out: OpenPrs = new Map()
  for (const x of v) {
    const o = x as { number?: unknown; headRefOid?: unknown }
    if (typeof o.number === 'number' && typeof o.headRefOid === 'string') out.set(o.number, o.headRefOid.toLowerCase())
  }
  return out
}

export const GH_CACHE_MS = 120_000
export const GH_TIMEOUT_MS = 5000

export type GhResult = { exitCode: number; stdout: string }
export type GhRun = (argv: readonly string[]) => Promise<GhResult>
export type GhCache = Map<string, { at: number; open: OpenPrs | null }>

// The read-only list command for one repo. An argument array, no shell.
export function ghArgv(repo: string): string[] {
  return ['gh', 'pr', 'list', '--repo', repo, '--state', 'open', '--json', 'number,headRefOid', '--limit', '200']
}

// The open PRs of one repo, from the cache when the last lookup is newer than
// GH_CACHE_MS. Null when gh is missing, fails or times out, or the repo is not
// a valid slug. A failed lookup is cached too, so gh runs at most once per
// window for each repo.
export async function openPrsFor(cache: GhCache, repo: string, now: number, run: GhRun): Promise<OpenPrs | null> {
  if (!validRepo(repo)) return null
  const hit = cache.get(repo)
  if (hit && now - hit.at < GH_CACHE_MS) return hit.open
  let open: OpenPrs | null = null
  try {
    const r = await run(ghArgv(repo))
    open = r.exitCode === 0 ? parseOpenPrs(r.stdout) : null
  } catch {
    open = null
  }
  cache.set(repo, { at: now, open })
  return open
}

export type Queue = { waiting: string[]; reReview: string[]; offline: boolean }

// Sort the candidates with the open PRs of their repos:
// - open, and the head is the commit Rex reviewed: waiting for /approve-merge
// - open, with another head (or no SHA in the marker): needs re-review
// - not open (merged or closed): dropped
// A repo with no lookup (null) falls back to the marker only: its candidates
// count as waiting and the queue is marked offline.
export function classify(
  cands: Candidate[],
  shas: Map<string, string | null>,
  open: Map<string, OpenPrs | null>,
): Queue {
  const q: Queue = { waiting: [], reReview: [], offline: false }
  for (const c of cands) {
    const prs = open.get(c.repo) ?? null
    if (prs === null) {
      q.waiting.push(c.ref)
      q.offline = true
      continue
    }
    const head = prs.get(c.number)
    if (head === undefined) continue
    const sha = shas.get(c.name) ?? null
    if (sha && head.startsWith(sha)) q.waiting.push(c.ref)
    else q.reReview.push(c.ref)
  }
  return q
}

// The Rex marker names in a directory listing (AgDR-0060 names only).
export function rexMarkers(entries: Entry[]): Set<string> {
  return new Set(entries.filter(e => e.name.endsWith('-rex.approved') && markerRef(e.name)).map(e => e.name))
}

// The Rex markers in `now` that were not in `before`. An empty result when
// `before` is null, so the first refresh of a session never toasts.
export function newMarkers(before: Set<string> | null, now: Set<string>): string[] {
  if (!before) return []
  return [...now].filter(n => !before.has(n)).sort()
}

export type TicketFields = Record<string, string>

export function parseFields(text: string): TicketFields {
  const fields: TicketFields = {}
  for (const line of text.split('\n')) {
    const i = line.indexOf('=')
    if (i > 0) fields[line.slice(0, i).trim()] = line.slice(i + 1).trim()
  }
  return fields
}

// "repo=me2resh/apexyard\nnumber=1541\ntitle=[Feature] Optional status band"
// -> "apexyard#1541 Optional status band". Null when repo or number is missing.
export function ticketLabel(text: string): string | null {
  const f = parseFields(text)
  if (!f.repo || !f.number) return null
  const repo = f.repo.split('/').pop() || f.repo
  const title = (f.title ?? '').replace(/^\[[^\]]+\]\s*/, '')
  const short = title.length > TITLE_MAX ? `${title.slice(0, TITLE_MAX - 1)}…` : title
  return short ? `${repo}#${f.number} ${short}` : `${repo}#${f.number}`
}

// The parent directory of an absolute path, or null at the root.
export function parentDir(path: string): string | null {
  const p = path.replace(/\/+$/, '')
  const i = p.lastIndexOf('/')
  if (i <= 0) return p === '' || i < 0 ? null : '/'
  return p.slice(0, i)
}

// Same anchors as resolve_ops_root_walk in .claude/hooks/_lib-ops-root.sh:
// a .apexyard-fork file, or onboarding.yaml and apexyard.projects.yaml together.
export async function isOpsFork(dir: string, exists: (p: string) => Promise<boolean>): Promise<boolean> {
  if (await exists(`${dir}/.apexyard-fork`)) return true
  return (await exists(`${dir}/onboarding.yaml`)) && (await exists(`${dir}/apexyard.projects.yaml`))
}

// The ops fork: the session pin first, then a walk up from the working directory.
export async function findOpsRoot(
  pinned: string | null,
  cwd: string,
  exists: (p: string) => Promise<boolean>,
): Promise<string | null> {
  const pin = pinned?.split('\n')[0]?.trim() ?? ''
  if (pin.startsWith('/') && (await isOpsFork(pin, exists))) return pin.replace(/\/+$/, '') || '/'
  let dir: string | null = cwd.replace(/\/+$/, '') || '/'
  while (dir) {
    if (await isOpsFork(dir, exists)) return dir
    dir = parentDir(dir)
  }
  return null
}

// Same character rule as active_reviewer_marker_path in _lib-review-markers.sh.
export function safeSessionId(id: string): string {
  return id.replace(/[^A-Za-z0-9._-]/g, '_')
}

// Number of process command lines that match the pattern. Null when the
// pattern is empty or not a valid regular expression (the count is off).
export function countBuilds(psOutput: string, pattern: string): number | null {
  if (!pattern.trim()) return null
  let re: RegExp
  try {
    re = new RegExp(pattern)
  } catch {
    return null
  }
  let n = 0
  for (const line of psOutput.split('\n')) {
    if (line.trim() && re.test(line)) n += 1
  }
  return n
}

// "me2resh/apexyard#1541:rex" -> "me2resh/apexyard#1541 (rex)".
export function lockLabel(text: string): string | null {
  const t = text.trim().split('\n')[0]?.trim() ?? ''
  if (!t) return null
  const m = t.match(/^(.+#\d+):(\w+)$/)
  return m ? `${m[1]} (${m[2]})` : t
}

// All reviewer locks of a session: one label per marker, in order, no duplicates.
// Texts come from the per-review files and the legacy single file.
export function lockLabels(texts: Array<string | null>): string | null {
  const labels: string[] = []
  for (const text of texts) {
    const label = text ? lockLabel(text) : null
    if (label && !labels.includes(label)) labels.push(label)
  }
  return labels.length > 0 ? labels.join(', ') : null
}

// The text of the "waiting" segment. Lists up to three references.
export function waitingText(waiting: string[], offline = false): string {
  const tag = offline ? ' (offline)' : ''
  if (waiting.length === 0) return `nothing waiting for /approve-merge${tag}`
  const shown = waiting.slice(0, 3).join(', ')
  const more = waiting.length > 3 ? ` +${waiting.length - 3}` : ''
  return `${waiting.length} waiting for your /approve-merge${tag}: ${shown}${more}`
}

// The text of the "needs re-review" segment, or null when it is empty.
export function reReviewText(refs: string[]): string | null {
  if (refs.length === 0) return null
  const shown = refs.slice(0, 3).join(', ')
  const more = refs.length > 3 ? ` +${refs.length - 3}` : ''
  return `${refs.length} need${refs.length === 1 ? 's' : ''} re-review: ${shown}${more}`
}
