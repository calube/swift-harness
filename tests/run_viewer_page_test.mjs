// Checks the run viewer page in headless Chrome with a RunView built here: every region draws,
// the span popover works from the keyboard and closes on Escape or an outside click, it is a bottom
// sheet at phone width, the zoom scales the track and not the page, the task drawer opens with and
// without a brief, and a module that throws can't blank the page.
// Run: node tests/run_viewer_page_test.mjs
// Regressions caught: a popover the keyboard can't reach or that keeps focus, a zoom that widens
// the page, a drawer that needs a brief, a module able to blank the core regions, and a console
// error on load.
import assert from 'node:assert/strict'
import { copyFileSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { findChrome, launch } from './headless_chrome.mjs'

const viewer = new URL('../plugin/viewer/', import.meta.url)
const PAGE_FILES = ['run-viewer.html', 'run-viewer.css', 'run-viewer.js', 'run-view-model.js']

const t0 = Date.parse('2026-10-03T14:00:00.000Z')
const at = (minutes) => new Date(t0 + minutes * 60000).toISOString()
const tokens = (n) => ({ input: n, output: n / 2, cacheRead: n * 4, cacheWrite: n / 2 })
const span = (id, parent, phase, start, end, extra = {}) => ({
  id, parent, phase, task: null, gateRun: null, start: at(start), end: end == null ? null : at(end),
  outcome: null, approximate: false, ...extra,
})
const gate = (runId, task, verdict, ms, steps) => ({
  runId, task, command: 'check --tier push', verdict, ms, tests: { passed: 40, failed: 0, skipped: 1 },
  ruleCounts: verdict === 'RED' ? { 'prove.not-proven': 1 } : {}, steps,
})
const step = (tier, name, startMs, ms, verdict = 'GREEN') => ({ tier, step: name, startMs, ms, verdict })

const view = {
  schemaVersion: 1, cursor: 'c0',
  run: { id: '20261003T140000Z-0a1b2c3d', plan: 'sample-notes', preset: 'default', startedAt: at(0), endedAt: at(40), state: 'done' },
  spec: [
    { id: 'req-save-note', title: 'Save a note', tasks: ['store'] },
    { id: 'req-list-notes', title: 'List notes newest first', tasks: ['store', 'list'] },
    { id: 'req-uncovered', title: 'Share a note', tasks: [] },
  ],
  tasks: [
    {
      id: 'store', status: 'done', model: 'opus', deps: [], writes: ['Sources/NoteStore.swift', 'Tests/NoteStoreTests.swift'],
      gate: 'push', covers: ['req-save-note', 'req-list-notes'], commits: ['4be91c0'], gateRun: 'g-store', mergeGateRun: 'g-store',
      createdAt: at(4), mergedAt: at(24),
      brief: { title: 'Save notes to a local store', why: 'Every other task reads from the store.', designRef: '§3', scope: ['`NoteStore` saves and loads notes'], acceptance: ['`savesNote()` fails first'], outOfScope: ['Any view'] },
      tokens: tokens(100000),
    },
    {
      id: 'list', status: 'in-progress', model: 'sonnet', deps: ['store'], writes: ['Sources/NoteList.swift'],
      gate: 'push', covers: ['req-list-notes'], commits: [], gateRun: null, mergeGateRun: null,
      createdAt: at(4), mergedAt: null, tokens: null,
    },
  ],
  roles: [{ role: 'orchestrator', tokens: tokens(50000) }, { role: 'build-worker', tokens: tokens(100000) }],
  spans: [
    span('a000000000000001', null, 'run', 0, 40),
    span('a000000000000002', 'a000000000000001', 'spec-read', 0, 2),
    span('a000000000000003', 'a000000000000001', 'plan', 2, 4),
    span('t-store', 'a000000000000001', 'task', 5, 24, { task: 'store' }),
    span('a000000000000004', 't-store', 'worker', 5, 15, { task: 'store', tools: { calls: [{ tool: 'Edit', count: 4, ms: 900 }, { tool: 'Read', count: 9, ms: 400 }], otherCount: 2, ms: 1500, files: ['Sources/NoteStore.swift'], droppedPaths: 1 } }),
    span('g-store-span', 't-store', 'gate', 15, 20, { task: 'store', gateRun: 'g-store', outcome: 'ok' }),
    span('a000000000000005', 't-store', 'review', 20, 23, { task: 'store' }),
    span('m-store', 't-store', 'merge', 23, 24, { task: 'store', gateRun: 'g-store' }),
    span('t-list', 'a000000000000001', 'task', 6, 40, { task: 'list' }),
    span('a000000000000006', 't-list', 'worker', 6, null, { task: 'list' }),
  ],
  gates: [gate('g-store', 'store', 'GREEN', 300000, [step('t0', 'lint', 0, 4000), step('t1', 'test', 4000, 200000), step('t1', 'prove', 204000, 96000)])],
  proofs: [{ gateRun: 'g-store', task: 'store', test: 'NoteStoreTests/savesNote()', outcome: 'proven', proofBase: '7e21d0a', assertion: { file: 'Tests/NoteStoreTests.swift', line: 41, kind: 'expect' } }],
  halts: [],
  damage: [{ source: 'events/usage.jsonl', reason: 'line 3 is not JSON' }],
}

function writePage(extraScript) {
  const dir = mkdtempSync(join(tmpdir(), 'run-viewer-page-'))
  for (const name of PAGE_FILES) copyFileSync(new URL(name, viewer), join(dir, name))
  let html = readFileSync(join(dir, 'run-viewer.html'), 'utf8')
  const data = JSON.stringify(view).replace(/</g, '\\u003c')
  assert.ok(html.includes('<script type="application/json" id="run-view"></script>'), 'the page has no empty run-view script')
  html = html.replace('<script type="application/json" id="run-view"></script>', `<script type="application/json" id="run-view">${data}</script>`)
  if (extraScript) {
    writeFileSync(join(dir, 'run-viewer-zz-test.js'), extraScript)
    html = html.replace('<script src="run-viewer.js"></script>', '<script src="run-viewer.js"></script>\n<script src="run-viewer-zz-test.js"></script>')
  }
  writeFileSync(join(dir, 'run-viewer.html'), html)
  return { dir, url: pathToFileURL(join(dir, 'run-viewer.html')).href }
}

const REGIONS = `(() => ({
  meta: document.querySelectorAll('#meta span').length,
  stats: document.querySelectorAll('#stats .stat').length,
  bars: document.querySelectorAll('#tl .bar').length,
  spec: document.querySelectorAll('#spec tbody tr').length,
  proof: document.querySelectorAll('#proof tbody tr').length,
  tokens: document.querySelectorAll('#tokens .tok-row').length,
  roles: document.querySelectorAll('#roles .tok-row').length,
  gates: document.querySelectorAll('#gates .gate').length,
  damage: document.querySelectorAll('#foot .damage-line').length,
  steps: [...document.querySelectorAll('#tl .bar')].filter((b) => b.dataset.id.includes(':')).length,
  emptyMounts: [...document.querySelectorAll('[data-module]')].filter((m) => m.offsetHeight > 0).length,
  errors: document.body.dataset.errors,
}))()`

function assertCoreDrawn(regions) {
  for (const key of ['meta', 'stats', 'bars', 'spec', 'proof', 'tokens', 'roles', 'gates']) {
    assert.ok(regions[key] > 0, `region ${key} is empty`)
  }
}

const POPOVER = `(() => { const p = document.getElementById('pop'); const r = p.getBoundingClientRect();
  return { hidden: p.hidden, title: document.getElementById('pop-title').textContent, body: document.getElementById('pop-body').textContent,
    focusInPop: p.contains(document.activeElement), active: document.activeElement.dataset.id ?? null,
    bottom: r.bottom, left: r.left, width: r.width, innerHeight, innerWidth: document.documentElement.clientWidth } })()`

if (!findChrome()) {
  console.log('skip run viewer page checks: no Chrome binary (set CHROME_PATH)')
  process.exit(0)
}

const { page, close } = await launch()
const main = writePage()
const throwing = writePage("window.runViewer.register('board', { render() { throw new Error('board exploded') }, apply() {} })")

const tests = {
  async 'the page draws every region from a test-built RunView with 0 console errors — catches a key the page does not read'() {
    await page.viewport(1280, 900)
    await page.load(main.url)
    const regions = await page.evaluate(REGIONS)
    assertCoreDrawn(regions)
    assert.equal(regions.damage, 1)
    assert.equal(regions.steps, 3, 'the gate run draws no step bars')
    assert.equal(regions.emptyMounts, 0, 'an unregistered module panel takes space on the page')
    assert.equal(regions.errors, '0')
    assert.deepEqual(page.errors, [])
    const text = await page.evaluate("document.body.innerText")
    assert.match(text, /pending/, 'null tokens do not read pending')
    assert.match(text, /uncovered/, 'a requirement with no task is not flagged')
    assert.doesNotMatch(text, /undefined|NaN/)
    const openTitle = await page.evaluate("[...document.querySelectorAll('#tl .bar')].map((b) => b.title).find((t) => t.includes('never ended')) ?? null")
    assert.ok(openTitle, 'an open span does not read never ended')
  },

  async 'Tab to a bar and Enter opens its popover; Escape closes it and focus returns to the bar — catches a popover the keyboard can\'t reach'() {
    await page.evaluate("document.getElementById('tl-scroll').focus()")
    await page.press('Tab')
    const focused = await page.evaluate("document.activeElement.classList.contains('bar') ? document.activeElement.dataset.id : null")
    assert.ok(focused, 'Tab from the timeline scroller does not reach a bar')
    await page.press('Enter')
    let pop = await page.evaluate(POPOVER)
    assert.equal(pop.hidden, false, 'Enter on a bar does not open the popover')
    assert.ok(pop.focusInPop, 'focus does not move into the popover')
    assert.match(pop.body, /phase/)
    await page.press('Escape')
    pop = await page.evaluate(POPOVER)
    assert.equal(pop.hidden, true, 'Escape does not close the popover')
    assert.equal(pop.active, focused, 'focus does not return to the bar')
  },

  async 'the popover carries the span\'s ids, time and tool summary — catches a summary read from the mock\'s shape'() {
    await page.evaluate("document.querySelector('#tl .bar[data-id=\"a000000000000004\"]').click()")
    const pop = await page.evaluate(POPOVER)
    assert.equal(pop.hidden, false)
    assert.match(pop.body, /a000000000000004/)
    assert.match(pop.body, /Edit 4/)
    assert.match(pop.body, /other 2/)
    assert.match(pop.body, /Sources\/NoteStore\.swift/)
    assert.match(pop.body, /1 path dropped/)
  },

  async 'a click outside the popover closes it — catches a popover that only closes from its button'() {
    let pop = await page.evaluate(POPOVER)
    assert.equal(pop.hidden, false, 'precondition: the popover is open')
    await page.click(4, 4)
    pop = await page.evaluate(POPOVER)
    assert.equal(pop.hidden, true)
  },

  async 'the zoom changes the track\'s width and not the page\'s — catches a zoom that scrolls the whole page'() {
    const measure = "(() => ({ track: document.getElementById('tl').offsetWidth, page: document.documentElement.scrollWidth, client: document.documentElement.clientWidth }))()"
    const before = await page.evaluate(measure)
    await page.evaluate("document.querySelector('#zoom button[data-z=\"4\"]').click()")
    const after = await page.evaluate(measure)
    assert.ok(Math.abs(after.track - before.track * 4) <= 2, `4x track is ${after.track}, 1x was ${before.track}`)
    assert.equal(after.page, after.client, 'the page scrolls sideways')
    assert.equal(await page.evaluate("document.querySelector('#zoom button[data-z=\"4\"]').getAttribute('aria-pressed')"), 'true')
    await page.evaluate("document.querySelector('#zoom button[data-z=\"1\"]').click()")
  },

  async 'a task with no brief opens a drawer of Properties, Links and Activity; Escape returns focus to the opener — catches a drawer that needs a brief'() {
    await page.evaluate("document.querySelector('#zoom button[data-z=\"2\"]').focus()")
    await page.evaluate("window.runViewer.openTaskDrawer('list')")
    const drawer = await page.evaluate(`(() => ({ open: document.getElementById('drawer').classList.contains('open'),
      title: document.getElementById('dr-title').textContent, status: document.getElementById('dr-status').textContent,
      cards: [...document.querySelectorAll('#dr-body > .dr-card > h4, #dr-body > details > summary')].map((h) => h.textContent),
      body: document.getElementById('dr-body').textContent }))()`)
    assert.equal(drawer.open, true)
    assert.equal(drawer.title, 'list')
    assert.equal(drawer.status, 'in-progress')
    assert.deepEqual(drawer.cards, ['Properties', 'Links', 'Activity', 'Tool activity'])
    assert.match(drawer.body, /wave 2/)
    assert.match(drawer.body, /store/, 'blocked by does not list the dep')
    await page.press('Escape')
    const after = await page.evaluate("({ open: document.getElementById('drawer').classList.contains('open'), active: document.activeElement.dataset.z ?? null })")
    assert.equal(after.open, false)
    assert.equal(after.active, '2')
    assert.deepEqual(page.errors, [])
  },

  async 'a task with a brief shows Why, Scope, Acceptance and Out of scope before its properties — catches a brief left out'() {
    await page.evaluate("window.runViewer.openTaskDrawer('store')")
    const cards = await page.evaluate("[...document.querySelectorAll('#dr-body > .dr-card > h4')].map((h) => h.textContent)")
    assert.deepEqual(cards, ['Why', 'Scope', 'Acceptance', 'Out of scope', 'Properties', 'Links', 'Activity'])
    const body = await page.evaluate("document.getElementById('dr-body').textContent")
    assert.match(body, /§3/)
    assert.match(body, /Blocks/)
    await page.press('Escape')
  },

  async 'at a 390 px viewport the popover is a bottom sheet — catches a popover anchored off a phone screen'() {
    await page.viewport(390, 800)
    await page.load(main.url)
    await page.evaluate("document.getElementById('tl-scroll').focus()")
    await page.press('Tab')
    await page.press('Enter')
    const pop = await page.evaluate(POPOVER)
    assert.equal(pop.hidden, false)
    assert.ok(Math.abs(pop.bottom - pop.innerHeight) <= 1, `sheet bottom ${pop.bottom} vs ${pop.innerHeight}`)
    assert.equal(pop.left, 0)
    assert.ok(Math.abs(pop.width - pop.innerWidth) <= 1)
    assert.deepEqual(page.errors, [])
  },

  async 'a module whose render throws leaves every core region drawn and adds 1 damage line — catches a module able to blank the page'() {
    await page.viewport(1280, 900)
    await page.load(throwing.url)
    const regions = await page.evaluate(REGIONS)
    assertCoreDrawn(regions)
    assert.equal(regions.damage, 2, 'the failing module adds no damage line')
    const line = await page.evaluate("[...document.querySelectorAll('#foot .damage-line')].map((l) => l.textContent).join('\\n')")
    assert.match(line, /board/)
    assert.equal(await page.evaluate("document.querySelector('[data-module=\"board\"]').hidden"), true)
  },
}

let failed = 0
try {
  for (const [name, test] of Object.entries(tests)) {
    try {
      await test()
      console.log(`ok   ${name}`)
    } catch (error) {
      failed++
      console.log(`FAIL ${name}\n     ${String(error.message).split('\n').join('\n     ')}`)
    }
  }
} finally {
  await close()
  rmSync(main.dir, { recursive: true, force: true })
  rmSync(throwing.dir, { recursive: true, force: true })
}
if (failed) {
  console.log(`${failed} failed`)
  process.exit(1)
}
