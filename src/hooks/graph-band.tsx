import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { GraphRow } from './graph-band-types'

// The live state of every work graph under this session's directory, drawn
// above the prompt from the graph's own files (nodes.tsv, graph-log.md) on a
// timer: no model turn, no token. `graph.sh run` loops in the background and
// writes nothing to the terminal by design; this is where its progress shows.

const snapshot = atom({ plugin: 'ship', key: 'graph-band' } as const, null)

const REFRESH_MS = 5000
const BAR_CELLS = 12
const DONE_LINGER_MS = 30 * 60 * 1000
const ALERT = /→ failed|asks|answered|graph complete|Every node|NOT moved|nothing to land|deadlock/

const lastSeen = new Map<string, string>()

function shortLog(line: string): { at: string; ageMs: number; text: string } {
  const m = /^- (\d{4}-\d\d-\d\dT(\d\d:\d\d):\d\dZ) — (.*)$/.exec(line.trim())
  const raw = (m?.[3] ?? line.trim())
    .replace(/\s*\([^)]*\)/g, '')
    .replace(/\s+—\s+reports harvested.*$/, '')
  const stamp = m?.[1] ? Date.parse(m[1]) : NaN
  return { at: m?.[2] ?? '', ageMs: Number.isNaN(stamp) ? 0 : Date.now() - stamp, text: raw.slice(0, 100) }
}

async function graphDirs($: EngineInterface): Promise<string[]> {
  const root = `${await $.session.cwd()}/.context/ship-graph`
  if (!(await $.fs.exists(root))) return []
  const dirs: string[] = []
  for (const entry of await $.fs.list(root)) {
    if (entry.kind === 'dir' && (await $.fs.exists(`${root}/${entry.name}/nodes.tsv`))) {
      dirs.push(`${root}/${entry.name}`)
    }
  }
  return dirs
}

async function rowOf($: EngineInterface, dir: string): Promise<GraphRow | null> {
  let nodes: string
  try {
    nodes = await $.fs.read(`${dir}/nodes.tsv`)
  } catch {
    return null
  }
  const row: GraphRow = {
    feature: dir.split('/').pop() ?? dir,
    total: 0, merged: 0, failed: 0, pending: 0, running: [], landed: [], last: '', at: '', ageMs: 0,
  }
  for (const line of nodes.split('\n')) {
    if (!line.trim()) continue
    const cols = line.split('\t')
    const task = cols[0] ?? ''
    row.total += 1
    switch (cols[5]) {
      case 'merged':
        row.merged += 1
        break
      case 'failed':
        row.failed += 1
        break
      case 'in_flight':
        row.running.push(task)
        break
      case 'landed':
        row.landed.push(task)
        break
      default:
        row.pending += 1
    }
  }
  try {
    const log = await $.fs.read(`${dir}/graph-log.md`)
    const lines = log.trimEnd().split('\n')
    const tail = lines[lines.length - 1] ?? ''
    const { at, ageMs, text } = shortLog(tail)
    row.at = at
    row.ageMs = ageMs
    row.last = text
    const prev = lastSeen.get(dir)
    if (prev !== undefined && prev !== tail && ALERT.test(tail)) {
      $.ui.toast(`${row.feature}: ${text}`)
    }
    lastSeen.set(dir, tail)
  } catch {
    // a graph without a log yet draws without a last line
  }
  return row
}

async function refresh($: EngineInterface): Promise<void> {
  const rows: GraphRow[] = []
  for (const dir of await graphDirs($)) {
    const row = await rowOf($, dir)
    if (row) rows.push(row)
  }
  await update($, snapshot, () => rows)
}

function isDone(r: GraphRow): boolean {
  return r.merged + r.failed >= r.total
}

function bar(r: GraphRow): { done: number; bad: number; rest: number } {
  const total = Math.max(1, r.total)
  const done = Math.round((r.merged / total) * BAR_CELLS)
  const bad = Math.min(BAR_CELLS - done, Math.round((r.failed / total) * BAR_CELLS))
  return { done, bad, rest: BAR_CELLS - done - bad }
}

export const register: Register = (on) => {
  on('session.start', async ($, e, next) => {
    void refresh($)
    $.clock.every(REFRESH_MS, () => {
      void refresh($)
    })
    return next(e)
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const rows = await read($, snapshot)
    if (e.props.hasSurvey || !rows) return next(e)
    const shown = rows
      .filter((r) => !isDone(r) || r.ageMs < DONE_LINGER_MS)
      .slice(0, Math.max(1, (e.props.maxRows ?? 6) - 1))
    if (shown.length === 0) return next(e)

    const { Box, Text } = $.ui.resolve(e)
    const width = Math.max(...shown.map((r) => r.feature.length))

    return (
      <Box flexDirection="column">
        {shown.map((r) => {
          const done = isDone(r)
          const b = bar(r)
          const glyph = done ? (r.failed > 0 ? '✗' : '✓') : '▶'
          const glyphColor = done ? (r.failed > 0 ? 'error' : 'success') : 'claude'
          return (
            <Text wrap="truncate-end">
              <Text color={glyphColor} bold>{glyph} </Text>
              <Text bold dimColor={done}>{r.feature.padEnd(width)} </Text>
              <Text color="success">{'█'.repeat(b.done)}</Text>
              <Text color="error">{'█'.repeat(b.bad)}</Text>
              <Text color="inactive">{'░'.repeat(b.rest)}</Text>
              <Text> </Text>
              <Text color="success" bold>{r.merged}</Text>
              <Text color="subtle">/{r.total}</Text>
              {r.failed > 0 ? <Text color="error"> ✗{r.failed}</Text> : null}
              {r.running.length > 0 ? <Text color="warning">  ⟳ {r.running.join(' ')}</Text> : null}
              {r.landed.length > 0 ? <Text color="merged">  ↑ {r.landed.join(' ')}</Text> : null}
              {r.at ? <Text color="subtle">  {r.at}Z </Text> : null}
              {r.last ? <Text dimColor>{r.last}</Text> : null}
            </Text>
          )
        })}
      </Box>
    )
  })
}
