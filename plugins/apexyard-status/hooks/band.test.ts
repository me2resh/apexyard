import { describe, expect, test } from 'claude-code/testing'

import {
  candidatesFrom,
  classify,
  countBuilds,
  findOpsRoot,
  ghArgv,
  lockLabel,
  lockLabels,
  markerRef,
  markerSha,
  newMarkers,
  openPrsFor,
  parseOpenPrs,
  parentDir,
  reReviewText,
  rexMarkers,
  safeSessionId,
  ticketLabel,
  validRepo,
  waitingText,
} from './band'
import type { Candidate, GhCache, GhRun, OpenPrs } from './band'
import { readSettings, RESOLVE_TICKET } from './register'

const DAY = 24 * 60 * 60 * 1000

describe('review markers (AgDR-0060 names)', () => {
  test('a marker name maps to owner/repo#N', async () => {
    expect(markerRef('me2resh__apexyard__1541-rex.approved')).toBe('me2resh/apexyard#1541')
    expect(markerRef('acme__my_repo.js__7-ceo.approved')).toBe('acme/my_repo.js#7')
  })

  test('a bare-number marker is not an AgDR-0060 name', async () => {
    expect(markerRef('429-rex.approved')).toBe(null)
  })

  test('candidates = recent Rex marker and no CEO marker', async () => {
    const now = 10 * DAY
    const entries = [
      { name: 'me2resh__apexyard__11-rex.approved', mtimeMs: now - 60_000 },
      { name: 'me2resh__apexyard__11-ceo.approved', mtimeMs: now - 30_000 },
      { name: 'acme__infra__176-rex.approved', mtimeMs: now - 60_000 },
      { name: 'acme__infra__20-rex.approved', mtimeMs: now - 5 * DAY },
      { name: '429-rex.approved', mtimeMs: now },
      { name: 'acme__infra__30-architecture.approved', mtimeMs: now },
    ]
    const refs = (days: number) => candidatesFrom(entries, now, days).map(c => c.ref)
    expect(refs(3)).toEqual(['acme/infra#176'])
    expect(refs(7)).toEqual(['acme/infra#176', 'acme/infra#20'])
    expect(candidatesFrom(entries, now, 3)[0]).toEqual({
      name: 'acme__infra__176-rex.approved',
      ref: 'acme/infra#176',
      repo: 'acme/infra',
      number: 176,
    })
  })

  test('the first refresh never toasts; later ones toast only new Rex markers', async () => {
    const first = rexMarkers([{ name: 'a__b__1-rex.approved', mtimeMs: 0 }])
    expect(newMarkers(null, first)).toEqual([])
    const second = rexMarkers([
      { name: 'a__b__1-rex.approved', mtimeMs: 0 },
      { name: 'a__b__2-rex.approved', mtimeMs: 0 },
      { name: 'a__b__2-ceo.approved', mtimeMs: 0 },
    ])
    expect(newMarkers(first, second)).toEqual(['a__b__2-rex.approved'])
  })

  test('waiting text lists up to three references', async () => {
    expect(waitingText([])).toBe('nothing waiting for /approve-merge')
    expect(waitingText(['a/b#1', 'a/b#2', 'a/b#3', 'a/b#4'])).toBe(
      '4 waiting for your /approve-merge: a/b#1, a/b#2, a/b#3 +1',
    )
    expect(waitingText(['a/b#1'], true)).toBe('1 waiting for your /approve-merge (offline): a/b#1')
    expect(waitingText([], true)).toBe('nothing waiting for /approve-merge (offline)')
  })

  test('re-review text', async () => {
    expect(reReviewText([])).toBe(null)
    expect(reReviewText(['a/b#1'])).toBe('1 needs re-review: a/b#1')
    expect(reReviewText(['a/b#1', 'a/b#2'])).toBe('2 need re-review: a/b#1, a/b#2')
  })

  test('the marker SHA is the bare reviewed commit', async () => {
    expect(markerSha('ABCDEF1234567\n')).toBe('abcdef1234567')
    expect(markerSha('')).toBe(null)
    expect(markerSha('approved by rex')).toBe(null)
    expect(markerSha(null)).toBe(null)
  })
})

const SHA_A = 'a'.repeat(40)
const SHA_B = 'b'.repeat(40)
const cand = (repo: string, n: number): Candidate => ({
  name: `${repo.replace('/', '__')}__${n}-rex.approved`,
  ref: `${repo}#${n}`,
  repo,
  number: n,
})

describe('open-PR check (cached, read only)', () => {
  test('open with the reviewed head -> waiting; another head -> re-review; not open -> dropped', async () => {
    const c1 = cand('me2resh/apexyard', 1)
    const c2 = cand('me2resh/apexyard', 2)
    const c3 = cand('me2resh/apexyard', 3)
    const shas = new Map([[c1.name, SHA_A], [c2.name, SHA_A], [c3.name, SHA_A]])
    const open = new Map<string, OpenPrs | null>([['me2resh/apexyard', new Map([[1, SHA_A], [2, SHA_B]])]])
    expect(classify([c1, c2, c3], shas, open)).toEqual({
      waiting: ['me2resh/apexyard#1'],
      reReview: ['me2resh/apexyard#2'],
      offline: false,
    })
  })

  test('a short SHA in the marker matches the full head', async () => {
    const c = cand('a/b', 5)
    const q = classify([c], new Map([[c.name, 'aaaaaaa']]), new Map([['a/b', new Map([[5, SHA_A]])]]))
    expect(q.waiting).toEqual(['a/b#5'])
  })

  test('an open PR whose marker has no SHA needs re-review', async () => {
    const c = cand('a/b', 6)
    const q = classify([c], new Map([[c.name, null]]), new Map([['a/b', new Map([[6, SHA_A]])]]))
    expect(q.reReview).toEqual(['a/b#6'])
  })

  test('a repo with a failed lookup falls back to the markers and is offline', async () => {
    const c1 = cand('a/b', 1)
    const c2 = cand('c/d', 2)
    const open = new Map<string, OpenPrs | null>([['a/b', null], ['c/d', new Map()]])
    expect(classify([c1, c2], new Map(), open)).toEqual({ waiting: ['a/b#1'], reReview: [], offline: true })
  })

  test('the gh command is read only, an argument array, and needs a valid repo', async () => {
    expect(ghArgv('me2resh/apexyard')).toEqual([
      'gh', 'pr', 'list', '--repo', 'me2resh/apexyard', '--state', 'open',
      '--json', 'number,headRefOid', '--limit', '200',
    ])
    expect(validRepo('me2resh/apexyard')).toBe(true)
    expect(validRepo('acme/my_repo.js')).toBe(true)
    expect(validRepo('a/b; rm -rf /')).toBe(false)
    expect(validRepo('../b')).toBe(false)
    expect(validRepo('a/b/c')).toBe(false)
    expect(validRepo('-R/x')).toBe(false)
    expect(validRepo('me2resh/.github')).toBe(true)
  })

  test('parses the open-PR list and refuses another shape', async () => {
    const out = parseOpenPrs(JSON.stringify([{ number: 7, headRefOid: SHA_A.toUpperCase() }, { number: 'x' }]))
    expect(out && [...out.entries()]).toEqual([[7, SHA_A]])
    expect(parseOpenPrs('not json')).toBe(null)
    expect(parseOpenPrs('{}')).toBe(null)
  })

  test('the lookup is cached for 120 seconds per repo, failures too', async () => {
    const calls: string[][] = []
    let ok = true
    const run: GhRun = async argv => {
      calls.push([...argv])
      if (!ok) throw new Error('gh: not found')
      return { exitCode: 0, stdout: JSON.stringify([{ number: 1, headRefOid: SHA_A }]) }
    }
    const cache: GhCache = new Map()
    expect((await openPrsFor(cache, 'a/b', 0, run))?.get(1)).toBe(SHA_A)
    await openPrsFor(cache, 'a/b', 119_999, run)
    expect(calls.length).toBe(1)
    await openPrsFor(cache, 'c/d', 1000, run)
    expect(calls.length).toBe(2)
    ok = false
    expect(await openPrsFor(cache, 'a/b', 120_000, run)).toBe(null)
    expect(calls.length).toBe(3)
    expect(await openPrsFor(cache, 'a/b', 200_000, run)).toBe(null)
    expect(calls.length).toBe(3)
  })

  test('a failed or invalid lookup returns null and never throws', async () => {
    const fail: GhRun = async () => ({ exitCode: 4, stdout: '' })
    expect(await openPrsFor(new Map(), 'a/b', 0, fail)).toBe(null)
    let called = false
    const spy: GhRun = async () => {
      called = true
      return { exitCode: 0, stdout: '[]' }
    }
    expect(await openPrsFor(new Map(), 'not a repo', 0, spy)).toBe(null)
    expect(called).toBe(false)
  })
})

describe('active ticket', () => {
  test('label is repo#N plus a short title without the [Type] prefix', async () => {
    const text = 'repo=me2resh/apexyard\nnumber=1541\ntitle=[Feature] Optional status band\n'
    expect(ticketLabel(text)).toBe('apexyard#1541 Optional status band')
  })

  test('a long title is cut to 48 characters', async () => {
    const label = ticketLabel(`repo=a/b\nnumber=1\ntitle=${'x'.repeat(80)}\n`) ?? ''
    expect(label).toBe(`b#1 ${'x'.repeat(47)}…`)
  })

  test('a marker without repo or number gives null', async () => {
    expect(ticketLabel('started_at=now\n')).toBe(null)
  })
})

describe('ops-fork discovery', () => {
  const fs = (paths: string[]) => async (p: string) => paths.includes(p)

  test('the session pin wins when it is an ops fork', async () => {
    const exists = fs(['/ops/.apexyard-fork', '/cwd-fork/.apexyard-fork'])
    expect(await findOpsRoot('/ops\n', '/cwd-fork/sub', exists)).toBe('/ops')
  })

  test('a stale pin falls back to a walk up from the working directory', async () => {
    const exists = fs(['/home/me/fork/onboarding.yaml', '/home/me/fork/apexyard.projects.yaml'])
    expect(await findOpsRoot('/gone', '/home/me/fork/workspace/app', exists)).toBe('/home/me/fork')
  })

  test('one v1 anchor file alone is not a fork', async () => {
    expect(await findOpsRoot(null, '/a/b', fs(['/a/onboarding.yaml']))).toBe(null)
  })

  test('parent directories walk to the root', async () => {
    expect(parentDir('/a/b')).toBe('/a')
    expect(parentDir('/a')).toBe('/')
    expect(parentDir('/')).toBe(null)
  })
})

describe('reviewer lock and builds', () => {
  test('the lock reads owner/repo#N:role', async () => {
    expect(lockLabel('me2resh/apexyard#12:rex\n')).toBe('me2resh/apexyard#12 (rex)')
    expect(lockLabel('  \n')).toBe(null)
  })

  test('the lock joins every review marker and keeps the legacy file', async () => {
    expect(lockLabels(['a/b#1:rex\n', 'a/b#2:security\n', null])).toBe('a/b#1 (rex), a/b#2 (security)')
    expect(lockLabels(['a/b#1:rex', 'a/b#1:rex'])).toBe('a/b#1 (rex)')
    expect(lockLabels([null, '  \n'])).toBe(null)
  })

  test('the session id is sanitised like active_reviewer_marker_path', async () => {
    expect(safeSessionId('abc-1.2_3')).toBe('abc-1.2_3')
    expect(safeSessionId('../x y')).toBe('.._x_y')
  })

  test('the build count is off when the pattern is empty or invalid', async () => {
    expect(countBuilds('codex exec\n', '')).toBe(null)
    expect(countBuilds('codex exec\n', '(')).toBe(null)
  })

  test('the build count is the number of matching command lines', async () => {
    const ps = 'codex exec -C /w/a\n/bin/zsh\ncodex exec -C /w/b\n\n'
    expect(countBuilds(ps, '^codex exec')).toBe(2)
  })
})

describe('ticket resolver', () => {
  test('the ticket comes from the framework resolver, not from a marker path', async () => {
    expect(RESOLVE_TICKET).toContain('_lib-active-ticket.sh')
    expect(RESOLVE_TICKET).toContain('active_ticket_lookup')
    expect(RESOLVE_TICKET).not.toContain('apexyard-ticket')
    expect(RESOLVE_TICKET).not.toContain('.claude/session')
  })
})

describe('settings', () => {
  test('defaults: build count off, three-day window', async () => {
    expect(readSettings(undefined)).toEqual({ pattern: '', windowDays: 3 })
  })

  test('values from the plugin options', async () => {
    expect(readSettings({ build_process_pattern: 'codex', waiting_window_days: 7 })).toEqual({
      pattern: 'codex',
      windowDays: 7,
    })
    expect(readSettings({ waiting_window_days: -1 })).toEqual({ pattern: '', windowDays: 3 })
  })
})
