export type Line = { id: string; text: string }

declare module 'claude-code' {
  interface PluginState {
    'apexyard-explainer': { lines: Line[] }
  }
}
