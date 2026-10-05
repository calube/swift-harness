// Checks the run viewer page in headless Chrome with a RunView built here: every region draws,
// the span popover works from the keyboard and closes on Escape or an outside click, it is a bottom
// sheet at phone width, the zoom scales the track and not the page, the task drawer opens with and
// without a brief, and a module that throws can't blank the page. Served by a stub server, the page
// polls for changes, merges each partial, and shows the now strip; the embedded report hides it.
// The tabs: Overview by default or the URL's #token, badges counted from the view, the arrow keys,
// a task row's popover, and a poll that keeps the open tab and its scroll.
// Run: node tests/run_viewer_page_test.mjs
// Regressions caught: a popover the keyboard can't reach or that keeps focus, a zoom that widens
// the page, a drawer that needs a brief, a module able to blank the core regions, and a console
// error on load, a poll that refetches the whole view, a failed poll that stops live mode, and a
// strip shown in a static report.
import assert from 'node:assert/strict'
import { createServer } from 'node:http'
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

function writePage(extraScript, data = view) {
  const dir = mkdtempSync(join(tmpdir(), 'run-viewer-page-'))
  for (const name of PAGE_FILES) copyFileSync(new URL(name, viewer), join(dir, name))
  let html = readFileSync(join(dir, 'run-viewer.html'), 'utf8')
  const embedded = JSON.stringify(data).replace(/</g, '\\u003c')
  assert.ok(html.includes('<script type="application/json" id="run-view"></script>'), 'the page has no empty run-view script')
  html = html.replace('<script type="application/json" id="run-view"></script>', `<script type="application/json" id="run-view">${embedded}</script>`)
  if (extraScript) {
    writeFileSync(join(dir, 'run-viewer-zz-test.js'), extraScript)
    html = html.replace('<script src="run-viewer.js"></script>', '<script src="run-viewer.js"></script>\n<script src="run-viewer-zz-test.js"></script>')
  }
  writeFileSync(join(dir, 'run-viewer.html'), html)
  return { dir, url: pathToFileURL(join(dir, 'run-viewer.html')).href }
}

// A live view whose times sit around the test's own clock, since the page measures open spans and
// stalls against Date.now().
const nowAt = Date.now()
const ago = (minutes) => new Date(nowAt - minutes * 60000).toISOString()
const liveView = {
  schemaVersion: 1, cursor: 'c0',
  run: { id: '20261003T140000Z-live0001', plan: 'sample-notes', preset: 'default', stallMin: 3, startedAt: ago(12), endedAt: null, state: 'running' },
  spec: [{ id: 'req-save-note', title: 'Save a note', tasks: ['store', 'list'] }],
  tasks: [
    { ...view.tasks[0], status: 'in-progress', mergedAt: null, commits: [], mergeGateRun: null, gateRun: null, createdAt: ago(11), tokens: null },
    { ...view.tasks[1], createdAt: ago(11) },
  ],
  roles: [],
  spans: [
    span('r1', null, 'run', 0, null, { start: ago(12) }),
    span('t-store', 'r1', 'task', 0, null, { task: 'store', start: ago(10) }),
    span('w-store', 't-store', 'worker', 0, null, { task: 'store', start: ago(10) }),
    span('t-list', 'r1', 'task', 0, null, { task: 'list', start: ago(10) }),
    span('w-list', 't-list', 'worker', 0, null, { task: 'list', start: ago(10) }),
  ],
  gates: [], proofs: [], halts: [], damage: [],
}
// Each cursor's answer. The second request after c1 fails once, so a failed poll must keep going.
const changes = {
  c0: [{ cursor: 'c1', spans: [span('w-store', 't-store', 'worker', 0, 0, { task: 'store', start: ago(10), end: ago(1), outcome: 'ok' }), span('g-store', 't-store', 'gate', 0, null, { task: 'store', start: ago(1) })] }],
  c1: [null, { cursor: 'c2', spans: [span('v-store', 't-store', 'verify', 0, null, { task: 'store', start: ago(0.5) })] }],
  c2: [{ cursor: 'c3', halts: [{ task: 'list', reason: 'gate-red', at: ago(9), answer: null, waitMs: null }] }],
  c3: [{ cursor: 'c3' }],
}

// Serves the page as `swiftgate view` does; `modules` adds those module scripts and styles.
function startLiveServer(modules = []) {
  const files = PAGE_FILES.concat(modules.flatMap((m) => [`run-viewer-${m}.js`, `run-viewer-${m}.css`]))
  const requests = []
  const missing = []
  const seen = {}
  const server = createServer((req, res) => {
    const url = new URL(req.url, 'http://127.0.0.1')
    requests.push(url.pathname + url.search)
    const json = (status, body) => { res.writeHead(status, { 'content-type': 'application/json' }); res.end(JSON.stringify(body)) }
    if (url.pathname === '/view.json') return json(200, liveView)
    if (url.pathname === '/changes') {
      const after = url.searchParams.get('after')
      const answers = changes[after]
      if (!answers) return json(400, { error: 'unknown cursor' })
      const n = seen[after] = (seen[after] ?? -1) + 1
      const body = answers[Math.min(n, answers.length - 1)]
      return body ? json(200, body) : json(503, { error: 'store busy' })
    }
    const name = url.pathname === '/' ? 'run-viewer.html' : url.pathname.slice(1)
    if (!files.includes(name)) { missing.push(url.pathname); res.writeHead(404); return res.end() }
    const type = name.endsWith('.css') ? 'text/css' : name.endsWith('.js') ? 'text/javascript' : 'text/html'
    res.writeHead(200, { 'content-type': type })
    let body = readFileSync(new URL(name, viewer), 'utf8')
    if (name === 'run-viewer.html') {
      for (const m of modules) {
        body = body.replace('<script src="run-viewer.js"></script>', `<script src="run-viewer.js"></script>\n<script src="run-viewer-${m}.js"></script>`)
          .replace('<link rel="stylesheet" href="run-viewer.css">', `<link rel="stylesheet" href="run-viewer.css">\n<link rel="stylesheet" href="run-viewer-${m}.css">`)
      }
    }
    res.end(body)
  })
  return new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve({
    server, requests, missing, url: `http://127.0.0.1:${server.address().port}/`,
  })))
}

// Resolves once `condition` (an expression over the page) holds, read on every DOM change, or
// rejects naming it after `ms`. The page's own 1 s poll drives the changes; nothing here sleeps.
const until = (condition, ms = 6000) => `new Promise((resolve, reject) => {
  const check = () => { const v = (${condition}); if (v) { observer.disconnect(); clearTimeout(timer); resolve(v) } }
  const observer = new MutationObserver(check)
  const timer = setTimeout(() => { observer.disconnect(); reject(new Error(${JSON.stringify('timed out waiting for: ' + condition)})) }, ${ms})
  observer.observe(document.documentElement, { subtree: true, childList: true, attributes: true, characterData: true })
  check()
})`

const REGIONS = `(() => ({
  meta: document.querySelectorAll('#meta span').length,
  stats: document.querySelectorAll('#stats .stat').length,
  bars: document.querySelectorAll('#tl .bar').length,
  spec: document.querySelectorAll('#spec-table tbody tr').length,
  proof: document.querySelectorAll('#proof tbody tr').length,
  tokens: document.querySelectorAll('#token-rows .tok-row').length,
  roles: document.querySelectorAll('#roles .tok-row').length,
  gates: document.querySelectorAll('#gate-list .gate').length,
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

// The tab strip: its tab ids in order, the selected and focused tab, the panels shown, the URL's
// #token, each tab's badges by key, and each tab's accessible name.
const TABS = `(() => {
  const tabs = [...document.querySelectorAll('[role=tab]')].filter((t) => !t.hidden)
  return {
    ids: tabs.map((t) => t.dataset.tab),
    selected: tabs.find((t) => t.getAttribute('aria-selected') === 'true')?.dataset.tab ?? null,
    focused: document.activeElement?.getAttribute('role') === 'tab' ? document.activeElement.dataset.tab : null,
    shown: [...document.querySelectorAll('[role=tabpanel]')].filter((p) => !p.hidden && p.offsetHeight > 0).map((p) => p.dataset.tab),
    hash: location.hash,
    badges: Object.fromEntries(tabs.filter((t) => t.querySelector('.badge')).map((t) => [t.dataset.tab, Object.fromEntries([...t.querySelectorAll('.badge')].map((b) => [b.dataset.key, b.dataset.n]))])),
    labels: Object.fromEntries(tabs.map((t) => [t.dataset.tab, t.getAttribute('aria-label')])),
  }
})()`
// Loads `url` from a blank page, since a change of #token alone is a same-document navigation that
// fires no load event.
const loadFresh = async (url) => { await page.load('about:blank'); await page.load(url) }
const selectTab = (id) => `document.querySelector('[role=tab][data-tab="${id}"]').click()`

const POPOVER = `(() => { const p = document.getElementById('pop'); const r = p.getBoundingClientRect();
  return { hidden: p.hidden, title: document.getElementById('pop-title').textContent, body: document.getElementById('pop-body').textContent,
    focusInPop: p.contains(document.activeElement), active: document.activeElement.dataset.id ?? null,
    bottom: r.bottom, left: r.left, width: r.width, innerHeight, innerWidth: document.documentElement.clientWidth } })()`

if (!findChrome()) {
  console.log('skip run viewer page checks: no Chrome binary (set CHROME_PATH)')
  process.exit(0)
}

const { page, close } = await launch({ deadlineMs: 45000 })
const main = writePage()
const throwing = writePage("window.runViewer.register('board', { render() { throw new Error('board exploded') }, apply() {} })")
// A report written while its run was still going: before the first ledger event, with no spec page yet.
const snapshot = writePage(null, {
  ...view, spec: [], damage: [],
  run: { ...view.run, state: 'running', endedAt: null, snapshotAt: '2026-10-03T14:41:00.000Z' },
  unwritten: [{ source: 'swift-harness/plans/sample-notes/build/20261003T140000Z-0a1b2c3d/events.jsonl', reason: 'not written yet' }],
})

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
    const text = await page.evaluate("document.body.textContent")
    assert.match(text, /pending/, 'null tokens do not read pending')
    assert.match(text, /uncovered/, 'a requirement with no task is not flagged')
    assert.doesNotMatch(text, /undefined|NaN/)
    const openTitle = await page.evaluate("[...document.querySelectorAll('#tl .bar')].map((b) => b.title).find((t) => t.includes('never ended')) ?? null")
    assert.ok(openTitle, 'an open span does not read never ended')
  },

  async 'the tab strip names Overview to Tokens with Overview selected and every other panel hidden — catches a tab layout that still shows 1 long page'() {
    const tabs = await page.evaluate(TABS)
    assert.deepEqual(tabs.ids, ['overview', 'timeline', 'spec', 'gates', 'tokens'], 'without the board and graph modules their tabs show')
    assert.equal(tabs.selected, 'overview')
    assert.deepEqual(tabs.shown, ['overview'])
    assert.equal(tabs.hash, '')
  },

  async 'badges carry the view\'s counts on every tab: an uncovered requirement, a never-ended span and a pending task — catches a badge that drifts from the data'() {
    const tabs = await page.evaluate(TABS)
    assert.deepEqual(tabs.badges, { spec: { uncovered: '1' }, timeline: { unended: '1' }, tokens: { pending: '1' } })
    assert.match(tabs.labels.spec, /Spec, 1 uncovered/, 'a badge is missing from the tab\'s accessible name')
  },

  async 'a task row opens a details popover with its column, deps, latest gate, commits and covers, and Open task opens the drawer; Escape returns focus to the row — catches a task popover read from the wrong task'() {
    await page.evaluate("document.querySelector('#tab-overview .task-link[data-task=\"store\"]').click()")
    const pop = await page.evaluate(POPOVER)
    assert.equal(pop.hidden, false, 'a task row opens no popover')
    assert.equal(pop.title, 'store')
    for (const text of [/Save notes to a local store/, /merged/, /g-store/, /4be91c0/, /req-save-note/, /none/]) assert.match(pop.body, text)
    await page.evaluate("document.querySelector('#pop [data-open-task]').click()")
    const drawer = await page.evaluate("({ open: document.getElementById('drawer').classList.contains('open'), id: document.getElementById('dr-id').textContent })")
    assert.deepEqual(drawer, { open: true, id: 'store' })
    await page.press('Escape')
    assert.equal(await page.evaluate("document.activeElement.dataset.task ?? null"), 'store', 'closing the drawer loses the row')
    await page.evaluate("document.querySelector('#tab-overview .task-link[data-task=\"list\"]').focus()")
    await page.press('Enter')
    let after = await page.evaluate(POPOVER)
    assert.equal(after.title, 'list', 'Enter on a task row opens no popover')
    assert.match(after.body, /store/, 'the deps are missing')
    await page.press('Escape')
    after = await page.evaluate(POPOVER)
    assert.equal(after.hidden, true)
    assert.equal(await page.evaluate("document.activeElement.dataset.task ?? null"), 'list')
    assert.deepEqual(page.errors, [])
  },

  async 'clicking a tab shows its panel and writes its #token, and the arrow keys move between tabs — catches a tab the URL or keyboard loses'() {
    await page.evaluate(selectTab('gates'))
    let tabs = await page.evaluate(TABS)
    assert.equal(tabs.selected, 'gates')
    assert.deepEqual(tabs.shown, ['gates'])
    assert.equal(tabs.hash, '#gates')
    await page.evaluate("document.querySelector('[role=tab][data-tab=\"gates\"]').focus()")
    await page.press('ArrowRight')
    tabs = await page.evaluate(TABS)
    assert.equal(tabs.selected, 'tokens')
    assert.equal(tabs.focused, 'tokens', 'the arrow key does not move focus')
    await page.press('ArrowLeft')
    await page.press('ArrowLeft')
    tabs = await page.evaluate(TABS)
    assert.equal(tabs.selected, 'spec')
    await page.evaluate(selectTab('timeline'))
    assert.deepEqual(page.errors, [])
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

  async '#gates in the URL opens the Gates tab on load — catches a selection the link does not carry'() {
    await loadFresh(main.url + '#gates')
    const tabs = await page.evaluate(TABS)
    assert.equal(tabs.selected, 'gates')
    assert.deepEqual(tabs.shown, ['gates'])
    assert.equal(await page.evaluate("window.scrollY"), 0, 'the #token scrolls the page to an element')
    await loadFresh(main.url + '#nonsense')
    assert.equal((await page.evaluate(TABS)).selected, 'overview', 'an unknown #token selects no tab')
  },

  async 'at a 390 px viewport the popover is a bottom sheet and the tab strip scrolls inside itself — catches a popover anchored off a phone screen'() {
    await page.viewport(390, 800)
    await loadFresh(main.url + '#timeline')
    assert.equal(await page.evaluate("document.documentElement.scrollWidth <= document.documentElement.clientWidth"), true, 'the tab strip widens the page')
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

  async 'a report of a run still going says when it was taken in its header, its unwritten files read not written yet without counting as damage, and its empty Spec tab says the plan has no spec page — catches a mid-run snapshot read as a damaged final report'() {
    await page.viewport(1280, 900)
    await page.load(snapshot.url)
    const read = await page.evaluate(`(() => {
      document.querySelector('[role=tab][data-tab="spec"]').click()
      return { banner: document.getElementById('snapshot')?.textContent ?? null, bannerHidden: document.getElementById('snapshot')?.hidden ?? null,
        foot: document.getElementById('foot').textContent, damage: document.querySelectorAll('#foot .damage-line').length,
        unwritten: [...document.querySelectorAll('#foot .unwritten-line')].map((l) => l.textContent),
        spec: document.querySelector('.tab-panel[data-tab="spec"]').innerText, errors: document.body.dataset.errors }
    })()`)
    assert.equal(read.banner, 'Snapshot at 2026-10-03 14:41 UTC, run still running')
    assert.equal(read.bannerHidden, false)
    assert.equal(read.damage, 0)
    assert.match(read.foot, /damage: none/)
    assert.deepEqual(read.unwritten, ['swift-harness/plans/sample-notes/build/20261003T140000Z-0a1b2c3d/events.jsonl: not written yet'])
    assert.match(read.spec, /no spec page/i)
    assert.equal(read.errors, '0')
    assert.deepEqual(page.errors, [])
    await page.load(main.url)
    assert.equal(await page.evaluate("document.getElementById('snapshot')?.hidden ?? null"), true, 'a final report shows a snapshot banner')
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

  async 'served, the page merges 3 polled partials through a failed poll, the cursor advances, and the strip badges a halt and a stall, which the embedded report hides — catches a poll that refetches everything'() {
    const live = await startLiveServer()
    try {
      await page.load(live.url)
      const failedLine = await page.evaluate(until("document.body.dataset.pollFailures === '1' && document.getElementById('live-error').textContent"))
      assert.match(failedLine, /503/, 'a failed poll shows no line in the header')
      await page.evaluate(until("Number(document.body.dataset.polls) >= 4"))
      const after = live.requests.filter((r) => r.startsWith('/changes')).map((r) => new URL(r, 'http://x').searchParams.get('after'))
      assert.deepEqual(after.slice(0, 4), ['c0', 'c1', 'c1', 'c2'], 'the cursor does not advance with each answer')
      assert.equal(live.requests.filter((r) => r === '/view.json').length, 1, 'the page refetches the full view')
      const state = await page.evaluate(`(() => ({
        error: document.getElementById('live-error').hidden,
        cards: [...document.querySelectorAll('#now .now-card')].map((c) => ({ task: c.dataset.task, text: c.textContent })),
        storeWorkerOpen: document.querySelector('#tl .bar[data-id="w-store"]').classList.contains('open'),
        verify: !!document.querySelector('#tl .bar[data-id="v-store"]'),
        text: document.body.innerText,
        errors: document.body.dataset.errors,
      }))()`)
      assert.equal(state.error, true, 'the failed-poll line stays after a poll succeeds')
      assert.equal(state.storeWorkerOpen, false, 'the first partial did not end the worker span')
      assert.ok(state.verify, 'the second partial did not add its span')
      assert.deepEqual(state.cards.map((c) => c.task), ['store', 'list'])
      assert.match(state.cards[0].text, /verify/, 'the card does not name the newest open stage')
      assert.doesNotMatch(state.cards[0].text, /halted|stalled/)
      assert.match(state.cards[1].text, /halted/, 'the halted task shows no halt badge')
      assert.match(state.cards[1].text, /stalled/, 'a task quiet past stall_min shows no stall badge')
      assert.match(state.text, /pending/, 'a running worker\'s tokens do not read pending')
      assert.equal(state.errors, '0')
      // Chrome logs each failed load; the stubbed 503 is meant, and the browser asks for a favicon.
      assert.deepEqual(live.missing.filter((p) => p !== '/favicon.ico'), [], 'the page asks for a file it does not ship')
      assert.deepEqual(page.errors.filter((e) => !/status of (503|404)/.test(e)), [])
    } finally {
      await new Promise((resolve) => live.server.close(resolve))
    }
    await page.load(main.url)
    const embedded = await page.evaluate("({ strip: document.getElementById('now')?.offsetHeight ?? 0, live: document.body.dataset.live ?? null })")
    assert.deepEqual(embedded, { strip: 0, live: null }, 'the embedded report shows the now strip')
  },

  async 'served with the board module on #board, the board draws from the fetched view and its cards move on each poll — catches a module that registered before live data and never drew'() {
    const live = await startLiveServer(['board'])
    try {
      await loadFresh(live.url + '#board')
      await page.evaluate(until("Number(document.body.dataset.polls) >= 4"))
      const state = await page.evaluate(`(() => ({
        tab: document.body.dataset.tab,
        mountHidden: document.querySelector('[data-module="board"]').hidden,
        cards: [...document.querySelectorAll('[data-module="board"] .card')].map((c) => [c.dataset.task, c.closest('.lane').dataset.lane]),
        damage: [...document.querySelectorAll('#foot .damage-line')].map((l) => l.textContent),
      }))()`)
      assert.deepEqual(state.damage, [], 'the board module failed on a live poll')
      assert.equal(state.mountHidden, false)
      assert.equal(state.tab, 'board')
      assert.deepEqual(Object.fromEntries(state.cards), { store: 'gating', list: 'blocked' })
    } finally {
      await new Promise((resolve) => live.server.close(resolve))
    }
  },

  async 'served on #timeline, polled updates keep the Timeline tab, its zoom and scroll, and move the badges — catches a poll that resets the selection'() {
    const live = await startLiveServer()
    try {
      await page.load(live.url + '#timeline')
      await page.evaluate(until("Number(document.body.dataset.polls) >= 1 && document.querySelector('#tl .bar')"))
      await page.evaluate("document.querySelector('#zoom button[data-z=\"4\"]').click()")
      await page.evaluate("document.getElementById('tl-scroll').scrollLeft = 400")
      const before = await page.evaluate(TABS)
      assert.deepEqual(before.badges.overview ?? {}, {}, 'precondition: no halt yet')
      await page.evaluate(until("Number(document.body.dataset.polls) >= 4"))
      const after = await page.evaluate(TABS)
      assert.equal(after.selected, 'timeline', 'a poll moves the selected tab')
      assert.deepEqual(after.shown, ['timeline'])
      assert.equal(after.hash, '#timeline')
      assert.equal(await page.evaluate("document.getElementById('tl-scroll').scrollLeft"), 400, 'a poll resets the timeline scroll')
      assert.deepEqual(after.badges.overview, { halted: '1' }, 'the halt from the poll shows no badge on Overview')
      assert.equal(after.badges.timeline?.stalled, '1', 'the quiet task shows no stall badge on Timeline')
      assert.equal(await page.evaluate("document.body.dataset.errors"), '0')
    } finally {
      await new Promise((resolve) => live.server.close(resolve))
    }
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
  rmSync(snapshot.dir, { recursive: true, force: true })
}
if (failed) {
  console.log(`${failed} failed`)
  process.exit(1)
}
