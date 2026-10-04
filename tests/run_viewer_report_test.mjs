// Writes a real `swiftgate report --html` of the captured build run in a scratch repository and
// loads it in headless Chrome: the page is the report's only file, every region draws a row for
// each item the embedded view holds, every tab draws, its badges match the view, and the console
// holds no error.
// Run: node tests/run_viewer_report_test.mjs   (SWIFTGATE_BIN=plugin/bin/swiftgate to use the shim)
// Regressions caught: key drift between the Swift encoder and the page, a report that needs a
// sibling file or the network to draw, and a red span or blocked task with no failure context.
import assert from 'node:assert/strict'
import { execFileSync, spawnSync } from 'node:child_process'
import { cpSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { gitPath } from './developer_tools.mjs'
import { findChrome, launch } from './headless_chrome.mjs'

const plugin = join(dirname(fileURLToPath(import.meta.url)), '..', 'plugin')
const fixtures = join(plugin, 'gate/Tests/Fixtures/RunView')
// Each captured build run: its fixture directory, build run id and plan slug.
const RUNS = {
  first: { dir: 'build-run-1', buildRun: '20261004T045528Z-58d28c78', plan: '2026-10-03-counter-reset-and-floor' },
  // The first run's plan state with the qa run sequence captured over that plan's validation table.
  qa: { dir: 'build-run-1', buildRun: '20261004T045528Z-58d28c78', plan: '2026-10-03-counter-reset-and-floor', qa: 'qa-checks' },
  // The same plan state with a captured final qa run over 2 flow rows and a state row, and a
  // captured T3 run's 2 kept flows, moved onto the run's RED merge gate so the run owns them.
  flows: { dir: 'build-run-1', buildRun: '20261004T045528Z-58d28c78', plan: '2026-10-03-counter-reset-and-floor', qa: 'qa-flows', keptOn: '20261004T050310Z-ed998508' },
  spans: { dir: 'build-run-2', buildRun: '20261004T095203Z-7053bb32', plan: '2026-10-04-counter-reset-and-floor' },
  blocked: { dir: 'brownfield-blocked', buildRun: '20261004T124141Z-c3747b7a', plan: 'spec', brownfield: true, clone: 'memos-3' },
  rejected: { dir: 'brownfield-rejected', buildRun: '20261004T141445Z-85d15f09', plan: 'spec', brownfield: true, clone: 'memos-4' },
}
// build-run-1's merge gate of counter-ui-reset-button, RED on a snapshot test before the fixer.
const RED_GATE = '20261004T050310Z-ed998508'
// What no published report may carry: the capture's machine paths, anonymised or not.
const MACHINE_PATHS = /\/var\/folders|\/Users\/|tmp\.scratch|file:\/\//

function swiftgateBinary() {
  if (process.env.SWIFTGATE_BIN) return process.env.SWIFTGATE_BIN
  const debug = join(plugin, 'gate/.build/debug/swiftgate')
  return existsSync(debug) ? debug : join(plugin, 'bin/swiftgate')
}

// A brownfield clone holding the captured run's shared store and plan state, with each task
// worktree's run store under its own git dir, as `git worktree add` lays them out.
function seededClone({ dir: fixture, buildRun, plan, clone }) {
  const captured = join(fixtures, fixture)
  const parent = mkdtempSync(join(tmpdir(), 'run-viewer-report-'))
  const dir = join(parent, clone)
  mkdirSync(dir)
  execFileSync(gitPath, ['init', '-q'], { cwd: dir })
  const harness = join(dir, '.git/swift-harness')
  const runDir = join(harness, 'plans', plan, 'build', buildRun)
  mkdirSync(runDir, { recursive: true })
  writeFileSync(join(harness, 'config.toml'), '')
  const copies = [
    ['events', join(harness, 'events')],
    // The warm-up's times and baseline files, where the capture kept them.
    ...['warmup', 'baseline'].filter((name) => existsSync(join(captured, name))).map((name) => [name, join(harness, name)]),
    ['ledger.json', join(harness, 'plans', plan, 'ledger.json')],
    ['plan.json', join(harness, 'plans', plan, 'plan.json')],
    ['clock.json', join(harness, 'plans', plan, 'clock.json')],
    ['run.json', join(runDir, 'run.json')],
    ['ledger-events.jsonl', join(runDir, 'events.jsonl')],
    ['returns', join(runDir, 'returns')],
  ]
  for (const [from, to] of copies) cpSync(join(captured, from), to, { recursive: true })
  for (const name of readdirSync(join(captured, 'worktrees'))) {
    const gitDir = join(dir, '.git/worktrees', name)
    mkdirSync(join(parent, name), { recursive: true })
    mkdirSync(join(gitDir, 'swift-harness'), { recursive: true })
    writeFileSync(join(parent, name, '.git'), `gitdir: ${gitDir}\n`)
    writeFileSync(join(gitDir, 'commondir'), '../..\n')
    cpSync(join(captured, 'worktrees', name, 'runs'), join(gitDir, 'swift-harness/runs'), { recursive: true })
  }
  return { dir, root: parent, report: join(harness, 'reports', `${buildRun}.html`) }
}

// A git repository holding the captured run's plan state and stores, as the run left them.
function seededRepository(run) {
  const { dir: fixture, buildRun, plan } = run
  const captured = join(fixtures, fixture)
  const dir = mkdtempSync(join(tmpdir(), 'run-viewer-report-'))
  execFileSync(gitPath, ['init', '-q'], { cwd: dir })
  writeFileSync(join(dir, '.swiftgate.toml'), '')
  const planDir = join(dir, '.git/swift-harness/plans', plan)
  const runDir = join(planDir, 'build', buildRun)
  mkdirSync(runDir, { recursive: true })
  mkdirSync(join(dir, '.harness'), { recursive: true })
  const copies = [
    ['ledger.json', join(planDir, 'ledger.json')],
    ['plan.json', join(planDir, 'plan.json')],
    ['plan.md', join(planDir, 'spec-page.md')],
    ['run.json', join(runDir, 'run.json')],
    ['ledger-events.jsonl', join(runDir, 'events.jsonl')],
    ['returns', join(runDir, 'returns')],
    ['events', join(dir, '.harness/events')],
  ]
  for (const [from, to] of copies) cpSync(join(captured, from), to, { recursive: true })
  // A gate run's report.json, where the capture kept it.
  if (existsSync(join(captured, 'runs'))) cpSync(join(captured, 'runs'), join(dir, '.harness/runs'), { recursive: true })
  // `qa run`'s stream and run folders, as it left them in the checkout.
  if (run.qa) {
    const lines = readFileSync(join(fixtures, run.qa, 'events/qa.jsonl'), 'utf8').split('\n').filter(Boolean).map((line) => {
      const event = JSON.parse(line)
      if (!run.keptOn || event.kind !== 'qa.flow' || event.payload.row != null) return line
      return JSON.stringify({ ...event, runID: run.keptOn })
    })
    writeFileSync(join(dir, '.harness/events/qa.jsonl'), lines.join('\n') + '\n')
    cpSync(join(fixtures, run.qa, 'runs'), join(dir, '.harness/runs'), { recursive: true })
  }
  return { dir, root: dir, report: join(dir, '.harness/reports', `${buildRun}.html`) }
}

const REGIONS = `(() => ({
  meta: document.querySelectorAll('#meta span').length,
  stats: document.querySelectorAll('#stats .stat').length,
  bars: document.querySelectorAll('#tl .bar').length,
  spec: document.querySelectorAll('#spec-table tbody tr').length,
  proof: document.querySelectorAll('#proof tbody tr').length,
  tokens: document.querySelectorAll('#token-rows .tok-row').length,
  roles: document.querySelectorAll('#roles .tok-row').length,
  gates: document.querySelectorAll('#gate-list .gate').length,
  errors: document.body.dataset.errors,
}))()`

if (!findChrome()) {
  console.log('skip run viewer report checks: no Chrome binary (set CHROME_PATH)')
  process.exit(0)
}

const repositories = []

// Writes the run's report in a seeded repository and loads it, returning the page's region
// counts, its embedded view, its text and its console errors.
// `act`, when given, runs against the open page before it closes and its answer is returned.
async function renderReport(run, act) {
  const repository = run.brownfield ? seededClone(run) : seededRepository(run)
  repositories.push(repository.root)
  const result = spawnSync(swiftgateBinary(), ['report', '--html', run.buildRun], {
    cwd: repository.dir,
    encoding: 'utf8',
    env: { ...process.env, LLVM_PROFILE_FILE: join(repository.root, 'profile-%p.profraw'), SWIFTGATE_HARNESS_ROOT: plugin },
    timeout: 30_000,
  })
  assert.equal(result.status, 0, result.stdout + result.stderr)
  const html = readFileSync(repository.report, 'utf8')
  assert.doesNotMatch(html, /<script src|<link|http/)

  const { page, close } = await launch()
  try {
    await page.viewport(1280, 900)
    await page.load(pathToFileURL(repository.report).href)
    const regions = await page.evaluate(REGIONS)
    const view = JSON.parse(await page.evaluate("document.getElementById('run-view').textContent"))
    const text = await page.evaluate('document.body.innerText')
    const barIDs = await page.evaluate("[...new Set([...document.querySelectorAll('#tl .bar')].map(bar => bar.dataset.id))]")
    const acted = act ? await act(page) : null
    const tabs = await walkTabs(page)
    return { regions, view, text, barIDs, html, acted, tabs, errors: [...page.errors] }
  } finally {
    await close()
  }
}

// Focuses the bar with `id` and reads the popover, then opens the drawer of `task` and reads it.
const POPOVER = `(() => { const p = document.getElementById('pop');
  return { hidden: p.hidden, text: p.innerText, active: document.activeElement.dataset.id ?? null } })()`
async function focusThenDrawer(page, id, task) {
  await page.evaluate(`document.querySelector('[role=tab][data-tab="timeline"]').click()`)
  await page.evaluate(`document.querySelector('#tl .bar[data-id="${id}"]').focus()`)
  const popover = await page.evaluate(POPOVER)
  await page.evaluate(`window.runViewer.openTaskDrawer(${JSON.stringify(task)})`)
  const drawer = await page.evaluate("document.getElementById('dr-body').innerText")
  return { popover, drawer }
}

const TABS = ['overview', 'timeline', 'board', 'graph', 'spec', 'gates', 'tokens']
// Clicks each tab in turn and reads what it shows: the panels on screen, their height and text,
// the errors so far, and every tab's badges by key.
async function walkTabs(page) {
  const shown = {}
  for (const id of TABS) {
    shown[id] = await page.evaluate(`(() => {
      const tab = document.querySelector('[role=tab][data-tab="${id}"]')
      if (!tab || tab.hidden) return null
      tab.click()
      const panels = [...document.querySelectorAll('[role=tabpanel]')].filter((p) => !p.hidden && p.offsetHeight > 0)
      return { panels: panels.map((p) => p.dataset.tab), height: panels[0]?.offsetHeight ?? 0, text: panels[0]?.innerText.trim().length ?? 0,
        selected: tab.getAttribute('aria-selected'), errors: document.body.dataset.errors }
    })()`)
  }
  const badges = await page.evaluate(`Object.fromEntries([...document.querySelectorAll('[role=tab]')].map((t) => [t.dataset.tab,
    Object.fromEntries([...t.querySelectorAll('.badge')].map((b) => [b.dataset.key, Number(b.dataset.n)]))]))`)
  return { shown, badges }
}

// The badge keys checked on each tab, and the counts they should carry, read straight from the
// embedded view.
const CHECKED = { overview: ['halted'], board: ['blocked', 'active'], spec: ['uncovered'], gates: ['red'], tokens: ['pending'], timeline: ['failed'] }
function expectedBadges(view) {
  const open = view.halts.filter((h) => h.answer == null && h.waitMs == null)
  const halted = new Set(open.map((h) => h.task))
  const n = (key, count) => (count ? { [key]: count } : {})
  return {
    overview: n('halted', open.length),
    board: { ...n('blocked', view.tasks.filter((t) => ['blocked', 'needs-replan', 'abandoned'].includes(t.status) || halted.has(t.id)).length),
      ...n('active', view.tasks.filter((t) => t.status === 'in-progress' && !halted.has(t.id)).length) },
    spec: n('uncovered', view.spec.filter((q) => q.tasks.length === 0).length),
    gates: n('red', view.gates.filter((g) => g.verdict === 'RED').length),
    tokens: n('pending', view.tasks.filter((t) => t.tokens == null).length),
    timeline: n('failed', view.spans.filter((x) => ['red', 'halted'].includes(x.outcome) && !x.baseline && !['tier', 'step'].includes(x.phase)).length),
  }
}

// Hovers the pointer over the bar with `id` on the timeline and reads each label and value of the
// popover it previews, with the bar's colour.
async function hoverBar(page, id) {
  await page.evaluate(`document.querySelector('[role=tab][data-tab="timeline"]').click()`)
  const box = await page.evaluate(`(() => { const b = document.querySelector('#tl .bar[data-id="${id}"]'); b.scrollIntoView({ block: 'center', inline: 'center' });
    const r = b.getBoundingClientRect(); return { x: r.left + Math.min(4, r.width / 2), y: r.top + r.height / 2 } })()`)
  await page.hover(box.x, box.y)
  const read = await page.evaluate(`(() => { const p = document.getElementById('pop');
    const rows = [...p.querySelectorAll('dt')].map((dt) => [dt.innerText, dt.nextElementSibling.innerText]);
    return { hidden: p.hidden, rows, colour: document.querySelector('#tl .bar[data-id="${id}"]').style.backgroundColor } })()`)
  await page.press('Escape')
  return read
}

// Clicks a task's board card and reads the task popover it opens.
async function cardPopover(page, task) {
  await page.evaluate(`document.querySelector('[role=tab][data-tab="board"]').click()`)
  await page.evaluate(`document.querySelector('.card[data-task="${task}"]').click()`)
  const read = await page.evaluate(`({ hidden: document.getElementById('pop').hidden, title: document.getElementById('pop-title').textContent, text: document.getElementById('pop').innerText, cardText: document.querySelector('.card[data-task="${task}"]').innerText })`)
  await page.press('Escape')
  return read
}

// Every tab draws its panel alone with no error, and its badges carry the view's counts.
function assertTabs({ tabs: { shown, badges }, view }) {
  for (const id of TABS) {
    assert.ok(shown[id], `the ${id} tab is missing`)
    assert.deepEqual(shown[id].panels, [id], `the ${id} tab shows ${JSON.stringify(shown[id].panels)}`)
    assert.ok(shown[id].height > 0 && shown[id].text > 0, `the ${id} tab is blank`)
    assert.equal(shown[id].selected, 'true')
    assert.equal(shown[id].errors, '0', `the ${id} tab throws`)
  }
  for (const [tab, counts] of Object.entries(expectedBadges(view))) {
    const shownCounts = Object.fromEntries(Object.entries(badges[tab]).filter(([key]) => CHECKED[tab].includes(key)))
    assert.deepEqual(shownCounts, counts, `the ${tab} tab's badges`)
  }
}

function assertRendered(rendered, run, keys) {
  const { regions, view, text, errors } = rendered
  assertTabs(rendered)
  for (const key of keys) {
    assert.ok(regions[key] > 0, `region ${key} is empty: ${JSON.stringify(regions)}`)
  }
  assert.deepEqual(
    { spec: regions.spec, proof: regions.proof, tokens: regions.tokens, roles: regions.roles, gates: regions.gates },
    { spec: view.spec.length, proof: view.proofs.length, tokens: view.tasks.length, roles: view.roles.length, gates: view.gates.length })
  assert.equal(regions.errors, '0')
  assert.deepEqual(errors, [])
  assert.match(text, new RegExp(run.buildRun))
  assert.doesNotMatch(text, /undefined|NaN|no run data embedded/)
}

const REGION_KEYS = ['meta', 'stats', 'bars', 'spec', 'tokens', 'roles', 'gates']

// The Validation tab after a click: its strip, each row's number and result, every bar of a
// qa.check span, the footer's damage lines, and any embedded image or video.
const VALIDATION = `(() => {
  document.querySelector('[role=tab][data-tab="validation"]').click()
  const mount = document.querySelector('[data-module="validation"]')
  return {
    shown: !mount.hidden && mount.offsetHeight > 0,
    strip: Object.fromEntries([...mount.querySelectorAll('.qa-count')].map((c) => [c.dataset.result, Number(c.querySelector('b').textContent)])),
    rows: [...new Set([...mount.querySelectorAll('.qa-row')].map((r) => r.dataset.row + ':' + r.dataset.result))],
    damage: [...document.querySelectorAll('#foot .damage-line')].map((d) => d.textContent),
    media: document.querySelectorAll('img, video').length,
    errors: document.body.dataset.errors,
  }
})()`
// Clicks row `n`'s Why button and reads the popover's title and text.
async function whyPopover(page, n) {
  await page.evaluate(`document.querySelector('.qa-row[data-row="${n}"] .qa-why').click()`)
  const read = await page.evaluate(`({ title: document.getElementById('pop-title').textContent, text: document.getElementById('pop').innerText })`)
  await page.press('Escape')
  return read
}

const tests = {
  async 'the report of the captured run is 1 file that draws a row for each item in every region and every tab, whose badges carry the view\'s counts, with 0 console errors — catches key drift between the encoder and the page, a blank tab or a drifting badge'() {
    // The first captured run predates proof recording, so its proof table is checked against the data.
    assertRendered(await renderReport(RUNS.first), RUNS.first, REGION_KEYS)
  },
  async 'the report of the run captured with spans draws its phase, stage and tool data with 0 console errors — catches a span, proof or tool summary the page fails to draw'() {
    const rendered = await renderReport(RUNS.spans)
    assertRendered(rendered, RUNS.spans, REGION_KEYS)
    const phases = new Set(rendered.view.spans.map(span => span.phase))
    for (const phase of ['worker', 'final', 'ship']) assert.ok(phases.has(phase), `no ${phase} span in the view`)
    assert.ok(rendered.view.spans.some(span => span.phase === 'worker' && span.tools), 'no worker span carries tools')
    // Every emitted span draws its own bar, so a span the page can't place fails here.
    const emitted = rendered.view.spans.filter(span => ['worker', 'final', 'ship'].includes(span.phase)).map(span => span.id)
    assert.deepEqual(emitted.filter(id => !rendered.barIDs.includes(id)), [])
  },
  async 'the report of a run with captured qa checks draws every validation row with its newest result and the strip\'s counts, a damage line for the check the guard rejects, both Why popovers, and no embedded image or video, with 0 console errors — catches a validation row the page drops or an embedded thumbnail'() {
    const rendered = await renderReport(RUNS.qa, async (page) => ({
      tab: await page.evaluate(VALIDATION),
      red: await whyPopover(page, 2),
      unverified: await whyPopover(page, 3),
    }))
    assertRendered(rendered, RUNS.qa, REGION_KEYS)
    const { view, acted: { tab, red, unverified } } = rendered
    assert.ok(view.validation, 'the view has no validation section')
    assert.equal(tab.shown, true, 'the Validation tab draws nothing')
    assert.deepEqual(tab.rows.slice().sort(), view.validation.rows.map((r) => r.row + ':' + r.result).sort())
    assert.deepEqual(tab.rows, ['1:pass', '4:waiting', '2:red', '3:unverified', '5:unverified'])
    assert.deepEqual(tab.strip, view.validation.counts)
    assert.deepEqual(rendered.tabs.badges.validation, { red: 1, unverified: 2, waiting: 1 })
    assert.ok(tab.damage.some((line) => /qa run 20261004T185049Z-a14503a3 row 1: check: absolute-path/.test(line)), JSON.stringify(tab.damage))
    assert.equal(tab.media, 0)
    assert.equal(tab.errors, '0')
    assert.equal(red.title, 'Why it failed')
    assert.match(red.text, /exit status\s+1/i)
    assert.match(red.text, /expected 0 after reset, got 1/)
    assert.match(red.text, /qa\/02-slice-1-reset-after-increments-shows-zero\.acceptance\.txt/)
    assert.equal(unverified.title, 'Why unverified')
    assert.match(unverified.text, /flow check reset\.flow\.json/)
    assert.match(unverified.text, /not run: the acceptance layer has a red row/)
    const qaBars = rendered.barIDs.filter((id) => id.startsWith('qa:'))
    assert.deepEqual(qaBars.sort(), ['qa:20261004T185048Z-f46593bf:1', 'qa:20261004T185048Z-f46593bf:2', 'qa:20261004T185049Z-a14503a3:1'])
    assert.doesNotMatch(rendered.html, MACHINE_PATHS)
  },
  async 'the report of a run with a captured final qa run and kept flows draws every flow step linked to its video offset, each contact sheet, the kept flows by flow and test, and 1 timeline tick per step, with no embedded image or video and 0 console errors — catches a flow step the page drops or an embedded thumbnail'() {
    const rendered = await renderReport(RUNS.flows, async (page) => ({
      tab: await page.evaluate(VALIDATION),
      flows: await page.evaluate(`[...document.querySelectorAll('.qa-group:not(.qa-kept) .qa-row')].filter((r) => r.querySelector('.qa-flow')).map((r) => ({ row: r.dataset.row,
        steps: [...r.querySelectorAll('.qa-step')].map((li) => li.dataset.ok + ' ' + li.querySelector('a').getAttribute('href')), sheet: r.querySelector('.qa-sheet')?.getAttribute('href') }))`),
      kept: await page.evaluate(`[...document.querySelectorAll('.qa-kept .qa-kept-group')].map((g) => [g.dataset.flow, [...g.querySelectorAll('.qa-kept-flow')].map((r) => r.dataset.test + ' ' + r.querySelectorAll('.qa-step a').length)])`),
      ticks: await page.evaluate(`(() => { document.querySelector('[role=tab][data-tab="timeline"]').click(); return [...document.querySelectorAll('#tl .tl-tick')].map((t) => t.dataset.span + ' ' + t.dataset.n) })()`),
    }))
    assertRendered(rendered, RUNS.flows, REGION_KEYS)
    const { view, acted: { tab, flows, kept, ticks } } = rendered
    const qaRun = '20261004T220955Z-1614d1ea'
    assert.deepEqual(tab.rows, ['3:red', '1:pass', '2:pass'])
    assert.deepEqual(tab.damage, [])
    assert.equal(tab.media, 0)
    assert.equal(tab.errors, '0')
    const flowRows = view.validation.rows.filter((r) => r.flow)
    flows.sort((a, b) => Number(a.row) - Number(b.row))
    assert.deepEqual(flows.map((f) => f.row), ['1', '3'])
    for (const [i, r] of flowRows.entries()) {
      assert.deepEqual(flows[i].steps, r.flow.steps.map((st) => `${st.ok} ../runs/${qaRun}/${r.flow.video}#t=${st.offsetMs / 1000}`))
      assert.equal(flows[i].sheet, `../runs/${qaRun}/${r.flow.sheet}`)
    }
    assert.deepEqual(flows[1].steps.map((st) => st.split(' ')[0]), ['true', 'true', 'false'])
    assert.deepEqual(kept, [['counter', [
      'CounterFlowUITests/testFixedFactScenarioShowsItsFactWithoutNetwork() 5',
      'CounterFlowUITests/testIncrementAndDecrementUpdateTheDisplayedCount() 8',
    ]]])
    assert.deepEqual(ticks.sort(), flowRows.flatMap((r) => r.flow.steps.map((st) => `qa:${qaRun}:${r.row} ${st.n}`)).sort())
    assert.doesNotMatch(rendered.html, MACHINE_PATHS)
  },
  async 'focusing the RED merge gate\'s bar shows its tier, rule and file:line in the popover, and the task drawer the whole message, its failing test and report — catches a red span with no failure context'() {
    const rendered = await renderReport(RUNS.first, (page) => focusThenDrawer(page, `gate:${RED_GATE}`, 'counter-ui-reset-button'))
    assertRendered(rendered, RUNS.first, REGION_KEYS)
    const { popover, drawer } = rendered.acted
    assert.equal(popover.hidden, false, 'focusing the red gate bar opens no popover')
    assert.equal(popover.active, `gate:${RED_GATE}`, 'the popover took focus from the bar')
    assert.match(popover.text, /why it failed/i)
    assert.match(popover.text, /T2 failed/)
    assert.match(popover.text, /t2\.test-failed/)
    assert.match(popover.text, /CounterViewSnapshotTests\.swift:21/)
    assert.match(popover.text, /33 passed, 1 failed, 0 skipped/)
    assert.match(popover.text, new RegExp(`report \\.harness/runs/${RED_GATE}/report\\.json`))
    assert.match(popover.text, new RegExp(`swiftgate events list --run ${RED_GATE}`))
    assert.match(drawer, /why it failed/i)
    assert.match(drawer, /Newly-taken snapshot does not match reference/, 'the drawer cuts the message the popover cuts')
    assert.doesNotMatch(popover.text, /Newly-taken snapshot/)
    assert.match(drawer, /CounterUISnapshotTests\.CounterViewSnapshotTests\/counterWithFact/)
    assert.doesNotMatch(rendered.html, MACHINE_PATHS)
  },
  async 'a brownfield run\'s blocked task reads why on its task span and drawer, and a worker\'s RED gate its rule at file:line — catches a blocked task whose spans all read ok'() {
    const task = 'share-view-limit-store'
    const rendered = await renderReport(RUNS.blocked, async (page) => ({
      card: await cardPopover(page, task),
      task: await focusThenDrawer(page, `task:${task}`, task),
      gate: await focusThenDrawer(page, 'gate:20261004T124744Z-9d7ec113', task),
    }))
    assertRendered(rendered, RUNS.blocked, ['meta', 'stats', 'bars', 'gates'])
    const { task: blocked, gate, card } = rendered.acted
    assert.equal(card.hidden, false, 'the board card opens no task popover')
    assert.equal(card.title, task)
    // A block and a RED worker gate: the heading is the drawer's, and both causes show.
    assert.match(card.text, /why it failed/i, 'the task popover carries no failure context')
    assert.match(card.text, /no return of it was stored/)
    assert.match(card.text, /neutral\.lint/)
    assert.match(card.text, /FAILURE REASON\s+No return came back from the worker\./i, 'the task popover has no failure reason')
    assert.match(blocked.drawer, /failure reason\s+No return came back from the worker\./i, 'the drawer has no failure reason')
    assert.match(blocked.popover.text, /FAILURE REASON\s+No return came back from the worker\./i, 'the task span has no failure reason')
    assert.doesNotMatch(card.text, /null|undefined/, 'a brownfield task with no model reads null')
    assert.doesNotMatch(card.cardText, /null/, 'the board card of a task with no model reads null')
    assert.equal(blocked.popover.hidden, false)
    assert.match(blocked.popover.text, /why it stopped/i)
    assert.match(blocked.popover.text, /stopped\s+at \d\d:\d\d UTC: no return of it was stored/)
    assert.match(blocked.popover.text, /halt raised: question/)
    assert.match(blocked.popover.text, /last gate run 20261004T124847Z-cc87cdd0 GREEN/)
    assert.match(gate.popover.text, /neutral\.lint/)
    assert.match(gate.popover.text, /store\/test\/memo_share_test\.go:212/)
    assert.match(gate.popover.text, /slice tier · worker's gate/)
    assert.match(gate.drawer, /20261004T124744Z-9d7ec113/)
    assert.doesNotMatch(rendered.html, MACHINE_PATHS)
  },
  async 'hovering a red warm-up step shows FAILURE REASON right after OUTCOME, with the count the baseline recorded, and its bar reads as an excused baseline — catches a red warm-up with no explanation'() {
    const memos = 'warmup:memos:test:45BCDA7C-6BA0-44B8-B894-13B851158D52'
    const web = 'warmup:web:test:AE9DDF06-4CE9-4DDA-BA76-C63837D85CEA'
    const rendered = await renderReport(RUNS.blocked, async (page) => ({ memos: await hoverBar(page, memos), web: await hoverBar(page, web) }))
    assertRendered(rendered, RUNS.blocked, ['meta', 'stats', 'bars', 'gates'])
    for (const [read, reason] of [
      [rendered.acted.memos, "Base commit's tests already fail; 1 recorded as baseline."],
      [rendered.acted.web, "Base commit's tests fail, no test names read; whole step recorded as baseline."],
    ]) {
      assert.equal(read.hidden, false, 'hovering the warm-up bar previews no popover')
      const labels = read.rows.map(([label]) => label)
      const at = labels.indexOf('FAILURE REASON')
      assert.ok(at > 0, `no FAILURE REASON row: ${JSON.stringify(labels)}`)
      assert.equal(labels[at - 1], 'OUTCOME')
      assert.equal(at, labels.length - 1, 'FAILURE REASON is not the last field before TOOLS')
      assert.equal(read.rows[at][1], reason)
      assert.equal(read.rows[at - 1][1], 'baseline')
      assert.ok(reason.split(/\s+/).length <= 15)
    }
    assert.match(rendered.acted.memos.colour, /bar-baseline/, 'an excused warm-up step reads red')
    assert.doesNotMatch(rendered.html, MACHINE_PATHS)
  },
  async 'a task whose return check-return rejected reads the rule and its message on its task span and drawer — catches a rejected-return task that reads only "no return stored"'() {
    const task = 'share-view-limit-web'
    const rendered = await renderReport(RUNS.rejected, (page) => focusThenDrawer(page, `task:${task}`, task))
    assertRendered(rendered, RUNS.rejected, ['meta', 'stats', 'bars', 'gates'])
    const { popover, drawer } = rendered.acted
    assert.equal(popover.hidden, false)
    for (const text of [popover.text, drawer]) {
      assert.match(text, /why it stopped/i)
      assert.match(text, /stopped\s+at \d\d:\d\d UTC: build check-return rejected its return/)
      assert.match(text, /build-return\.surface-commit-off-branch/)
      assert.match(text, /surface commit "7c3becaa" isn't on branch spec\/share-view-limit-web/)
      assert.match(text, /last gate run 20261004T141801Z-79b9bebf GREEN/)
    }
    assert.doesNotMatch(popover.text, /no return of it was stored/)
    assert.doesNotMatch(rendered.html, MACHINE_PATHS)
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
  for (const repository of repositories) rmSync(repository, { recursive: true, force: true })
}
if (failed) {
  console.log(`${failed} failed`)
  process.exit(1)
}
