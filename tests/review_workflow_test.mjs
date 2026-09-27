// Runs workflows/review.js against stubbed agents. Run: node tests/review_workflow_test.mjs
// Regressions caught: reviewers never told where the plugin's standards live; the verifier's
// reasoning lost before review.json; a verifier downgrading a cited standards violation with no
// evidence, which is how a structural finding used to end up as `merge`.
import assert from 'node:assert/strict'
import { existsSync, readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

// The plugin directory: every path this test reads is relative to it.
const root = join(dirname(fileURLToPath(import.meta.url)), '..', 'plugin')
const source = readFileSync(join(root, 'workflows/review.js'), 'utf8').replace(
  /^export const meta/m,
  'const meta',
)
const AsyncFunction = Object.getPrototypeOf(async () => {}).constructor
const script = new AsyncFunction('args', 'agent', 'pipeline', 'log', 'budget', source)

const PLUGIN = '/opt/plugins/swift-harness'
const BUNDLE = '/work/app/.harness/runs/r1/review-input'

async function run({ args, reviews = {}, verify = () => null, budget }) {
  const calls = []
  const agent = async (prompt, opts) => {
    calls.push({ prompt, opts })
    const [stage, focus] = opts.label.split(':')
    if (stage === 'review') return reviews[focus] ?? { findings: [] }
    return verify(focus, prompt)
  }
  const pipeline = async (items, ...stages) =>
    Promise.all(
      items.map(async (item, index) => {
        let value = item
        for (const stage of stages) value = await stage(value, item, index)
        return value
      }),
    )
  const result = await script(args, agent, pipeline, () => {}, budget)
  return { result, calls }
}

const contract = readFileSync(join(root, 'docs/review-contract.md'), 'utf8')
const SEVERITY_RULES = ['defect-users-hit', 'defect-narrow-trigger', 'structural-fix', 'do-violation', 'no-harm-yet', 'taste']

const findings = (result, focus) => result.reviews.find(r => r.focus === focus).findings

const baseArgs = { bundle: BUNDLE, focuses: ['architecture', 'concurrency'], pluginRoot: PLUGIN }

const violation = {
  kind: 'standards-violation',
  rule: 'D7',
  severity: 'blocker',
  category: 'logic-in-live-client',
  file: 'Sources/FactClientLive/Live.swift',
  line: 12,
  title: 'length rule in a Live client',
  failure_scenario: 'the next change to the limit edits an untested IO module',
  evidence: 'Live.swift:12 `.prefix(140)`',
  fix: 'move the limit to the feature reducer',
}
const defect = { ...violation, kind: 'defect', rule: undefined, line: 30, category: 'data-race' }

const tests = {
  async 'a missing or relative pluginRoot is rejected — catches agents told to read standards that are not there'() {
    await assert.rejects(run({ args: { ...baseArgs, pluginRoot: undefined } }), /pluginRoot/)
    await assert.rejects(run({ args: { ...baseArgs, pluginRoot: 'plugins/sh' } }), /pluginRoot/)
  },

  async 'every reviewer and verifier prompt names the absolute standards and playbook — catches agents citing rules they could not read'() {
    const { calls } = await run({
      args: baseArgs,
      reviews: { architecture: { findings: [violation] } },
      verify: () => ({ findings: [{ ...violation, verified: true, verification_note: 'ok' }] }),
    })
    assert.equal(calls.length, 3)
    for (const { prompt, opts } of calls) {
      assert.ok(prompt.includes(`${PLUGIN}/docs/standards.md`), opts.label)
      assert.ok(prompt.includes(`${PLUGIN}/docs/testing-playbook.md`), opts.label)
    }
  },

  async 'every prompt names a review contract that ships inside the plugin — catches a consumer runtime read of a contributor doc'() {
    const { calls } = await run({
      args: { ...baseArgs, pluginRoot: root },
      reviews: { architecture: { findings: [violation] } },
      verify: () => ({ findings: [{ ...violation, verified: true, verification_note: 'ok' }] }),
    })
    assert.equal(calls.length, 3)
    for (const { prompt, opts } of calls) {
      const contract = /Review contract for finding kinds and severity: (\S+?)\.(\s|$)/.exec(prompt)?.[1]
      assert.ok(contract, `${opts.label}: no review contract path in the prompt`)
      assert.ok(contract.startsWith(`${root}/docs/`), `${opts.label}: ${contract} is outside the plugin's docs/`)
      assert.doesNotMatch(contract, /\/docs\/(adrs|designs|plans|handoffs)\//, opts.label)
      assert.ok(existsSync(contract), `${opts.label}: ${contract} does not exist in the plugin`)
    }
  },

  async 'a reviewer with no findings gets no verifier — catches the agent count the skill reports drifting from the workflow'() {
    const { calls, result } = await run({ args: baseArgs })
    assert.deepEqual(calls.map(c => c.opts.label).sort(), ['review:architecture', 'review:concurrency'])
    assert.equal(result.reviews.find(r => r.focus === 'architecture').status, 'reviewed')
  },

  async 'the verification note, kind and rule reach the focus file — catches the verifier reasoning and the cited rule being dropped'() {
    const { result } = await run({
      args: baseArgs,
      reviews: { architecture: { findings: [violation] } },
      verify: () => ({
        findings: [
          { ...violation, kind: 'defect', rule: 'A5', verified: true, verification_note: 'D7 Tell matches Live.swift:12' },
        ],
      }),
    })
    const [finding] = findings(result, 'architecture')
    assert.equal(finding.verification_note, 'D7 Tell matches Live.swift:12')
    assert.equal(finding.kind, 'standards-violation')
    assert.equal(finding.rule, 'D7')
    assert.equal(finding.verified, true)
  },

  async 'a standards violation keeps its severity unless the verifier gives a downgrade reason — catches a structural blocker quietly becoming a merge'() {
    const verifyWith = extra => () => ({
      findings: [{ ...violation, severity: 'minor', verified: true, verification_note: 'n', ...extra }],
    })
    const unexplained = await run({ args: baseArgs, reviews: { architecture: { findings: [violation] } }, verify: verifyWith({}) })
    assert.equal(findings(unexplained.result, 'architecture')[0].severity, 'blocker')

    const explained = await run({
      args: baseArgs,
      reviews: { architecture: { findings: [violation] } },
      verify: verifyWith({ downgrade_reason: '.swiftgate.toml grants FactClientLive a reasoned exception' }),
    })
    const [finding] = findings(explained.result, 'architecture')
    assert.equal(finding.severity, 'minor')
    assert.match(finding.verification_note, /downgraded: .swiftgate.toml grants/)
  },

  async 'a defect may be downgraded without a reason and never raised — catches the downgrade guard leaking onto reproduced defects'() {
    const lowered = await run({
      args: baseArgs,
      reviews: { concurrency: { findings: [{ ...defect, severity: 'major' }] } },
      verify: () => ({ findings: [{ ...defect, severity: 'minor', verified: true, verification_note: 'n' }] }),
    })
    assert.equal(findings(lowered.result, 'concurrency')[0].severity, 'minor')
    const raised = await run({
      args: baseArgs,
      reviews: { concurrency: { findings: [{ ...defect, severity: 'minor' }] } },
      verify: () => ({ findings: [{ ...defect, severity: 'blocker', verified: true, verification_note: 'n' }] }),
    })
    assert.equal(findings(raised.result, 'concurrency')[0].severity, 'minor')
  },

  async 'reviewer and verifier prompts point at the numbered diff and the new-file line rule — catches findings citing diff.patch lines'() {
    const { calls } = await run({
      args: baseArgs,
      reviews: { concurrency: { findings: [defect] } },
      verify: () => ({ findings: [{ ...defect, verified: true, verification_note: 'n' }] }),
    })
    assert.equal(calls.length, 3)
    for (const { prompt, opts } of calls) {
      assert.ok(prompt.includes(`${BUNDLE}/diff-numbered.txt`), `${opts.label}: no numbered diff`)
      assert.match(prompt, /`line` is the line in the new file, never a line of diff\.patch/, opts.label)
    }
  },

  async 'a finding the verifier re-lines keeps its verification at the verifier line — catches a patch-line citation dropping a real finding'() {
    const cited = { ...defect, file: 'Tests/CounterFeatureTests.swift', line: 36, title: 'reset test never covers an in-flight fact' }
    const { result } = await run({
      args: baseArgs,
      reviews: { 'concurrency': { findings: [cited] } },
      verify: () => ({ findings: [{ ...cited, line: 73, verified: true, verification_note: 'traced at 73' }] }),
    })
    const [finding] = findings(result, 'concurrency')
    assert.equal(finding.verified, true)
    assert.equal(finding.line, 73)
    assert.equal(finding.unmatched, undefined)
    assert.match(finding.verification_note, /line 36\b.*line 73/)
  },

  async 'a finding the verifier returns nothing for is kept and marked unmatched — catches a silent drop at synthesis'() {
    const { result } = await run({
      args: baseArgs,
      reviews: { concurrency: { findings: [defect] } },
      verify: () => ({ findings: [] }),
    })
    const [finding] = findings(result, 'concurrency')
    assert.equal(finding.verified, false)
    assert.equal(finding.unmatched, true)
    assert.equal(finding.severity, defect.severity)
    assert.match(finding.verification_note, /no verifier entry matched/)
  },

  async 'a finding with no kind is a defect — catches older reviewer output bypassing the defect path'() {
    const { kind, ...legacy } = defect
    const { result } = await run({
      args: baseArgs,
      reviews: { concurrency: { findings: [legacy] } },
      verify: () => ({ findings: [{ ...legacy, verified: true, verification_note: 'n' }] }),
    })
    assert.equal(findings(result, 'concurrency')[0].kind, 'defect')
  },

  async 'the verifier schema requires one of the contract severity rules and the rule reaches the focus file — catches a severity judgement no test can check'() {
    const { calls, result } = await run({
      args: baseArgs,
      reviews: { concurrency: { findings: [{ ...defect, severity: 'major' }] } },
      verify: () => ({
        findings: [{ ...defect, severity: 'major', severity_rule: 'defect-users-hit', verified: true, verification_note: 'n' }],
      }),
    })
    const verifier = calls.find(c => c.opts.label === 'verify:concurrency')
    const item = verifier.opts.schema.properties.findings.items
    assert.ok(item.required.includes('severity_rule'), 'severity_rule is not required')
    assert.deepEqual(item.properties.severity_rule.enum, SEVERITY_RULES)
    for (const rule of SEVERITY_RULES) assert.ok(contract.includes(`\`${rule}\``), `review-contract.md never defines ${rule}`)
    assert.match(verifier.prompt, /severity_rule/)
    assert.equal(findings(result, 'concurrency')[0].severity_rule, 'defect-users-hit')
  },

  async 'a severity rule the contract gives the other kind is dropped with a note — catches review-synth refusing the whole review over one verifier slip'() {
    const { result } = await run({
      args: baseArgs,
      reviews: { architecture: { findings: [violation] } },
      verify: () => ({
        findings: [{ ...violation, severity_rule: 'defect-users-hit', verified: true, verification_note: 'n' }],
      }),
    })
    const [finding] = findings(result, 'architecture')
    assert.equal(finding.severity_rule, undefined)
    assert.match(finding.verification_note, /severity rule defect-users-hit does not apply to a standards-violation/)
  },

  async 'the return reports the output tokens the budget counted across the run and every agent call — catches review cost left unrecorded or invented'() {
    let spent = 1000
    const budget = { total: null, spent: () => spent, remaining: () => Infinity }
    const { result } = await run({
      args: baseArgs,
      budget,
      reviews: { concurrency: { findings: [defect] } },
      verify: () => {
        spent = 6000
        return null
      },
    })
    assert.equal(result.telemetry.outputTokens, 5000)
    assert.deepEqual(result.telemetry.agents, [
      { label: 'review:concurrency', returned: true },
      { label: 'verify:concurrency', returned: false },
      { label: 'review:architecture', returned: true },
    ])
    assert.ok(result.telemetry.unavailable.some(u => /per-agent tokens/.test(u)))
  },

  async 'with no budget in the runtime the token count is null and says why — catches a zero standing in for an unknown cost'() {
    const { result } = await run({ args: baseArgs })
    assert.equal(result.telemetry.outputTokens, null)
    assert.ok(result.telemetry.unavailable.some(u => /^output tokens: /.test(u)))
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
