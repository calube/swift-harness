// Writes a real `swiftgate report --html` of the captured build run in a scratch repository and
// loads it in headless Chrome: the page is the report's only file, every region draws a row for
// each item the embedded view holds, and the console holds no error.
// Run: node tests/run_viewer_report_test.mjs   (SWIFTGATE_BIN=plugin/bin/swiftgate to use the shim)
// Regressions caught: key drift between the Swift encoder and the page, and a report that needs a
// sibling file or the network to draw.
import assert from 'node:assert/strict'
import { execFileSync, spawnSync } from 'node:child_process'
import { cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
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
}

function swiftgateBinary() {
  if (process.env.SWIFTGATE_BIN) return process.env.SWIFTGATE_BIN
  const debug = join(plugin, 'gate/.build/debug/swiftgate')
  return existsSync(debug) ? debug : join(plugin, 'bin/swiftgate')
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
  return dir
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
async function renderReport(run) {
  const repository = seededRepository(run)
  repositories.push(repository)
  const result = spawnSync(swiftgateBinary(), ['report', '--html', run.buildRun], {
    cwd: repository,
    encoding: 'utf8',
    env: { ...process.env, LLVM_PROFILE_FILE: join(repository, 'profile-%p.profraw'), SWIFTGATE_HARNESS_ROOT: plugin },
    timeout: 30_000,
  })
  assert.equal(result.status, 0, result.stdout + result.stderr)
  const report = join(repository, '.harness/reports', `${run.buildRun}.html`)
  const html = readFileSync(report, 'utf8')
  assert.doesNotMatch(html, /<script src|<link|http/)

  const { page, close } = await launch()
  try {
    await page.viewport(1280, 900)
    await page.load(pathToFileURL(report).href)
    const regions = await page.evaluate(REGIONS)
    const view = JSON.parse(await page.evaluate("document.getElementById('run-view').textContent"))
    const text = await page.evaluate('document.body.innerText')
    const barIDs = await page.evaluate("[...new Set([...document.querySelectorAll('#tl .bar')].map(bar => bar.dataset.id))]")
    return { regions, view, text, barIDs, errors: [...page.errors] }
  } finally {
    await close()
  }
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
