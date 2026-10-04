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
const captured = join(plugin, 'gate/Tests/Fixtures/RunView/build-run-1')
const buildRun = '20261004T045528Z-58d28c78'
const plan = '2026-10-03-counter-reset-and-floor'

function swiftgateBinary() {
  if (process.env.SWIFTGATE_BIN) return process.env.SWIFTGATE_BIN
  const debug = join(plugin, 'gate/.build/debug/swiftgate')
  return existsSync(debug) ? debug : join(plugin, 'bin/swiftgate')
}

// A git repository holding the captured run's plan state and stores, as the run left them.
function seededRepository() {
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

const repository = seededRepository()
const tests = {
  async 'the report of the captured run is 1 file that draws a row for each item in every region with 0 console errors — catches key drift between the encoder and the page'() {
    const result = spawnSync(swiftgateBinary(), ['report', '--html', buildRun], {
      cwd: repository,
      encoding: 'utf8',
      env: { ...process.env, LLVM_PROFILE_FILE: join(repository, 'profile-%p.profraw'), SWIFTGATE_HARNESS_ROOT: plugin },
      timeout: 30_000,
    })
    assert.equal(result.status, 0, result.stdout + result.stderr)
    const report = join(repository, '.harness/reports', `${buildRun}.html`)
    const html = readFileSync(report, 'utf8')
    assert.doesNotMatch(html, /<script src|<link|http/)

    const { page, close } = await launch()
    try {
      await page.viewport(1280, 900)
      await page.load(pathToFileURL(report).href)
      const regions = await page.evaluate(REGIONS)
      for (const key of ['meta', 'stats', 'bars', 'spec', 'tokens', 'roles', 'gates']) {
        assert.ok(regions[key] > 0, `region ${key} is empty: ${JSON.stringify(regions)}`)
      }
      // The captured run predates proof recording, so its proof table is checked against the data.
      const view = JSON.parse(await page.evaluate("document.getElementById('run-view').textContent"))
      assert.deepEqual(
        { spec: regions.spec, proof: regions.proof, tokens: regions.tokens, roles: regions.roles, gates: regions.gates },
        { spec: view.spec.length, proof: view.proofs.length, tokens: view.tasks.length, roles: view.roles.length, gates: view.gates.length })
      assert.equal(regions.errors, '0')
      assert.deepEqual(page.errors, [])
      const text = await page.evaluate('document.body.innerText')
      assert.match(text, new RegExp(buildRun))
      assert.doesNotMatch(text, /undefined|NaN|no run data embedded/)
    } finally {
      await close()
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
  rmSync(repository, { recursive: true, force: true })
}
if (failed) {
  console.log(`${failed} failed`)
  process.exit(1)
}
