import { describe, expect, test } from 'claude-code/testing'

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
  ticketLabel,
  waitingFrom,
  waitingText,
} from './band'
import { readSettings } from './register'

const DAY = 24 * 60 * 60 * 1000

describe('review markers (AgDR-0060 names)', () => {
  test('a marker name maps to owner/repo#N', async () => {
    expect(markerRef('me2resh__apexyard__1541-rex.approved')).toBe('me2resh/apexyard#1541')
    expect(markerRef('acme__my_repo.js__7-ceo.approved')).toBe('acme/my_repo.js#7')
  })

  test('a bare-number marker is not an AgDR-0060 name', async () => {
    expect(markerRef('429-rex.approved')).toBe(null)
  })

  test('waiting = recent Rex marker and no CEO marker', async () => {
    const now = 10 * DAY
    const entries = [
      { name: 'me2resh__apexyard__11-rex.approved', mtimeMs: now - 60_000 },
      { name: 'me2resh__apexyard__11-ceo.approved', mtimeMs: now - 30_000 },
      { name: 'acme__infra__176-rex.approved', mtimeMs: now - 60_000 },
      { name: 'acme__infra__20-rex.approved', mtimeMs: now - 5 * DAY },
      { name: '429-rex.approved', mtimeMs: now },
      { name: 'acme__infra__30-architecture.approved', mtimeMs: now },
    ]
    expect(waitingFrom(entries, now, 3)).toEqual(['acme/infra#176'])
    expect(waitingFrom(entries, now, 7)).toEqual(['acme/infra#176', 'acme/infra#20'])
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

  test('the newest started_at wins', async () => {
    const old = 'repo=a/old\nnumber=1\ntitle=Old\nstarted_at=2026-10-01T08:00:00Z\n'
    const neu = 'repo=a/new\nnumber=2\ntitle=New\nstarted_at=2026-10-02T08:00:00Z\n'
    expect(newestTicket([old, neu])).toBe('new#2 New')
    expect(newestTicket([])).toBe(null)
  })

  test('a linked worktree .git file names its git dir', async () => {
    expect(gitDirFromFile('gitdir: /r/.git/worktrees/gh1\n', '/w/gh1')).toBe('/r/.git/worktrees/gh1')
    expect(gitDirFromFile('gitdir: ../r/.git/worktrees/x\n', '/w')).toBe('/w/../r/.git/worktrees/x')
    expect(gitDirFromFile('nonsense', '/w')).toBe(null)
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
