export type Band = {
  // "apexyard#1541 Optional status band", or null when no marker covers the session.
  ticket: string | null
  // PR references ("owner/repo#N") that are open, with the head Rex reviewed
  // and no CEO marker. Offline: every recent Rex marker with no CEO marker.
  waiting: string[]
  // Open PRs with a Rex marker whose head moved after the review.
  reReview: string[]
  // True when the open-PR lookup failed for a repo (gh missing, failed or slow).
  offline: boolean
  // The content of this session's reviewer lock ("owner/repo#N:rex"), or null.
  reviewLock: string | null
  // Number of running build processes, or null when the build count is off.
  builds: number | null
}

export type OrbitCriterion = { id: string; status: string; statement: string; shownBy: string }

export type OrbitOutcome = {
  id: string
  title: string
  pct: number
  achieved: number
  partly: number
  contradicted: number
  total: number
  criteria: OrbitCriterion[]
}

export type OrbitSummary = {
  title?: string
  checkedAt?: string | null
  planId: string
  revision: number
  reconciledAt: string | null
  outcomes: OrbitOutcome[]
  slices: { id: string; contributesTo: string[] }[]
  totals: { achieved: number; partly: number; contradicted: number; total: number }
}

export type OrbitPlanView = {
  key: string
  repo: string
  summary: OrbitSummary
}

export type OrbitView = {
  activeRepo: string | null
  plans: OrbitPlanView[]
  updatedAt: number
}

export type SliceLink = { repo: string; number: number; title: string; state: string; updatedAt?: string; approved?: boolean; ready?: boolean }

export type SliceLinks = {
  status: 'loading' | 'done' | 'error'
  issues: (SliceLink & { prs: SliceLink[] })[]
}

declare module 'claude-code' {
  interface PluginState {
    'apexyard-status': { band: Band | null; orbit: OrbitView | null; expanded: Record<string, boolean>; sliceLinks: Record<string, SliceLinks> }
  }
}
