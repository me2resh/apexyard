export type Band = {
  // "apexyard#1541 Optional status band", or null when no marker covers the session.
  ticket: string | null
  // PR references ("owner/repo#N") with a recent Rex marker and no CEO marker.
  waiting: string[]
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
