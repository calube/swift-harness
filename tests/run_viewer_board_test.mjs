// Checks the run viewer's board module: the pure lane rules, then the module in headless Chrome
// with a RunView built here, moving a card as polled views arrive, badging its tab, and opening the task
// popover and from it the drawer.
// Run: node tests/run_viewer_board_test.mjs
// Regressions caught: a halt hidden behind the task's stage, a pending task shown as started before
// any span opens, a card that never moves on a poll, a card the keyboard can't open, and a console
// error from the module.
import assert from 'node:assert/strict'
import { copyFileSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { findChrome, launch } from './headless_chrome.mjs'

const viewer = new URL('../plugin/viewer/', import.meta.url)
const read = (name) => readFileSync(new URL(name, viewer), 'utf8')

// Both scripts are classic scripts that set globals; here those globals land on a local object.
const sandbox = {}
new Function('globalThis', read('run-view-model.js'))(sandbox)
new Function('globalThis', read('run-viewer-board.js'))(sandbox)
const B = sandbox.RunViewBoard

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
const gate = (runId, taskID, verdict) => ({
  runId, task: taskID, command: 'check --tier push', verdict, ms: 60000, tests: { passed: 1, failed: 0, skipped: 0 },
  ruleCounts: {}, steps: [],
})
const runView = (extra = {}) => ({
  schemaVersion: 1, cursor: 'c0',
  run: { id: 'run-1', plan: 'sample', preset: 'default', startedAt: at(0), endedAt: null, state: 'running' },
  spec: [], tasks: [], roles: [], spans: [span('run', null, 'run', 0, null)], gates: [], proofs: [], halts: [], damage: [],
  ...extra,
})
const laneOf = (lanes, id) => Object.keys(lanes).find((lane) => lanes[lane].some((c) => c.id === id)) ?? null

const unitTests = {
  'an in-progress task with an open verify span is gating, and an open halt moves it to blocked — catches the halt lost behind the stage'() {
    const base = {
      tasks: [task('a', { status: 'in-progress' })],
      spans: [span('run', null, 'run', 0, null), span('ta', 'run', 'task', 2, null, { task: 'a' }),
        span('wa', 'ta', 'worker', 2, 10, { task: 'a' }), span('va', 'ta', 'verify', 10, null, { task: 'a' })],
    }
    assert.equal(laneOf(B.columns(runView(base), t0 + 12 * 60000), 'a'), 'gating')
    const halted = runView({ ...base, halts: [{ task: 'a', reason: 'gate-red', at: at(11), answer: null, waitMs: null }] })
    assert.equal(laneOf(B.columns(halted, t0 + 12 * 60000), 'a'), 'blocked')
    const resumed = runView({ ...base, halts: [{ task: 'a', reason: 'gate-red', at: at(11), answer: 'retry', waitMs: 30000 }] })
    assert.equal(laneOf(B.columns(resumed, t0 + 12 * 60000), 'a'), 'gating', 'a resumed halt still blocks the task')
  },

  'a pending task with every dep merged stays queued until a span opens — catches a ready task drawn as started'() {
    const tasks = [task('a', { status: 'done', mergedAt: at(9) }), task('b', { deps: ['a'] })]
    const spans = [span('run', null, 'run', 0, null), span('ta', 'run', 'task', 2, 9, { task: 'a' })]
    const queued = B.columns(runView({ tasks, spans }), t0 + 10 * 60000)
    assert.equal(laneOf(queued, 'b'), 'queued')
    assert.equal(queued.queued[0].elapsed, 'waiting')
    const opened = runView({ tasks, spans: spans.concat([span('tb', 'run', 'task', 10, null, { task: 'b' }), span('wb', 'tb', 'worker', 10, null, { task: 'b' })]) })
    assert.equal(laneOf(B.columns(opened, t0 + 13 * 60000), 'b'), 'building')
  },

  'each status and open stage lands in its own lane — catches a lane rule read from the mock\'s columns'() {
    const tasks = [
      task('fixing', { status: 'in-progress' }), task('reviewing', { status: 'in-progress' }),
      task('bare', { status: 'in-progress' }), task('merged', { status: 'done', mergedAt: at(20) }),
      task('stuck', { status: 'blocked' }), task('replan', { status: 'needs-replan' }), task('dropped', { status: 'abandoned' }),
    ]
    const spans = [
      span('run', null, 'run', 0, null),
      span('tf', 'run', 'task', 1, null, { task: 'fixing' }), span('vf', 'tf', 'verify', 1, 5, { task: 'fixing' }),
      span('ff', 'tf', 'fix', 5, null, { task: 'fixing' }),
      span('tr', 'run', 'task', 1, null, { task: 'reviewing' }), span('rr', 'tr', 'review', 6, null, { task: 'reviewing' }),
    ]
    const lanes = B.columns(runView({ tasks, spans }), t0 + 21 * 60000)
    assert.deepEqual(
      Object.fromEntries(tasks.map((t) => [t.id, laneOf(lanes, t.id)])),
      { fixing: 'building', reviewing: 'review', bare: 'building', merged: 'merged', stuck: 'blocked', replan: 'blocked', dropped: 'blocked' })
    assert.deepEqual(Object.keys(lanes), ['queued', 'building', 'gating', 'review', 'merged', 'blocked'])
  },

  'a card carries the model, the elapsed time, the last gate verdict and the spec ids — catches a card showing the first gate'() {
    const view = runView({
      tasks: [task('a', { status: 'done', model: 'sonnet', covers: ['req-a', 'req-b'], mergedAt: at(14) })],
      spans: [span('run', null, 'run', 0, null), span('ta', 'run', 'task', 2, 14, { task: 'a' }),
        span('g1', 'ta', 'gate', 5, 6, { task: 'a', gateRun: 'g-red', outcome: 'red' }),
        span('g2', 'ta', 'gate', 9, 10, { task: 'a', gateRun: 'g-green', outcome: 'ok' })],
      gates: [gate('g-green', 'a', 'GREEN'), gate('g-red', 'a', 'RED')],
    })
    const card = B.columns(view, t0 + 30 * 60000).merged.find((c) => c.id === 'a')
    assert.ok(card, 'the merged task has no card in merged')
    assert.deepEqual(
      { id: card.id, model: card.model, elapsed: card.elapsed, lastGate: card.lastGate, covers: card.covers },
      { id: 'a', model: 'sonnet', elapsed: '12m 00s', lastGate: 'GREEN', covers: ['req-a', 'req-b'] })
  },
}

// The whole view the next poll answers: `view` with each row of `rows` in place of the row with
// its key, or added after the rest.
function nextView(view, rows) {
  const out = { ...view }
  for (const [field, list] of Object.entries(rows)) {
    const key = field === 'gates' ? 'runId' : 'id'
    const merged = (view[field] || []).slice()
    for (const row of list) {
      const at = merged.findIndex((r) => r[key] === row[key])
      if (at >= 0) merged[at] = row; else merged.push(row)
    }
    out[field] = merged
  }
  return out
}

// A worker building `list`; the first poll ends the worker and opens review, the second merges it.
const liveView = runView({
  spec: [{ id: 'req-list', title: 'List notes', tasks: ['list'] }],
  tasks: [task('list', { status: 'in-progress', model: 'sonnet', covers: ['req-list'] }), task('later', { deps: ['list'] })],
  spans: [span('run', null, 'run', 0, null), span('tl', 'run', 'task', 2, null, { task: 'list' }),
    span('wl', 'tl', 'worker', 2, null, { task: 'list' })],
})
const polled = [
  {
    spans: [span('wl', 'tl', 'worker', 2, 8, { task: 'list' }), span('gl', 'tl', 'gate', 8, 9, { task: 'list', gateRun: 'g-list', outcome: 'ok' }),
      span('rl', 'tl', 'review', 9, null, { task: 'list' })],
    gates: [gate('g-list', 'list', 'GREEN')],
  },
  {
    tasks: [task('list', { status: 'done', model: 'sonnet', covers: ['req-list'], commits: ['4be91c0'], mergeGateRun: 'g-list', mergedAt: at(12) })],
    spans: [span('rl', 'tl', 'review', 9, 11, { task: 'list' }), span('ml', 'tl', 'merge', 11, 12, { task: 'list', gateRun: 'g-list' }),
      span('tl', 'run', 'task', 2, 12, { task: 'list' })],
  },
]
const firstPoll = nextView(liveView, polled[0])
const secondPoll = nextView(firstPoll, polled[1])

function writePage() {
  const dir = mkdtempSync(join(tmpdir(), 'run-viewer-board-'))
  for (const name of ['run-viewer.html', 'run-viewer.css', 'run-viewer.js', 'run-view-model.js', 'run-viewer-board.js', 'run-viewer-board.css']) {
    copyFileSync(new URL(name, viewer), join(dir, name))
  }
  const data = JSON.stringify(liveView).replace(/</g, '\\u003c')
  const html = read('run-viewer.html')
    .replace('<script type="application/json" id="run-view"></script>', `<script type="application/json" id="run-view">${data}</script>`)
    .replace('<link rel="stylesheet" href="run-viewer.css">', '<link rel="stylesheet" href="run-viewer.css">\n<link rel="stylesheet" href="run-viewer-board.css">')
    .replace('<script src="run-viewer.js"></script>', '<script src="run-viewer.js"></script>\n<script src="run-viewer-board.js"></script>')
  writeFileSync(join(dir, 'run-viewer.html'), html)
  return { dir, url: pathToFileURL(join(dir, 'run-viewer.html')).href }
}

const BOARD = `(() => {
  const mount = document.querySelector('[data-module="board"]')
  const lanes = [...mount.querySelectorAll('.lane')]
  return {
    hidden: mount.hidden, height: mount.offsetHeight, lanes: lanes.length,
    laneOf: Object.fromEntries(lanes.flatMap((l) => [...l.querySelectorAll('.card')].map((c) => [c.dataset.task, l.dataset.lane]))),
    list: mount.querySelector('.card[data-task="list"]')?.innerText ?? null,
    errors: document.body.dataset.errors,
  }
})()`
const DRAWER = "({ open: document.getElementById('drawer').classList.contains('open'), id: document.getElementById('dr-id').textContent, active: document.activeElement.dataset.task ?? null })"
const POPOVER = "({ hidden: document.getElementById('pop').hidden, title: document.getElementById('pop-title').textContent, body: document.getElementById('pop-body').textContent, active: document.activeElement.dataset.task ?? null })"
const BADGES = "Object.fromEntries([...document.querySelectorAll('[role=tab][data-tab=\"board\"] .badge')].map((b) => [b.dataset.key, b.dataset.n]))"

const withCard = (id, action) => `(() => { const c = document.querySelector('.card[data-task="${id}"]'); if (!c) return false; c.${action}(); return true })()`

const pageTests = {
  async 'the board draws 6 lanes from a test-built RunView, and 2 polled views move a card from building to merged with 0 console errors — catches a card that never moves on a poll'() {
    let board = await page.evaluate(BOARD)
    assert.equal(board.hidden, false, 'the board panel stays hidden')
    assert.ok(board.height > 0)
    assert.equal(board.lanes, 6)
    assert.deepEqual(board.laneOf, { list: 'building', later: 'queued' })
    assert.match(board.list, /sonnet/)
    assert.match(board.list, /req-list/)
    assert.match(board.list, /no gate yet/)
    await page.evaluate(`window.runViewer.replace(${JSON.stringify(firstPoll)})`)
    board = await page.evaluate(BOARD)
    assert.equal(board.laneOf.list, 'review')
    assert.match(board.list, /GREEN/)
    await page.evaluate(`window.runViewer.replace(${JSON.stringify(secondPoll)})`)
    board = await page.evaluate(BOARD)
    assert.deepEqual(board.laneOf, { list: 'merged', later: 'queued' })
    assert.equal(board.errors, '0')
    assert.deepEqual(page.errors, [])
  },

  async 'the Board tab badges the view\'s blocked tasks, and a poll that halts a task moves its card and the badge — catches a badge that drifts from the board'() {
    assert.deepEqual(await page.evaluate(BADGES), {}, 'precondition: nothing in flight or blocked after the merge')
    await page.evaluate(`window.runViewer.replace(${JSON.stringify(nextView(secondPoll, { tasks: [task('later', { status: 'blocked', deps: ['list'] })] }))})`)
    assert.deepEqual(await page.evaluate(BADGES), { blocked: '1' })
    assert.equal((await page.evaluate(BOARD)).laneOf.later, 'blocked')
    await page.evaluate(`window.runViewer.replace(${JSON.stringify(nextView(secondPoll, { tasks: [task('later', { deps: ['list'] })] }))})`)
    assert.deepEqual(await page.evaluate(BADGES), {})
  },

  async 'Enter on a focused card opens its task popover, Open task opens the drawer, and Escape returns focus to the card — catches a card the keyboard can\'t open'() {
    assert.ok(await page.evaluate(withCard('list', 'focus')), 'no card for list')
    await page.press('Enter')
    const pop = await page.evaluate(POPOVER)
    assert.equal(pop.hidden, false, 'Enter on a card opens no popover')
    assert.equal(pop.title, 'list')
    assert.match(pop.body, /merged/, 'the popover names no column')
    assert.match(pop.body, /4be91c0/, 'the popover names no commit')
    assert.match(pop.body, /req-list/, 'the popover names no covered requirement')
    await page.evaluate("document.querySelector('#pop [data-open-task]').click()")
    let drawer = await page.evaluate(DRAWER)
    assert.equal(drawer.open, true, 'Open task does not open the drawer')
    assert.equal(drawer.id, 'list')
    await page.press('Escape')
    drawer = await page.evaluate(DRAWER)
    assert.equal(drawer.open, false)
    assert.equal(drawer.active, 'list', 'focus does not return to the card')
  },

  async 'a click on a card opens the popover for its task and Escape closes it on the card — catches a click handler bound to the wrong card'() {
    assert.ok(await page.evaluate(withCard('later', 'click')), 'no card for later')
    let pop = await page.evaluate(POPOVER)
    assert.equal(pop.hidden, false)
    assert.equal(pop.title, 'later')
    assert.match(pop.body, /queued/)
    assert.match(pop.body, /list/, 'the popover names no dep')
    assert.equal((await page.evaluate(DRAWER)).open, false, 'a click opens the drawer, not the popover')
    await page.press('Escape')
    pop = await page.evaluate(POPOVER)
    assert.equal(pop.hidden, true)
    assert.equal(pop.active, 'later')
    assert.deepEqual(page.errors, [])
  },

  async 'Space on a focused card opens its popover too — catches a card only Enter opens'() {
    assert.ok(await page.evaluate(withCard('list', 'focus')))
    await page.press('Space')
    const pop = await page.evaluate(POPOVER)
    assert.equal(pop.hidden, false)
    assert.equal(pop.title, 'list')
    await page.press('Escape')
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
  console.log('skip run viewer board page checks: no Chrome binary (set CHROME_PATH)')
} else {
  const browser = await launch()
  page = browser.page
  const built = writePage()
  try {
    await page.viewport(1280, 900)
    await page.load(built.url + '#board')
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
