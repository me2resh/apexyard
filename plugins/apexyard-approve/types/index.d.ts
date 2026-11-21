export type CiState = 'pass' | 'fail' | 'pending' | 'none' | 'unknown'

export type GateRow = {
  // "owner/repo"
  repo: string
  number: number
  title: string
  // The 40-hex head SHA at the last refresh, or null when gh failed.
  head: string | null
  // The SHA in the Rex marker, or null.
  rexSha: string | null
  ci: CiState
  // True when GitHub says the PR is open. Null when gh failed.
  open: boolean | null
  // The result of the last press on this row.
  note: string | null
}

export type GateView = {
  // False outside an ops fork: the pane then shows a short notice.
  inFork: boolean
  rows: GateRow[]
  // True while one approval flow runs.
  busy: boolean
  updatedAt: number
}

declare module 'claude-code' {
  interface PluginState {
    'apexyard-approve': { view: GateView | null }
  }
}
