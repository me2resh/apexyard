export type Check = { kind: 'skill' | 'bash'; value: string }
export type Step = { title: string; body: string; try?: string; check?: Check; done?: string; note?: string }
export type Module = { title: string; steps: Step[] }
export type Lesson = { file: string; module?: Module; error?: string }
export type Progress = { module: number; step: number; ticked: Record<string, boolean> }

declare module 'claude-code' {
  interface PluginState {
    'apexyard-bootcamp': { progress: Progress }
  }
}
