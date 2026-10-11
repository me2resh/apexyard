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

// The PRs that have a Rex marker newer than the window and no CEO marker.
export function waitingFrom(entries: Entry[], now: number, windowDays: number): string[] {
  const names = new Set(entries.map(e => e.name))
  const windowMs = Math.max(0, windowDays) * DAY_MS
  const out: string[] = []
  for (const e of entries) {
    if (!e.name.endsWith('-rex.approved')) continue
    const ref = markerRef(e.name)
    if (!ref) continue
    if (now - e.mtimeMs > windowMs) continue
    if (names.has(e.name.replace(/-rex\.approved$/, '-ceo.approved'))) continue
    out.push(ref)
  }
  return out.sort()
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

// The label of the marker with the newest started_at value.
export function newestTicket(texts: string[]): string | null {
  let best: { label: string; at: string } | null = null
  for (const text of texts) {
    const label = ticketLabel(text)
    if (!label) continue
    const at = parseFields(text).started_at ?? ''
    if (!best || at > best.at) best = { label, at }
  }
  return best ? best.label : null
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

// The git dir named by a linked worktree's ".git" file ("gitdir: <path>").
export function gitDirFromFile(text: string, worktree: string): string | null {
  const m = text.match(/^gitdir:\s*(.+)$/m)
  const raw = m?.[1]?.trim()
  if (!raw) return null
  return raw.startsWith('/') ? raw : `${worktree}/${raw}`
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

// The text of the "waiting" segment. Lists up to three references.
export function waitingText(waiting: string[]): string {
  if (waiting.length === 0) return 'nothing waiting for /approve-merge'
  const shown = waiting.slice(0, 3).join(', ')
  const more = waiting.length > 3 ? ` +${waiting.length - 3}` : ''
  return `${waiting.length} waiting for your /approve-merge: ${shown}${more}`
}
