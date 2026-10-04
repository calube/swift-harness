// Checks the run viewer's Validation tab in headless Chrome with a RunView built here: the tab
// shows only for a run with validation rows, its strip and badges carry the counts, rows group by
// the task they run after with each group's waiting rows last, a red row opens "Why it failed" with
// its exit status and saved output, an unverified row opens "Why unverified" naming what didn't
// run, a qa.check bar on the timeline previews its reason, and no evidence is embedded.
// Run: node tests/run_viewer_validation_test.mjs
// Regressions caught: a Validation tab shown with nothing in it, a red check with no failure
// context, an unverified row that doesn't say what didn't run, an embedded thumbnail, and a
// console error from the module.
import assert from 'node:assert/strict'
import { copyFileSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { findChrome, launch } from './headless_chrome.mjs'

const viewer = new URL('../plugin/viewer/', import.meta.url)
const FILES = ['run-viewer.html', 'run-viewer.css', 'run-viewer.js', 'run-view-model.js', 'run-viewer-validation.js', 'run-viewer-validation.css']

const t0 = Date.parse('2026-10-03T14:00:00.000Z')
const at = (minutes) => new Date(t0 + minutes * 60000).toISOString()
const task = (id, status) => ({
  id, status, model: 'opus', deps: [], writes: [], gate: 'push', covers: [], commits: [], gateRun: null,
  mergeGateRun: null, createdAt: at(1), mergedAt: null, brief: null, tokens: null, blocked: null, failureReason: null,
})
const row = (n, layer, result, runsAfter, extra = {}) => ({
  row: n, requirement: 'req-save-note', layer, check: null, runsAfter, result, message: null, exitStatus: null, ms: 0,
  evidence: [], waitingOn: [], qaRun: '20261003T143000Z-0000aaaa', at: at(30), output: [], outputCut: false, ...extra,
})
const validation = {
  plan: 'sample-notes',
  counts: { pass: 1, red: 1, unverified: 1, waiting: 1 },
  rows: [
    row(1, 'acceptance', 'pass', ['store'], { check: 'curl -fsS localhost:$QA_PORT/notes', exitStatus: 0, ms: 420, message: 'exit 0', evidence: ['qa/01-req-save-note.acceptance.txt'] }),
    row(2, 'acceptance', 'red', ['list'], {
      check: 'notes-cli list --newest-first', exitStatus: 1, ms: 900, message: 'exit 1', evidence: ['qa/02-req-save-note.acceptance.txt'],
      output: ['$ notes-cli list --newest-first', 'exit: 1', '--- stderr ---', 'expected newest first, got oldest first'], outputCut: true,
    }),
    row(3, 'flow', 'unverified', ['list'], { check: 'save-note.flow.json', message: 'not run: the acceptance layer has a red row' }),
    row(4, 'state', 'waiting', ['store', 'share'], { check: 'save-note.state.sh', waitingOn: ['share'] }),
  ],
}
const view = (extra = {}) => ({
  schemaVersion: 1, cursor: null,
  run: { id: '20261003T140000Z-0a1b2c3d', plan: 'sample-notes', preset: 'default', startedAt: at(0), endedAt: at(40), state: 'done', stallMin: null, timeBox: null },
  spec: [], tasks: [task('store', 'done'), task('list', 'done'), task('share', 'pending')], roles: [],
  spans: [
    { id: 'run', parent: null, phase: 'run', task: null, gateRun: null, start: at(0), end: at(40), outcome: 'ok', approximate: false, tools: null, causeGateRun: null, failureReason: null, baseline: false },
    { id: 'qa:20261003T143000Z-0000aaaa:2', parent: 'run', phase: 'qa.check', task: null, gateRun: null, start: at(20), end: at(30), outcome: 'red', approximate: false, tools: null, causeGateRun: null, failureReason: 'Row 2 acceptance check failed with exit 1.', baseline: false },
  ],
  gates: [], proofs: [], halts: [], validation, damage: [], ...extra,
})

const dirs = []
function writePage(data) {
  const dir = mkdtempSync(join(tmpdir(), 'run-viewer-validation-'))
  dirs.push(dir)
  for (const name of FILES) copyFileSync(new URL(name, viewer), join(dir, name))
  const html = readFileSync(join(dir, 'run-viewer.html'), 'utf8')
    .replace('<script type="application/json" id="run-view"></script>', `<script type="application/json" id="run-view">${JSON.stringify(data).replace(/</g, '\\u003c')}</script>`)
    .replace('<link rel="stylesheet" href="run-viewer.css">', '<link rel="stylesheet" href="run-viewer.css">\n<link rel="stylesheet" href="run-viewer-validation.css">')
    .replace('<script src="run-viewer.js"></script>', '<script src="run-viewer.js"></script>\n<script src="run-viewer-validation.js"></script>')
  writeFileSync(join(dir, 'run-viewer.html'), html)
  return pathToFileURL(join(dir, 'run-viewer.html')).href
}

const TAB = `(() => {
  const tab = document.querySelector('[role=tab][data-tab="validation"]')
  const mount = document.querySelector('[data-module="validation"]')
  return {
    tabs: [...document.querySelectorAll('[role=tab]')].filter((t) => !t.hidden).map((t) => t.dataset.tab),
    badges: tab ? Object.fromEntries([...tab.querySelectorAll('.badge')].map((b) => [b.dataset.key, Number(b.dataset.n)])) : null,
    strip: mount ? Object.fromEntries([...mount.querySelectorAll('.qa-count')].map((c) => [c.dataset.result, Number(c.querySelector('b').textContent)])) : null,
    groups: mount ? [...mount.querySelectorAll('.qa-group')].map((g) => [g.dataset.task, [...g.querySelectorAll('.qa-row')].map((r) => r.dataset.row + ':' + r.dataset.result + (r.classList.contains('qa-waiting') ? ':waiting-on' : ''))]) : null,
    waitingText: mount ? [...mount.querySelectorAll('.qa-waiting')].map((r) => r.innerText) : null,
    flowText: mount?.querySelector('.qa-row[data-row="3"]')?.innerText ?? null,
    flowLists: mount ? mount.querySelectorAll('.qa-row[data-row="3"] ol, .qa-row[data-row="3"] ul').length : null,
    media: document.querySelectorAll('img, video').length,
    height: mount?.offsetHeight ?? 0,
    errors: document.body.dataset.errors,
  }
})()`
const POPOVER = `(() => { const p = document.getElementById('pop');
  return { hidden: p.hidden, title: document.getElementById('pop-title').textContent, text: p.innerText,
    rows: [...p.querySelectorAll('dt')].map((dt) => [dt.innerText.toLowerCase(), dt.nextElementSibling.innerText]),
    active: document.activeElement?.dataset.key ?? null } })()`
const why = (n) => `(() => { document.querySelector('[role=tab][data-tab="validation"]').click(); const b = document.querySelector('.qa-row[data-row="${n}"] .qa-why'); b.click(); return b.innerText })()`

if (!findChrome()) {
  console.log('skip run viewer validation checks: no Chrome binary (set CHROME_PATH)')
  process.exit(0)
}

const { page, close } = await launch({ deadlineMs: 45000 })
const withRows = writePage(view())
const withoutRows = writePage(view({ validation: null }))

const tests = {
  async 'a run with validation rows shows the Validation tab last, its badges and strip carry the counts, and rows group by task with each group\'s waiting rows last — catches a shared check shown under 1 task or a count that drifts'() {
    await page.load(withRows)
    await page.evaluate(`document.querySelector('[role=tab][data-tab="validation"]').click()`)
    const tab = await page.evaluate(TAB)
    assert.equal(tab.tabs[tab.tabs.length - 1], 'validation')
    assert.deepEqual(tab.badges, { red: 1, unverified: 1, waiting: 1 })
    assert.deepEqual(tab.strip, { pass: 1, red: 1, unverified: 1, waiting: 1 })
    assert.deepEqual(tab.groups, [
      ['store', ['1:pass', '4:waiting:waiting-on']],
      ['list', ['2:red', '3:unverified']],
      ['share', ['4:waiting:waiting-on']],
    ])
    assert.ok(tab.waitingText.every((text) => /waiting on share/.test(text)), JSON.stringify(tab.waitingText))
    assert.ok(tab.height > 0)
    assert.equal(tab.errors, '0')
    assert.deepEqual(page.errors, [])
  },

  async 'a flow row shows its result alone and the page embeds no image or video — catches an embedded thumbnail or a step list drawn before the final pass records one'() {
    await page.load(withRows)
    await page.evaluate(`document.querySelector('[role=tab][data-tab="validation"]').click()`)
    const tab = await page.evaluate(TAB)
    assert.match(tab.flowText, /unverified/)
    assert.equal(tab.flowLists, 0)
    assert.equal(tab.media, 0)
  },

  async 'a red row opens "Why it failed" with its check, exit status, reason, evidence path and saved output, and Escape returns focus to its button — catches a red check with no failure context'() {
    await page.load(withRows)
    assert.equal(await page.evaluate(why(2)), 'Why it failed')
    const pop = await page.evaluate(POPOVER)
    assert.equal(pop.hidden, false)
    assert.equal(pop.title, 'Why it failed')
    const rows = Object.fromEntries(pop.rows)
    assert.equal(rows['exit status'], '1')
    assert.equal(rows.check, 'notes-cli list --newest-first')
    assert.equal(rows.evidence, 'qa/02-req-save-note.acceptance.txt')
    assert.match(pop.text, /Saved output, last 4 lines/i)
    assert.match(pop.text, /expected newest first, got oldest first/)
    await page.press('Escape')
    const after = await page.evaluate(POPOVER)
    assert.equal(after.hidden, true)
    assert.equal(after.active, '1:2')
  },

  async 'an unverified row opens "Why unverified" naming the check that didn\'t run and why — catches an unverified row read as a pass'() {
    await page.load(withRows)
    assert.equal(await page.evaluate(why(3)), 'Why unverified')
    const pop = await page.evaluate(POPOVER)
    assert.equal(pop.title, 'Why unverified')
    const rows = Object.fromEntries(pop.rows)
    assert.equal(rows["didn't run"], 'flow check save-note.flow.json')
    assert.equal(rows.why, 'not run: the acceptance layer has a red row')
    assert.equal(await page.evaluate(`document.querySelectorAll('.qa-row[data-result="pass"] .qa-why, .qa-row[data-result="waiting"] .qa-why').length`), 0)
  },

  async 'hovering a qa.check bar on the timeline previews its failure reason — catches a validation check missing from the timeline'() {
    await page.viewport(1280, 900)
    await page.load(withRows)
    await page.evaluate(`document.querySelector('[role=tab][data-tab="timeline"]').click()`)
    const box = await page.evaluate(`(() => { const b = document.querySelector('#tl .bar[data-id="qa:20261003T143000Z-0000aaaa:2"]');
      const r = b.getBoundingClientRect(); return { x: r.left + Math.min(4, r.width / 2), y: r.top + r.height / 2, label: b.innerText || b.getAttribute('aria-label') } })()`)
    assert.match(box.label, /qa check/)
    await page.hover(box.x, box.y)
    const pop = await page.evaluate(POPOVER)
    assert.equal(pop.hidden, false)
    assert.deepEqual(pop.rows.find(([label]) => label === 'failure reason'), ['failure reason', 'Row 2 acceptance check failed with exit 1.'])
  },

  async 'a run with no validation rows has no Validation tab and no console error — catches an empty tab'() {
    await page.load(withoutRows)
    const tab = await page.evaluate(TAB)
    assert.ok(!tab.tabs.includes('validation'))
    assert.equal(tab.errors, '0')
    assert.deepEqual(page.errors, [])
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
  for (const dir of dirs) rmSync(dir, { recursive: true, force: true })
}
if (failed) {
  console.log(`${failed} failed`)
  process.exit(1)
}
