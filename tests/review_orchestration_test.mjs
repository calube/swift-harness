// Orchestration cases for workflows/review.js from evals/components.md, against stand-in agents.
// Run: node tests/review_orchestration_test.mjs
// The stubs follow the workflow runtime: a dead agent returns null, and a pipeline stage that
// throws turns that item into null without failing its siblings. review_workflow_test.mjs stubs
// pipeline with Promise.all, where one throw fails the whole run, so it can't see these cases.
// Regressions caught: the SwiftUI reviewer running on a diff that touches no SwiftUI, or its
// focus missing from the return; a dead or thrown reviewer or verifier dropping out of the return
// instead of coming back NOT REVIEWED; a verifier's partial or reordered answer verifying the
// wrong finding; a return review-synth can't read, or one that lets an unreviewed focus reach
// `merge`.
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = join(dirname(fileURLToPath(import.meta.url)), '..')
const source = readFileSync(join(root, 'workflows/review.js'), 'utf8').replace(/^export const meta/m, 'const meta')
const AsyncFunction = Object.getPrototypeOf(async () => {}).constructor
const script = new AsyncFunction('args', 'agent', 'pipeline', 'log', source)

const PLUGIN = '/opt/plugins/swift-harness'
const BUNDLE = '/work/app/.harness/runs/r1/review-input'
const CORE = ['concurrency', 'architecture', 'test-quality', 'api-errors']
const delay = ms => new Promise(resolve => setTimeout(resolve, ms))

async function pipeline(items, ...stages) {
  return Promise.all(
    items.map(async (item, index) => {
      try {
        let value = item
        for (const stage of stages) value = await stage(value, item, index)
        return value
      } catch {
        return null
      }
    }),
  )
}

// `reviews[focus]` and `verify(focus, findings)` return a reply, null (a dead agent), or throw.
async function run({ focuses = CORE, reviews = {}, verify = (focus, findings) => verifiedAll(findings) } = {}) {
  const calls = []
  const logs = []
  const agent = async (prompt, opts) => {
    calls.push({ prompt, opts })
    const [stage, focus] = opts.label.split(':')
    await delay(CORE.indexOf(focus) * 3 + 2)
    if (stage === 'review') {
      const reply = reviews[focus]
      return typeof reply === 'function' ? reply() : reply ?? { findings: [] }
    }
    const findings = JSON.parse(prompt.slice(prompt.indexOf('[')))
    return verify(focus, findings)
  }
  const result = await script({ bundle: BUNDLE, focuses, pluginRoot: PLUGIN }, agent, pipeline, m => logs.push(m))
  return { result, calls, logs }
}

const verifiedAll = findings => ({ findings: findings.map(f => ({ ...f, verified: true, verification_note: 'traced' })) })
const entry = (result, focus) => result.reviews.filter(r => r.focus === focus)
const labels = calls => calls.map(c => c.opts.label).sort()

const finding = (line, extra = {}) => ({
  kind: 'defect',
  severity: 'major',
  category: 'data-race',
  file: 'Packages/CounterFeature/Sources/CounterCore/CounterFeature.swift',
  line,
  title: `race at ${line}`,
  failure_scenario: 'two taps interleave and the count skips a value',
  evidence: `CounterFeature.swift:${line}`,
  fix: 'serialize through the reducer',
  ...extra,
})

const tests = {
  async 'no swiftui focus runs no SwiftUI reviewer and returns swiftui as not-applicable — catches the reviewer running on a diff with no SwiftUI'() {
    const { result, calls } = await run()
    assert.ok(!labels(calls).includes('review:swiftui'))
    const [swiftui] = entry(result, 'swiftui')
    assert.equal(swiftui.status, 'not-applicable')
    assert.deepEqual(result.reviews.map(r => r.focus).sort(), [...CORE, 'swiftui'].sort(), 'one entry per focus')
  },

  async 'a swiftui focus runs the SwiftUI reviewer, scoped to the manifest units, with one swiftui entry — catches a duplicate or not-applicable entry beside a real review'() {
    const { result, calls } = await run({ focuses: [...CORE, 'swiftui'] })
    const call = calls.find(c => c.opts.label === 'review:swiftui')
    assert.ok(call, 'review:swiftui ran')
    assert.equal(call.opts.agentType, 'swift-harness:swiftui')
    assert.match(call.prompt, /swiftUIUnits/)
    const swiftui = entry(result, 'swiftui')
    assert.equal(swiftui.length, 1)
    assert.equal(swiftui[0].status, 'reviewed')
  },

  async 'a reviewer that dies or throws comes back NOT REVIEWED and its siblings keep their findings — catches one death dropping a focus or failing the panel'() {
    const { result, logs } = await run({
      reviews: {
        concurrency: () => null,
        'api-errors': () => { throw new Error('terminal API error') },
        architecture: { findings: [finding(12)] },
      },
    })
    for (const focus of ['concurrency', 'api-errors']) {
      const [e] = entry(result, focus)
      assert.equal(e.status, 'not-reviewed', focus)
      assert.ok(e.reason.length > 0, focus)
      assert.deepEqual(e.findings, [])
    }
    const [architecture] = entry(result, 'architecture')
    assert.equal(architecture.status, 'reviewed')
    assert.equal(architecture.findings.length, 1)
    assert.equal(architecture.findings[0].verified, true)
    assert.ok(logs.some(l => /NOT REVIEWED: .*api-errors.*the verdict cannot be merge/.test(l) && /concurrency/.test(l)), logs.join('\n'))
  },

  async 'a dead or throwing verifier leaves its focus NOT REVIEWED with no unverified findings — catches unverified findings reaching the verdict'() {
    for (const verifier of [() => null, () => { throw new Error('verifier died') }]) {
      const { result } = await run({
        reviews: { concurrency: { findings: [finding(12)] } },
        verify: focus => (focus === 'concurrency' ? verifier() : { findings: [] }),
      })
      const [concurrency] = entry(result, 'concurrency')
      assert.equal(concurrency.status, 'not-reviewed')
      assert.deepEqual(concurrency.findings, [])
    }
  },

  async 'a verifier that drops or reorders findings verifies none of the mismatched ones — catches a partial answer verifying the wrong finding'() {
    const [a, b] = [finding(12), finding(30, { category: 'lost-update' })]
    const { result } = await run({
      reviews: { concurrency: { findings: [a, b] } },
      verify: () => ({ findings: [{ ...b, verified: true, verification_note: 'traced b' }] }),
    })
    const [concurrency] = entry(result, 'concurrency')
    assert.equal(concurrency.findings.length, 2, 'both reviewer findings are kept')
    assert.deepEqual(concurrency.findings.map(f => [f.line, f.verified]), [[12, false], [30, false]])
  },

  async 'the return is what review-synth reads, and an unreviewed focus keeps the verdict off merge — catches the workflow and the gate drifting'() {
    const synth = reviews => {
      const dir = mkdtempSync(join(tmpdir(), 'review-orchestration-'))
      try {
        const files = reviews.map(r => {
          const path = join(dir, `${r.focus}.json`)
          writeFileSync(path, JSON.stringify(r))
          return path
        })
        const out = execFileSync(join(root, 'bin/swiftgate'), ['review-synth', '--run-directory', dir, '--json', ...files], {
          encoding: 'utf8',
          cwd: dir,
          env: { ...process.env, LLVM_PROFILE_FILE: join(dir, 'review-synth-%p.profraw') },
        })
        return JSON.parse(out)
      } finally {
        rmSync(dir, { recursive: true, force: true })
      }
    }
    const clean = await run()
    assert.equal(synth(clean.result.reviews).verdict, 'merge', 'the all-clean control merges')

    const dead = await run({ reviews: { 'test-quality': () => null } })
    const report = synth(dead.result.reviews)
    assert.notEqual(report.verdict, 'merge')
    assert.deepEqual(report.notReviewed.map(n => n.focus), ['test-quality'])

    const blocker = await run({ reviews: { architecture: { findings: [finding(12, { severity: 'blocker' })] } } })
    assert.equal(synth(blocker.result.reviews).verdict, 'refactor-needed')
  },
}

let failed = 0
for (const [name, test] of Object.entries(tests)) {
  try {
    await test()
    console.log(`ok   ${name}`)
  } catch (error) {
    failed++
    console.log(`FAIL ${name}\n     ${error.message.split('\n').join('\n     ')}`)
  }
}
if (failed) {
  console.log(`${failed} failed`)
  process.exit(1)
}
