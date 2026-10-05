// Checks the run viewer's Validation tab in headless Chrome with a RunView built here: the tab
// shows only for a run with validation rows, its strip and badges carry the counts, rows group by
// the task they run after with each group's waiting rows last, a red row opens "Why it failed" with
// its exit status and saved output, an unverified row opens "Why unverified" naming what didn't
// run, a qa.check bar on the timeline previews its reason, a flow row lists its steps linked to
// the video at each offset and links its contact sheet, a flow's qa.check bar carries 1 tick per
// step, a missing video or sheet opens "Why unverified" with its reason, kept XCUITest flows list
// by flow and test, a task popover lists the task's rows, and no evidence is embedded.
// Run: node tests/run_viewer_validation_test.mjs
// Regressions caught: a Validation tab shown with nothing in it, a red check with no failure
// context, an unverified row that doesn't say what didn't run, an embedded thumbnail, a flow step
// with no video link, a missing sheet read as verified, a dropped kept flow, and a console error
// from the module.
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

const QA = '20261003T143000Z-0000aaaa'
const GATE = '20261003T143500Z-0000bbbb'
const steps = (oks) => oks.map((ok, i) => ({ n: i + 1, label: ['wait id="counter.value"', 'press id="counter.increment"', 'is text id="counter.value" "1"'][i] ?? null, offsetMs: [0, 2577, 3629][i] ?? 4000, ok }))
const flowRecord = (row, extra = {}) => ({
  source: 'batch', run: QA, steps: steps([true, true, true]),
  video: `qa/0${row}-req-save-note.flow/video.mp4`, sheet: `qa/0${row}-req-save-note.flow/sheet.png`,
  videoUnverified: null, sheetUnverified: null, ...extra,
})
const flowValidation = {
  plan: 'sample-notes',
  counts: { pass: 1, red: 1, unverified: 0, waiting: 0 },
  rows: [
    row(1, 'flow', 'pass', ['store'], { check: 'save-note.flow.json', ms: 6000, message: 'batch passed', flow: flowRecord(1, { sheet: null, sheetUnverified: 'sheetFailed' }) }),
    row(2, 'flow', 'red', ['list'], { check: 'list.flow.json', ms: 5000, message: 'step 3 `is` failed', flow: flowRecord(2, { steps: steps([true, true, false]) }) }),
  ],
  keptFlows: [
    { name: 'counter', test: 'CounterFlowUITests/testFact()', gateRun: GATE, task: 'store', at: at(35), flow: { source: 'xcuitest', run: GATE, steps: steps([true, true]), video: 'qa/xcuitest/CounterFlowUITests-testFact/video.mp4', sheet: 'qa/xcuitest/CounterFlowUITests-testFact/sheet.png', videoUnverified: null, sheetUnverified: null } },
    { name: 'counter', test: 'CounterFlowUITests/testIncrement()', gateRun: GATE, task: null, at: at(35), flow: { source: 'xcuitest', run: GATE, steps: steps([true]), video: null, sheet: null, videoUnverified: 'noVideoAttachment', sheetUnverified: null } },
  ],
}
const flowView = view({
  validation: flowValidation,
  spans: [
    view().spans[0],
    { id: `qa:${QA}:2`, parent: 'run', phase: 'qa.check', task: null, gateRun: null, start: at(20), end: at(30), outcome: 'red', approximate: false, tools: null, causeGateRun: null, failureReason: 'Row 2 flow check failed.', baseline: false, flow: flowRecord(2, { steps: steps([true, true, false]) }) },
  ],
})

// Rows whose earlier qa runs the view keeps: a row an at-base run read red and a later run passed,
// and a row only the at-base run checked.
const attempt = (qaRun, stage, result, extra = {}) => ({
  qaRun, stage, after: null, result, message: null, exitStatus: null, ms: 0, evidence: [], waitingOn: [], reusedFrom: null,
  at: at(30), output: [], outputCut: false, flow: null, ...extra,
})
const BASE = '20261003T142000Z-0000cccc'
const historyView = view({
  validation: {
    plan: 'sample-notes',
    counts: { pass: 1, red: 0, unverified: 0, waiting: 0, abandoned: 0, atBase: 1 },
    rows: [
      row(1, 'acceptance', 'pass', ['store'], {
        check: 'notes-cli save', exitStatus: 0, ms: 420, message: 'exit 0',
        history: [
          attempt(QA, 'after', 'pass', { after: 'store', exitStatus: 0, ms: 420, message: 'exit 0' }),
          attempt(BASE, 'at-base', 'red', { exitStatus: 1, ms: 300, message: 'exit 1', evidence: ['qa/01-req-save-note.acceptance.txt'], output: ['no such command: save'], reusedFrom: '20261003T141000Z-0000dddd' }),
        ],
      }),
      row(2, 'acceptance', 'red', ['list'], {
        check: 'notes-cli list', exitStatus: 1, ms: 200, message: 'exit 1', qaRun: BASE, atBase: true,
        history: [attempt(BASE, 'at-base', 'red', { exitStatus: 1, ms: 200, message: 'exit 1' })],
      }),
    ],
    keptFlows: [],
  },
})

// A flow row abandoned at the final run, whose before-merge run passed with a video.
const FINAL = '20261003T145000Z-0000eeee'
const LAST_PASS = `passed before merge of notes/fix-list, qa run ${QA}; final qa run ${FINAL} read abandoned: not run: list was abandoned before it merged`
const lastPassView = view({
  validation: {
    plan: 'sample-notes',
    counts: { pass: 0, red: 0, unverified: 0, waiting: 0, abandoned: 1, atBase: 0 },
    rows: [
      row(1, 'flow', 'abandoned', ['list'], {
        check: 'save-note.flow.json', qaRun: FINAL, message: 'not run: list was abandoned before it merged',
        history: [
          attempt(FINAL, 'final', 'abandoned', { message: 'not run: list was abandoned before it merged' }),
          attempt(QA, 'after', 'pass', { after: 'list', ms: 6000, message: 'batch passed', flow: flowRecord(1) }),
        ],
        lastPass: { qaRun: QA, label: LAST_PASS, flow: flowRecord(1) },
      }),
    ],
    keptFlows: [],
  },
})

// A flow row whose flow a repair rewrote after 2 red runs, from its qa.repair.
const REPAIRED = '20261003T144500Z-0000ffff'
const REPAIR_NOTE = `flow repaired (flow-side) after qa runs ${QA}, ${BASE} read red at step 6 \`wait\`: \`scroll\` replaced by \`gesture\`; red at the base again in qa run ${REPAIRED}`
const repairView = view({
  validation: {
    plan: 'sample-notes',
    counts: { pass: 0, red: 1, unverified: 0, waiting: 0, abandoned: 0, atBase: 0 },
    rows: [
      row(1, 'flow', 'red', ['list'], {
        check: 'refresh.flow.json', ms: 5000, message: 'step 6 `wait` failed',
        history: [attempt(QA, 'after', 'red', { after: 'list', ms: 5000, message: 'step 6 `wait` failed' })],
        repairs: [{ atBaseRun: REPAIRED, at: at(35), cause: 'flow-side', redRuns: [QA, BASE], failingStep: 6, failingCommand: 'wait', removed: ['scroll'], added: ['gesture'], note: REPAIR_NOTE }],
      }),
    ],
    keptFlows: [],
  },
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
const withFlows = writePage(flowView)
const withHistory = writePage(historyView)
const withLastPass = writePage(lastPassView)
const withRepair = writePage(repairView)
const FLOW = (n) => `(() => { document.querySelector('[role=tab][data-tab="validation"]').click()
  const r = document.querySelector('.qa-group:not(.qa-kept) .qa-row[data-row="${n}"]')
  return { steps: [...r.querySelectorAll('.qa-step')].map((li) => ({ n: li.dataset.n, ok: li.dataset.ok, mark: li.querySelector('.qa-mark').getAttribute('aria-label'), href: li.querySelector('a')?.getAttribute('href') ?? null, text: li.innerText })),
    sheet: r.querySelector('.qa-sheet')?.getAttribute('href') ?? null, video: r.querySelector('.qa-video')?.getAttribute('href') ?? null,
    why: r.querySelector('.qa-why')?.innerText ?? null, text: r.innerText, media: document.querySelectorAll('img, video').length, errors: document.body.dataset.errors } })()`

const tests = {
  async 'a repaired flow row shows its repair note, with the qa run that proved it red at the base again — catches a rewritten flow the report never mentions'() {
    await page.load(withRepair)
    const got = await page.evaluate(`(() => { document.querySelector('[role=tab][data-tab="validation"]').click()
      const r = document.querySelector('.qa-row[data-row="1"]')
      const notes = [...r.querySelectorAll('.qa-repair')]
      return { notes: notes.map((n) => n.innerText), runs: notes.map((n) => n.dataset.run), errors: document.body.dataset.errors } })()`)
    assert.deepEqual(got.runs, [REPAIRED])
    assert.equal(got.notes.length, 1)
    assert.ok(got.notes[0].includes(REPAIR_NOTE.replace(/`/g, '')), JSON.stringify(got.notes))
    assert.ok(!got.errors, got.errors)
  },

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

  async 'a flow row lists its steps with pass and fail marks, each linked to the video at its offset, and links its video and contact sheet, with no image or video element — catches a step with no video link or an embedded thumbnail'() {
    await page.load(withFlows)
    const red = await page.evaluate(FLOW(2))
    assert.deepEqual(red.steps.map((st) => [st.n, st.ok, st.mark]), [['1', 'true', 'passed'], ['2', 'true', 'passed'], ['3', 'false', 'failed']])
    assert.deepEqual(red.steps.map((st) => st.href), [0, 2.577, 3.629].map((t) => `../runs/${QA}/qa/02-req-save-note.flow/video.mp4#t=${t}`))
    assert.match(red.steps[2].text, /step 3 is text id="counter.value" "1"/)
    assert.equal(red.sheet, `../runs/${QA}/qa/02-req-save-note.flow/sheet.png`)
    assert.equal(red.video, `../runs/${QA}/qa/02-req-save-note.flow/video.mp4`)
    assert.equal(red.why, 'Why it failed')
    assert.equal(red.media, 0)
    assert.equal(red.errors, '0')
    assert.deepEqual(page.errors, [])
  },

  async 'a red flow row\'s "Why it failed" names its failing step — catches a red flow with no failing step'() {
    await page.load(withFlows)
    await page.evaluate(`(() => { document.querySelector('[role=tab][data-tab="validation"]').click(); document.querySelector('.qa-row[data-row="2"] .qa-why').click() })()`)
    const rows = Object.fromEntries((await page.evaluate(POPOVER)).rows)
    assert.equal(rows['failing step'], 'step 3 is text id="counter.value" "1"')
  },

  async 'a passing flow row with no contact sheet opens "Why unverified" naming the sheet and why, and shows no sheet link — catches a missing sheet read as verified'() {
    await page.load(withFlows)
    const pass = await page.evaluate(FLOW(1))
    assert.equal(pass.sheet, null)
    assert.match(pass.text, /no contact sheet/)
    assert.equal(pass.why, 'Why unverified')
    await page.evaluate(`document.querySelector('.qa-row[data-row="1"] .qa-why').click()`)
    const pop = await page.evaluate(POPOVER)
    assert.equal(pop.title, 'Why unverified')
    const rows = Object.fromEntries(pop.rows)
    assert.equal(rows["didn't run"], "the video's contact sheet")
    assert.equal(rows['contact sheet'], "the contact sheet couldn't be made from the video")
    assert.equal(rows.video, undefined)
  },

  async 'a flow\'s qa.check bar carries 1 tick per step, each linked to the video at its offset, a failed step marked — catches a flow check with no step ticks'() {
    await page.viewport(1280, 900)
    await page.load(withFlows)
    await page.evaluate(`document.querySelector('[role=tab][data-tab="timeline"]').click()`)
    const ticks = await page.evaluate(`[...document.querySelectorAll('#tl .tl-tick[data-span="qa:${QA}:2"]')].map((t) => ({ n: t.dataset.n, bad: t.classList.contains('bad'), href: t.getAttribute('href'), label: t.getAttribute('aria-label'), w: t.getBoundingClientRect().width }))`)
    assert.deepEqual(ticks.map((t) => [t.n, t.bad]), [['1', false], ['2', false], ['3', true]])
    assert.equal(ticks[2].href, `../runs/${QA}/qa/02-req-save-note.flow/video.mp4#t=3.629`)
    assert.match(ticks[2].label, /step 3 .*failed, 3\.6 s/)
    assert.ok(ticks.every((t) => t.w > 0))
    assert.equal(await page.evaluate(`document.querySelectorAll('img, video').length`), 0)
  },

  async 'kept XCUITest flows list under "Kept flows" by flow and test, their steps linked to the gate run\'s video, and one with no recording opens "Why unverified" — catches a kept flow dropped from the tab'() {
    await page.load(withFlows)
    const kept = await page.evaluate(`(() => { document.querySelector('[role=tab][data-tab="validation"]').click()
      const s = document.querySelector('.qa-kept')
      return { label: s?.getAttribute('aria-label'), groups: [...s.querySelectorAll('.qa-kept-group')].map((g) => [g.dataset.flow, [...g.querySelectorAll('.qa-kept-flow')].map((r) => r.dataset.test)]),
        hrefs: [...s.querySelectorAll('.qa-kept-flow[data-test="CounterFlowUITests/testFact()"] .qa-step a')].map((a) => a.getAttribute('href')),
        whys: [...s.querySelectorAll('.qa-why')].map((b) => b.closest('.qa-kept-flow').dataset.test) } })()`)
    assert.equal(kept.label, 'Kept flows')
    assert.deepEqual(kept.groups, [['counter', ['CounterFlowUITests/testFact()', 'CounterFlowUITests/testIncrement()']]])
    assert.deepEqual(kept.hrefs, [0, 2.577].map((t) => `../runs/${GATE}/qa/xcuitest/CounterFlowUITests-testFact/video.mp4#t=${t}`))
    assert.deepEqual(kept.whys, ['CounterFlowUITests/testIncrement()'])
    await page.evaluate(`document.querySelector('.qa-kept .qa-why').click()`)
    const rows = Object.fromEntries((await page.evaluate(POPOVER)).rows)
    assert.equal(rows.video, 'the UI test kept no screen recording in its result bundle')
    assert.equal(rows['gate run'], GATE)
  },

  async 'a task popover lists the rows that run after the task, and a row\'s Why button there opens its popover, anchored where the task popover was — catches a task popover with no validation rows'() {
    await page.load(withRows)
    await page.evaluate(`document.querySelector('#task-table .task-link[data-task="list"]').click()`)
    const task = await page.evaluate(`(() => { const p = document.getElementById('pop'); return { title: document.getElementById('pop-title').textContent,
      rows: [...p.querySelectorAll('.pop-validation .qa-row')].map((r) => r.dataset.row + ':' + r.dataset.result), whys: [...p.querySelectorAll('.pop-validation .qa-why')].map((b) => b.innerText) } })()`)
    assert.equal(task.title, 'list')
    assert.deepEqual(task.rows, ['2:red', '3:unverified'])
    assert.deepEqual(task.whys, ['Why it failed', 'Why unverified'])
    await page.evaluate(`document.querySelector('#pop .pop-validation .qa-row[data-row="2"] .qa-why').click()`)
    const pop = await page.evaluate(POPOVER)
    assert.equal(pop.title, 'Why it failed')
    assert.equal(Object.fromEntries(pop.rows)['exit status'], '1')
    await page.press('Escape')
    assert.equal(await page.evaluate(`document.activeElement?.dataset.task ?? null`), 'list')
    assert.equal(await page.evaluate(`document.body.dataset.errors`), '0')
  },

  async 'a row lists each qa run that checked it, newest first, with its stage, the task an after run named and the run an at-base check reused, and an earlier red run opens "Why it failed" — catches a page that shows only the last qa run'() {
    await page.load(withHistory)
    const rows = await page.evaluate(`(() => { document.querySelector('[role=tab][data-tab="validation"]').click()
      return [...document.querySelectorAll('.qa-group .qa-row')].map((r) => ({ row: r.dataset.row, result: r.dataset.result,
        attempts: [...r.querySelectorAll('.qa-attempt')].map((a) => [a.dataset.stage, a.dataset.result, a.dataset.run, a.innerText]) })) })()`)
    const saved = rows.find((r) => r.row === '1')
    assert.deepEqual(saved.attempts.map(([stage, result, run]) => [stage, result, run]), [['after', 'pass', QA], ['at-base', 'red', BASE]])
    assert.match(saved.attempts[0][3], /after store/)
    assert.match(saved.attempts[1][3], /reused from 20261003T141000Z-0000dddd/)
    await page.evaluate(`document.querySelector('.qa-row[data-row="1"] .qa-attempt[data-stage="at-base"] .qa-why').click()`)
    const pop = await page.evaluate(POPOVER)
    assert.equal(pop.title, 'Why it failed')
    const fields = Object.fromEntries(pop.rows)
    assert.equal(fields['qa run'], BASE)
    assert.equal(fields['exit status'], '1')
    assert.match(pop.text, /no such command: save/)
    assert.equal(await page.evaluate(`document.body.dataset.errors`), '0')
  },

  async 'a row only an at-base run checked reads "at base", counted apart in the strip and not as a red badge — catches expected reds before the first merge counted as failures'() {
    await page.load(withHistory)
    await page.evaluate(`document.querySelector('[role=tab][data-tab="validation"]').click()`)
    const tab = await page.evaluate(TAB)
    assert.deepEqual(tab.badges, {})
    assert.deepEqual(tab.strip, { pass: 1, red: 0, unverified: 0, waiting: 0, atBase: 1 })
    const base = await page.evaluate(`document.querySelector('.qa-row[data-row="2"]').innerText`)
    assert.match(base, /at base/)
    assert.deepEqual(page.errors, [])
  },

  async 'a row abandoned at the final run shows its last passing run\'s flow with its video and the label naming that run — catches a finished flow\'s video lost because its task missed the cutoff'() {
    await page.load(withLastPass)
    const shown = await page.evaluate(`(() => { document.querySelector('[role=tab][data-tab="validation"]').click()
      const r = document.querySelector('.qa-row[data-row="1"]')
      const p = r.querySelector(':scope > .qa-last-pass')
      return p ? { label: p.querySelector('.qa-last-pass-label')?.innerText ?? null, video: p.querySelector('.qa-video')?.getAttribute('href') ?? null,
        steps: p.querySelectorAll('.qa-step').length, errors: document.body.dataset.errors } : null })()`)
    assert.ok(shown, 'the row shows no last pass')
    assert.equal(shown.label, LAST_PASS)
    assert.ok(shown.video && shown.video.includes(QA) && shown.video.endsWith('video.mp4'), `video link ${shown.video}`)
    assert.equal(shown.steps, 3)
    assert.equal(shown.errors, '0')
    assert.deepEqual(page.errors, [])
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
