export type GraphRow = {
  feature: string
  total: number
  merged: number
  failed: number
  pending: number
  running: string[]
  landed: string[]
  last: string
  at: string
  ageMs: number
}

declare module 'claude-code' {
  interface PluginState {
    ship: { 'graph-band': GraphRow[] | null }
  }
}
