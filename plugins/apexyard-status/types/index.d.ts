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

declare module 'claude-code' {
  interface PluginState {
    'apexyard-status': { band: Band | null }
  }
}
