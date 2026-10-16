import { test, expect, mock } from 'claude-code/testing'

const CWD = '/w'
const ROOT = `${CWD}/.context/ship-graph`
const GRAPH = `${ROOT}/api-feature`
const NODES = [
  'MOB-1\ta\tb\tc\td\tin_flight\t1\tx\ty',
  'MOB-2\ta\tb\tc\td\tlanded\t1\tx\ty',
  'MOB-3\ta\tb\tc\td\tmerged\t1\tx\ty',
  'MOB-4\ta\tb\tc\td\tfailed\t2\tx\ty',
  'MOB-5\ta\tb\tc\td\tpending\t0\tx\ty',
].join('\n')
const LOG = '- 2026-10-16T08:11:10Z — MOB-1 dispatched (/w/x) — reports harvested to .context\n'
const PROPS = { hasSurvey: false, isWorking: false, maxRows: 6, bodyColumns: 120 } as any

function graphFiles(on: any, files: Record<string, string>, dirs: string[]) {
  on('session.cwd', async () => ({ value: CWD }))
  on('fs.exists', async (_$: unknown, e: { path: string }) => ({
    value: e.path === ROOT || dirs.some((d) => e.path.startsWith(d)) || e.path in files,
  }))
  on('fs.list', async (_$: unknown, e: { path: string }) => ({
    value: e.path === ROOT ? dirs.map((d) => ({ name: d.split('/').pop(), kind: 'dir' })) : [],
  }) as any)
  on('fs.read', async (_$: unknown, e: { path: string }) => {
    if (e.path in files) return { value: files[e.path] }
    throw new Error(`no such file ${e.path}`)
  })
  on('session.start', async () => ({ cwd: CWD }))
  on('ui.render', async () => ({ type: 'engine', ref: 'own' } as any))
}

test('an active graph draws one colored row per graph on every surface', async ($, on) => {
  const clock = mock.clock(on)
  graphFiles(on, { [`${GRAPH}/nodes.tsv`]: NODES, [`${GRAPH}/graph-log.md`]: LOG }, [GRAPH])
  await $.session.start({ cwd: CWD, surface: 'terminal', isInteractive: true } as any)
  await clock.advance(5000)

  for (const surface of ['terminal', 'desktop'] as const) {
    const ui = await $.ui.mount({ plugin: 'ship', surface, component: 'AbovePrompt', props: PROPS })
    expect((await ui.drawn()).type).toBe('Box')
    expect(await ui.find({ type: 'Text', text: /api-feature/ })).toBeDefined()
    expect((await ui.find({ type: 'Text', text: /MOB-1$/ }))?.props?.color).toBe('warning')
    expect((await ui.find({ type: 'Text', text: /MOB-2$/ }))?.props?.color).toBe('merged')
    expect(await ui.find({ type: 'Text', text: /MOB-1 dispatched$/ })).toBeDefined()
    await ui.unmount()
  }
})

test('a directory without graphs leaves the band to the engine', async ($, on) => {
  const clock = mock.clock(on)
  graphFiles(on, {}, [])
  await $.session.start({ cwd: CWD, surface: 'terminal', isInteractive: true } as any)
  await clock.advance(5000)
  await expect(
    $.ui.mount({ plugin: 'ship', surface: 'terminal', component: 'AbovePrompt', props: PROPS }),
  ).rejects.toThrow(/drew nothing/)
})

test('a graph that finished long ago is no longer drawn', async ($, on) => {
  const clock = mock.clock(on)
  const nodes = 'MOB-1\ta\tb\tc\td\tmerged\t1\tx\ty'
  const log = '- 2020-01-01T00:00:00Z — graph complete\n'
  graphFiles(on, { [`${GRAPH}/nodes.tsv`]: nodes, [`${GRAPH}/graph-log.md`]: log }, [GRAPH])
  await $.session.start({ cwd: CWD, surface: 'terminal', isInteractive: true } as any)
  await clock.advance(5000)
  await expect(
    $.ui.mount({ plugin: 'ship', surface: 'terminal', component: 'AbovePrompt', props: PROPS }),
  ).rejects.toThrow(/drew nothing/)
})
