// Checks the run viewer's plan graph module: the pure layering, then the module in headless Chrome
// with a RunView built here, drawing 1 node per task and 1 edge per dep, recolouring on a poll and
// opening the task drawer from the keyboard.
// Run: node tests/run_viewer_graph_test.mjs
// Regressions caught: a node drawn left of its dep, a wave ordered so its edges cross, a dep cycle
// that hangs the page, an edge lost or doubled, a node the keyboard can't open, plan-stage nodes
// drawn with no span behind them, and a console error from the module.
import assert from 'node:assert/strict'
import { copyFileSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { findChrome, launch } from './headless_chrome.mjs'

const viewer = new URL('../plugin/viewer/', import.meta.url)
const read = (name) => readFileSync(new URL(name, viewer), 'utf8')

// The scripts are classic scripts that set globals; here those globals land on a local object.
const sandbox = {}
new Function('globalThis', read('run-view-model.js'))(sandbox)
new Function('globalThis', read('run-viewer-graph.js'))(sandbox)
const G = sandbox.RunViewGraph

const waveOf = (waves, id) => waves.findIndex((w) => w.includes(id))
const deps = (pairs) => Object.entries(pairs).map(([id, d]) => ({ id, deps: d }))

const unitTests = {
  'layers puts every task in a later wave than each of its deps, whatever the input order — catches a node left of its dep'() {
    const tasks = deps({ e: ['d', 'a'], d: ['c'], c: ['b'], b: ['a'], a: [], f: ['a'] })
    const { waves, cycle } = G.layers(tasks)
    assert.equal(cycle, null)
    assert.equal(waves.flat().length, tasks.length, 'a task is missing from the waves')
    for (const t of tasks) for (const d of t.deps) {
      assert.ok(waveOf(waves, t.id) > waveOf(waves, d), `${t.id} is not right of its dep ${d}: ${JSON.stringify(waves)}`)
    }
    assert.equal(waveOf(waves, 'e'), 4, 'a wave is not the longest dep chain')
  },

  'a diamond yields 3 waves with both middle tasks in 1 — catches a wave counted from the shortest chain'() {
    const { waves } = G.layers(deps({ a: [], b: ['a'], c: ['a'], d: ['b', 'c'] }))
    assert.deepEqual(waves, [['a'], ['b', 'c'], ['d']])
  },

  'a wave is ordered by the mean position of its deps — catches an order that crosses edges'() {
    const { waves } = G.layers(deps({ top: [], bottom: [], underBottom: ['bottom'], underTop: ['top'], mid: ['top', 'bottom'] }))
    assert.deepEqual(waves, [['top', 'bottom'], ['underTop', 'mid', 'underBottom']])
  },

  'a dep cycle returns the tasks on it and no waves — catches a cycle that recurses forever'() {
    const { waves, cycle } = G.layers(deps({ free: [], a: ['c'], b: ['a'], c: ['b'], after: ['a'] }))
    assert.deepEqual(waves, [])
    assert.ok(Array.isArray(cycle), 'no cycle reported')
    assert.deepEqual([...cycle].sort(), ['a', 'b', 'c'])
  },

  'the captured build run\'s ledger lays out as its 3-task chain — catches a layering that only fits test-built plans'() {
    const ledger = JSON.parse(readFileSync(new URL('../plugin/gate/Tests/Fixtures/RunView/build-run-1/ledger.json', import.meta.url), 'utf8'))
    assert.deepEqual(G.layers(ledger.tasks).waves,
      [['counter-core-reset-and-decrement-floor'], ['counter-ui-reset-button'], ['counter-ui-reset-button-snapshot']])
  },
}

const t0 = Date.parse('2026-10-03T14:00:00.000Z')
const at = (minutes) => new Date(t0 + minutes * 60000).toISOString()
const span = (id, parent, phase, start, end, extra = {}) => ({
  id, parent, phase, task: null, gateRun: null, start: at(start), end: end == null ? null : at(end),
  outcome: null, approximate: false, ...extra,
})
const task = (id, extra = {}) => ({
  id, status: 'pending', model: 'opus', deps: [], writes: [], gate: 'push', covers: [], commits: [], gateRun: null,
  mergeGateRun: null, createdAt: at(1), mergedAt: null, tokens: null, ...extra,
})
const liveView = {
  schemaVersion: 1, cursor: 'c0',
  run: { id: 'run-1', plan: 'sample', preset: 'default', startedAt: at(0), endedAt: null, state: 'running' },
  spec: [],
  tasks: [
    task('core', { status: 'done', model: 'sonnet', writes: ['Core/A.swift', 'Core/B.swift'], mergedAt: at(8),
      brief: { title: 'The core counts down', why: 'The UI needs a floor.', designRef: '§2', scope: ['Core counter'], acceptance: ['a floor test fails first'], outOfScope: ['UI'] } }),
    task('ui', { status: 'in-progress', deps: ['core'], writes: ['UI/View.swift'] }),
    task('docs', { deps: ['core'], writes: ['docs/a.md'] }),
    task('snap', { deps: ['ui', 'docs'], writes: ['UI/Snap.swift'] }),
  ],
  roles: [],
  spans: [span('run', null, 'run', 0, null), span('tc', 'run', 'task', 1, 8, { task: 'core' }),
    span('tu', 'run', 'task', 9, null, { task: 'ui' }), span('wu', 'tu', 'worker', 9, null, { task: 'ui' })],
  gates: [], proofs: [], halts: [], damage: [],
}

function writePage() {
  const dir = mkdtempSync(join(tmpdir(), 'run-viewer-graph-'))
  const files = ['run-viewer.html', 'run-viewer.css', 'run-viewer.js', 'run-view-model.js', 'run-viewer-board.js', 'run-viewer-board.css', 'run-viewer-graph.js', 'run-viewer-graph.css']
  for (const name of files) copyFileSync(new URL(name, viewer), join(dir, name))
  const data = JSON.stringify(liveView).replace(/</g, '\\u003c')
  const html = read('run-viewer.html')
    .replace('<script type="application/json" id="run-view"></script>', `<script type="application/json" id="run-view">${data}</script>`)
    .replace('<link rel="stylesheet" href="run-viewer.css">', '<link rel="stylesheet" href="run-viewer.css">\n<link rel="stylesheet" href="run-viewer-board.css">\n<link rel="stylesheet" href="run-viewer-graph.css">')
    .replace('<script src="run-viewer.js"></script>', '<script src="run-viewer.js"></script>\n<script src="run-viewer-board.js"></script>\n<script src="run-viewer-graph.js"></script>')
  writeFileSync(join(dir, 'run-viewer.html'), html)
  return { dir, url: pathToFileURL(join(dir, 'run-viewer.html')).href }
}

const GRAPH = `(() => {
  const mount = document.querySelector('[data-module="graph"]')
  const svg = mount.querySelector('svg')
  const nodes = [...mount.querySelectorAll('.gnode[data-task]')]
  const box = (id) => mount.querySelector('.gnode[data-task="' + id + '"] .box')
  return {
    hidden: mount.hidden, svg: !!svg, height: svg ? svg.getBoundingClientRect().height : 0,
    depEdges: mount.querySelectorAll('path.edge.dep').length,
    stageEdges: mount.querySelectorAll('path.edge.stage').length,
    stages: [...mount.querySelectorAll('.gnode[data-stage]')].map((n) => n.dataset.stage),
    lane: Object.fromEntries(nodes.map((n) => [n.dataset.task, n.dataset.lane])),
    x: Object.fromEntries(nodes.map((n) => [n.dataset.task, +box(n.dataset.task).getAttribute('x')])),
    focusable: nodes.every((n) => n.getAttribute('role') === 'button' && n.getAttribute('tabindex') === '0'),
    coreText: mount.querySelector('.gnode[data-task="core"]')?.textContent ?? null,
    damage: [...mount.querySelectorAll('.damage-line')].map((d) => d.textContent),
    errors: document.body.dataset.errors,
  }
})()`
const DRAWER = "({ open: document.getElementById('drawer').classList.contains('open'), id: document.getElementById('dr-id').textContent, body: document.getElementById('dr-body').textContent, active: document.activeElement.dataset ? document.activeElement.dataset.task ?? null : null })"
const POPOVER = "({ hidden: document.getElementById('pop').hidden, title: document.getElementById('pop-title').textContent, body: document.getElementById('pop-body').textContent, active: document.activeElement.dataset ? document.activeElement.dataset.task ?? null : null })"
const focusNode = (id) => `(() => { const n = document.querySelector('[data-module="graph"] .gnode[data-task="${id}"]'); if (!n) return false; n.focus(); return document.activeElement === n })()`
const clickNode = (id) => `(() => { const n = document.querySelector('[data-module="graph"] .gnode[data-task="${id}"] .box'); if (!n) return false; n.dispatchEvent(new MouseEvent('click', { bubbles: true })); return true })()`

const pageTests = {
  async 'the graph draws 1 node per task in waves left to right and 1 path per dep, coloured by board lane — catches an edge lost or doubled'() {
    const g = await page.evaluate(GRAPH)
    assert.equal(g.hidden, false, 'the graph panel stays hidden')
    assert.ok(g.height > 0)
    assert.equal(g.depEdges, 4)
    assert.deepEqual(g.lane, { core: 'merged', ui: 'building', docs: 'queued', snap: 'queued' })
    assert.ok(g.x.core < g.x.ui && g.x.ui === g.x.docs && g.x.docs < g.x.snap, `waves are not left to right: ${JSON.stringify(g.x)}`)
    assert.ok(g.focusable, 'a node is not a focusable button')
    assert.match(g.coreText, /2 files · sonnet/)
    assert.match(g.coreText, /The core counts down/, 'the node has no title tooltip')
    assert.deepEqual(g.stages, [], 'plan-stage nodes drawn with no stage span')
    assert.equal(g.errors, '0')
    assert.deepEqual(page.errors, [])
  },

  async 'Enter on a focused node opens its task popover, and Open task the drawer listing its write set; Escape returns focus to the node — catches a node the keyboard can\'t open'() {
    assert.ok(await page.evaluate(focusNode('core')), 'the core node takes no focus')
    await page.press('Enter')
    const pop = await page.evaluate(POPOVER)
    assert.equal(pop.hidden, false, 'Enter on a node opens no popover')
    assert.equal(pop.title, 'core')
    assert.match(pop.body, /merged/)
    await page.evaluate("document.querySelector('#pop [data-open-task]').click()")
    let drawer = await page.evaluate(DRAWER)
    assert.equal(drawer.open, true, 'Open task does not open the drawer')
    assert.equal(drawer.id, 'core')
    assert.match(drawer.body, /Core\/A\.swift/)
    assert.match(drawer.body, /Core\/B\.swift/)
    await page.press('Escape')
    drawer = await page.evaluate(DRAWER)
    assert.equal(drawer.open, false)
    assert.equal(drawer.active, 'core', 'focus does not return to the node')
  },

  async 'a click on a node opens the popover for its task, and Space on a focused node too; Escape closes it — catches a click bound to the wrong node'() {
    assert.ok(await page.evaluate(clickNode('docs')), 'no node for docs')
    let pop = await page.evaluate(POPOVER)
    assert.equal(pop.hidden, false)
    assert.equal(pop.title, 'docs')
    assert.equal((await page.evaluate(DRAWER)).open, false, 'a click opens the drawer, not the popover')
    await page.press('Escape')
    assert.equal((await page.evaluate(POPOVER)).hidden, true)
    assert.ok(await page.evaluate(focusNode('ui')))
    await page.press('Space')
    pop = await page.evaluate(POPOVER)
    assert.equal(pop.title, 'ui', 'Space on a node opens no popover')
    await page.press('Escape')
  },

  async 'a poll recolours a node and keeps its focus, and stage spans add plan-stage nodes — catches a graph that never moves on a poll'() {
    assert.ok(await page.evaluate(focusNode('ui')))
    await page.evaluate(`window.runViewer.apply(${JSON.stringify({
      cursor: 'c1',
      tasks: [task('ui', { status: 'done', deps: ['core'], writes: ['UI/View.swift'], mergedAt: at(12) })],
      spans: [span('tu', 'run', 'task', 9, 12, { task: 'ui' }), span('wu', 'tu', 'worker', 9, 12, { task: 'ui' })],
    })})`)
    let g = await page.evaluate(GRAPH)
    assert.equal(g.lane.ui, 'merged')
    assert.equal(await page.evaluate("document.activeElement.dataset.task ?? null"), 'ui', 'the poll drops the node\'s focus')
    await page.evaluate(`window.runViewer.apply(${JSON.stringify({
      cursor: 'c2',
      spans: [span('sr', 'run', 'spec-read', 0, 1), span('pl', 'run', 'plan', 0, 1), span('fi', 'run', 'final', 12, null)],
    })})`)
    g = await page.evaluate(GRAPH)
    assert.deepEqual(g.stages, ['spec-read', 'plan', 'final'])
    assert.equal(g.depEdges, 4, 'stage edges counted as deps')
    assert.equal(g.stageEdges, 3, 'spec-read to plan, plan to the root, the sink to final')
    assert.deepEqual(page.errors, [])
  },

  async 'a dep cycle draws no graph and shows 1 damage line naming its tasks — catches a cycle that hangs the page'() {
    await page.evaluate(`window.runViewer.apply(${JSON.stringify({
      cursor: 'c3', tasks: [task('core', { status: 'done', model: 'sonnet', deps: ['snap'], writes: ['Core/A.swift', 'Core/B.swift'], mergedAt: at(8) })],
    })})`)
    const g = await page.evaluate(GRAPH)
    assert.equal(g.svg, false)
    assert.equal(g.damage.length, 1)
    assert.match(g.damage[0], /core/)
    assert.match(g.damage[0], /snap/)
    assert.deepEqual(page.errors, [])
  },
}

let failed = 0
const report = async (name, test) => {
  try {
    await test()
    console.log(`ok   ${name}`)
  } catch (error) {
    failed++
    console.log(`FAIL ${name}\n     ${String(error.message).split('\n').join('\n     ')}`)
  }
}
for (const [name, test] of Object.entries(unitTests)) await report(name, test)

let page = null
if (!findChrome()) {
  console.log('skip run viewer graph page checks: no Chrome binary (set CHROME_PATH)')
} else {
  const browser = await launch()
  page = browser.page
  const built = writePage()
  try {
    await page.viewport(1280, 900)
    await page.load(built.url + '#graph')
    for (const [name, test] of Object.entries(pageTests)) await report(name, test)
  } finally {
    await browser.close()
    rmSync(built.dir, { recursive: true, force: true })
  }
}
if (failed) {
  console.log(`${failed} failed`)
  process.exit(1)
}
