// Writes a real `swiftgate report --html` of the captured build run in a scratch repository and
// loads it in headless Chrome: the page is the report's only file, every region draws a row for
// each item the embedded view holds, and the console holds no error.
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
function seededRepository({ dir: fixture, buildRun, plan }) {
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
  return { dir, root: dir, report: join(dir, '.harness/reports', `${buildRun}.html`) }
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
    return { regions, view, text, barIDs, html, acted, errors: [...page.errors] }
  } finally {
    await close()
  }
}

// Focuses the bar with `id` and reads the popover, then opens the drawer of `task` and reads it.
const POPOVER = `(() => { const p = document.getElementById('pop');
  return { hidden: p.hidden, text: p.innerText, active: document.activeElement.dataset.id ?? null } })()`
async function focusThenDrawer(page, id, task) {
  await page.evaluate(`document.querySelector('#tl .bar[data-id="${id}"]').focus()`)
  const popover = await page.evaluate(POPOVER)
  await page.evaluate(`window.runViewer.openTaskDrawer(${JSON.stringify(task)})`)
  const drawer = await page.evaluate("document.getElementById('dr-body').innerText")
  return { popover, drawer }
}

function assertRendered({ regions, view, text, errors }, run, keys) {
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

const tests = {
  async 'the report of the captured run is 1 file that draws a row for each item in every region with 0 console errors — catches key drift between the encoder and the page'() {
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
      task: await focusThenDrawer(page, `task:${task}`, task),
      gate: await focusThenDrawer(page, 'gate:20261004T124744Z-9d7ec113', task),
    }))
    assertRendered(rendered, RUNS.blocked, ['meta', 'stats', 'bars', 'gates'])
    const { task: blocked, gate } = rendered.acted
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
