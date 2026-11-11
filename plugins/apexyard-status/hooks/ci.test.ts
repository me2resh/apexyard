import { describe, expect, test } from 'claude-code/testing'

import { ciArgv, ciState, ciWord, parseCi, waitingText } from './band'

describe('CI state in the band', () => {
  test('reads one CI word from the check rollup', () => {
    expect(ciState([])).toBe('none')
    expect(ciState(undefined)).toBe('unknown')
    expect(ciState([{ status: 'COMPLETED', conclusion: 'SUCCESS' }, { status: 'COMPLETED', conclusion: 'SKIPPED' }, { state: 'SUCCESS' }])).toBe('pass')
    expect(ciState([{ status: 'QUEUED', conclusion: '' }])).toBe('pending')
    expect(ciState([{ state: 'PENDING' }])).toBe('pending')
    expect(ciState([{ status: 'IN_PROGRESS' }, { state: 'ERROR' }])).toBe('fail')
  })

  test('builds read-only queries for one PR and for the current branch', () => {
    expect(ciArgv('a/b', 7)).toEqual(['gh', 'pr', 'view', '7', '--repo', 'a/b', '--json', 'number,statusCheckRollup'])
    expect(ciArgv(null, null)).toEqual(['gh', 'pr', 'view', '--json', 'number,statusCheckRollup'])
  })

  test('parses the query output', () => {
    expect(parseCi(JSON.stringify({ number: 7, statusCheckRollup: [] }))).toEqual({ number: 7, ci: 'none' })
    expect(parseCi('no pull requests found')).toBe(null)
    expect(ciWord('none')).toBe('no checks')
  })

  test('adds the CI word to each waiting PR that has one', () => {
    expect(waitingText(['a/b#1', 'a/b#2'], false, { 'a/b#1': 'pass' })).toBe(
      '2 waiting for your /approve-merge: a/b#1 (CI pass), a/b#2',
    )
  })
})
