// Runs workflows/design-research.js against stubbed lane agents with real async delays.
// Run: node tests/design_research_workflow_test.mjs
// Regressions caught: more than three lanes researching at once; one dead or malformed lane taking
// its siblings down; an answer re-running every lane instead of only the lane that asked it; a lane
// prompt missing its pin or the design doc; one pinless claim throwing away its whole lane.
import assert from 'node:assert/strict'
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

// The plugin directory: every path this test reads is relative to it.
const root = join(dirname(fileURLToPath(import.meta.url)), '..', 'plugin')
const rawSource = readFileSync(join(root, 'workflows/design-research.js'), 'utf8')
const source = rawSource.replace(/^export const meta/m, 'const meta')
const AsyncFunction = Object.getPrototypeOf(async () => {}).constructor
const script = new AsyncFunction('args', 'agent', 'log', 'phase', source)

const LANES = ['codebase', 'apple-docs', 'packages', 'prior-decisions']
const COMMIT = '6ee32101d306b2fc36641d5001b89f0d1627618c'
const DESIGN = 'docs/checkout/designs/offline-order-queue.md'
const PINS = {
  codebase: COMMIT,
  'apple-docs': 'iphonesimulator26.2',
  packages: 'swift-composable-architecture@1.26.2',
  'prior-decisions': 'swift-dependencies@1.9.0',
}
const lanes = (names = LANES) =>
  names.map(name => ({ name, packPath: `.harness/context-pack/research-lane-${name}.md`, pin: PINS[name] }))
const baseArgs = (extra = {}) => ({
  tier: 'standard',
  mode: 'research',
  design: DESIGN,
  commit: COMMIT,
  lanes: lanes(),
  answers: [],
  ...extra,
})

const delay = ms => new Promise(resolve => setTimeout(resolve, ms))

function laneResult(lane, { needsDecision = [], claimSuffix = 'first' } = {}) {
  const id = `ev-${lane}-finding-${claimSuffix}`
  return {
    lane,
    claims: [
      {
        id,
        lane,
        text: `${lane} relies on Effect.run`,
        citation: { kind: 'probe', loc: `probes/${id}.swift`, pin: 'swift-composable-architecture@1.26.2' },
        status: 'new',
      },
    ],
    probes: [{ claimId: id, swift: 'import ComposableArchitecture\nlet _ = Effect<Int>.run { _ in }' }],
    needsDecision,
  }
}

const ask = (question, recommendation = 'Keep one client') => ({
  question,
  options: [recommendation, 'Split per feature'],
  recommendation,
  evidence: ['ev-codebase-finding-first'],
})

// `behave[lane]` receives (prompt, callNumberForThatLane) and returns a result, null, or throws.
async function run(args, behave = {}) {
  const calls = []
  let inFlight = 0
  let maxInFlight = 0
  const perLane = {}
  const agent = async (prompt, opts) => {
    const lane = opts.agentType.replace('swift-harness:design-lane-', '')
    const n = (perLane[lane] = (perLane[lane] ?? 0) + 1)
    calls.push({ lane, prompt, opts })
    inFlight++
    maxInFlight = Math.max(maxInFlight, inFlight)
    try {
      // Varied lengths so completion order differs from start order.
      await delay([35, 5, 25, 15][LANES.indexOf(lane)] + n * 3)
      const fn = behave[lane]
      return fn ? await fn(prompt, n) : laneResult(lane)
    } finally {
      inFlight--
    }
  }
  const logs = []
  const result = await script(args, agent, message => logs.push(message), () => {})
  return { result, calls, maxInFlight, logs }
}

const laneOf = (result, name) => result.lanes.find(l => l.lane === name)

// The script with the runtime's `budget` in scope. `spent` counts the whole turn's output tokens,
// so each stub agent call adds its own output to it.
const scriptWithBudget = new AsyncFunction('args', 'agent', 'log', 'phase', 'budget', source)
async function runWithBudget(args, { startSpent = 7000, perCall = 1000, behave = {} } = {}) {
  let spent = startSpent
  const budget = { total: null, spent: () => spent, remaining: () => Infinity }
  const agent = async (prompt, opts) => {
    const lane = opts.agentType.replace('swift-harness:design-lane-', '')
    await delay([35, 5, 25, 15][LANES.indexOf(lane)])
    spent += perCall
    const fn = behave[lane]
    return fn ? await fn(prompt) : laneResult(lane)
  }
  return scriptWithBudget(args, agent, () => {}, () => {}, budget)
}

const tests = {
  async 'invalid args fail fast with a named error before any lane runs — catches a silent default researching the wrong thing'() {
    const cases = [
      [baseArgs({ mode: 'deep-dive' }), 'UnknownModeError'],
      [baseArgs({ lanes: [...lanes(), { name: 'codebase', packPath: 'x.md', pin: COMMIT }] }), 'TooManyLanesError'],
      [baseArgs({ mode: 'reresearch', lanes: lanes(['packages']) }), 'MissingClaimIdsError'],
      [baseArgs({ mode: 'reresearch', lanes: lanes(['packages']), claimIds: [] }), 'MissingClaimIdsError'],
      [baseArgs({ lanes: [{ name: 'codebase', pin: COMMIT }] }), 'MissingPackPathError'],
      [baseArgs({ lanes: [{ name: 'codebase', packPath: '', pin: COMMIT }] }), 'MissingPackPathError'],
      [baseArgs({ lanes: [{ name: 'web', packPath: 'x.md', pin: COMMIT }] }), 'UnknownLaneError'],
      [baseArgs({ lanes: [...lanes(['codebase']), ...lanes(['codebase'])] }), 'DuplicateLaneError'],
      [baseArgs({ lanes: [] }), 'InvalidArgsError'],
      [baseArgs({ tier: 'medium' }), 'UnknownTierError'],
      [baseArgs({ claimIds: ['ev-a-b-c'] }), 'InvalidArgsError'],
      [baseArgs({ mode: 'reresearch', lanes: lanes(['packages', 'codebase']), claimIds: ['ev-a-b-c'] }), 'InvalidArgsError'],
      [baseArgs({ answers: undefined }), 'InvalidArgsError'],
      [baseArgs({ answers: [{ question: 'q' }] }), 'InvalidArgsError'],
      [baseArgs({ budget: 3 }), 'InvalidArgsError'],
      [baseArgs({ design: undefined }), 'MissingDesignError'],
      [baseArgs({ design: 'docs/checkout/designs/offline-order-queue' }), 'MissingDesignError'],
      [baseArgs({ design: '/abs/docs/x.md' }), 'MissingDesignError'],
      [baseArgs({ commit: undefined }), 'InvalidCommitError'],
      [baseArgs({ commit: 'HEAD' }), 'InvalidCommitError'],
      [baseArgs({ commit: '6ee321' }), 'InvalidCommitError'],
      [baseArgs({ lanes: [{ name: 'codebase', packPath: 'x.md' }] }), 'MissingPinError'],
      [baseArgs({ lanes: [{ name: 'codebase', packPath: 'x.md', pin: ' ' }] }), 'MissingPinError'],
      [undefined, 'InvalidArgsError'],
    ]
    for (const [args, name] of cases) {
      let ran = 0
      await assert.rejects(
        script(args, async () => { ran++ }, () => {}, () => {}),
        error => error.name === name,
        `${name} for ${JSON.stringify(args)}`,
      )
      assert.equal(ran, 0)
    }
  },

  async 'never more than three lanes in flight, and the fourth still runs — catches a missing or broken concurrency cap'() {
    const { result, maxInFlight, calls } = await run(baseArgs())
    assert.equal(maxInFlight, 3)
    assert.equal(calls.length, 4)
    assert.deepEqual(result.lanes.map(l => [l.lane, l.status]), LANES.map(l => [l, 'researched']))
    assert.equal(result.status, 'complete')
  },

  async 'each lane runs its own agent type with its own pack path — catches a lane reading another lane\'s pack'() {
    const { calls } = await run(baseArgs())
    assert.equal(calls.length, 4)
    for (const { lane, prompt, opts } of calls) {
      assert.equal(opts.agentType, `swift-harness:design-lane-${lane}`)
      assert.ok(prompt.includes(`.harness/context-pack/research-lane-${lane}.md`), lane)
      for (const other of LANES.filter(l => l !== lane)) assert.ok(!prompt.includes(`research-lane-${other}.md`))
      assert.ok(opts.schema && opts.schema.type === 'object')
    }
  },

  async 'every lane prompt names its pin, the commit, the design doc and its evidence directory — catches a lane that cannot pin a claim or find stored evidence'() {
    const { calls } = await run(baseArgs())
    assert.equal(calls.length, 4)
    for (const { lane, prompt } of calls) {
      assert.ok(prompt.includes(PINS[lane]), `${lane} pin`)
      assert.ok(prompt.includes(COMMIT), `${lane} commit`)
      assert.ok(prompt.includes(DESIGN), `${lane} design`)
      assert.ok(prompt.includes('docs/checkout/designs/offline-order-queue.evidence/'), `${lane} evidence directory`)
      for (const other of LANES.filter(l => l !== lane && PINS[l] !== PINS[lane] && PINS[l] !== COMMIT)) {
        assert.ok(!prompt.includes(PINS[other]), `${lane} prompt names ${other}'s pin`)
      }
    }
  },

  async 'a pinless claim is dropped with a note and its lane keeps the rest — catches one missing pin throwing away a whole lane'() {
    const good = laneResult('prior-decisions')
    const pinless = {
      id: 'ev-prior-decisions-adr-without-pin',
      lane: 'prior-decisions',
      text: 'ADR 0002 keeps the plugin under plugin/.',
      citation: { kind: 'file', loc: 'docs/adrs/0002.md:L1-L2', pin: '', quote: 'plugin/' },
      status: 'new',
    }
    const pinlessProbe = {
      id: 'ev-prior-decisions-probe-without-pin',
      lane: 'prior-decisions',
      text: 'DependencyValues has a date key.',
      citation: { kind: 'probe', loc: 'probes/Probe_ev_prior_decisions_probe_without_pin.swift' },
      status: 'new',
    }
    const answer = {
      id: 'ev-prior-decisions-user-chose-one-client',
      lane: 'prior-decisions',
      text: 'The user chose one client.',
      citation: { kind: 'answer', loc: 'answers.jsonl#design-1/1', quote: 'one client' },
      status: 'new',
    }
    const { result, logs } = await run(baseArgs(), {
      'prior-decisions': () => ({
        ...good,
        claims: [...good.claims, pinless, pinlessProbe, answer],
        probes: [...good.probes, { claimId: pinlessProbe.id, swift: 'import Dependencies' }],
      }),
    })
    const lane = laneOf(result, 'prior-decisions')
    assert.equal(lane.status, 'researched')
    assert.deepEqual(lane.claims.map(c => c.id), [good.claims[0].id, answer.id])
    assert.deepEqual(lane.probes.map(p => p.claimId), [good.claims[0].id])
    assert.deepEqual(lane.dropped.map(d => d.id), [pinless.id, pinlessProbe.id])
    assert.ok(lane.dropped.every(d => /pin/.test(d.reason)))
    assert.equal(result.status, 'complete')
    assert.ok(logs.some(l => l.includes(pinless.id) && l.includes('prior-decisions')), logs.join('\n'))
    assert.deepEqual(laneOf(result, 'codebase').dropped, [])
  },

  async 'the apple-docs lane\'s snapshot requests come back with its result, and a malformed one is a defect — catches a missing snapshot vanishing silently'() {
    const request = { page: 'documentation/observation/migrating-from-the-observable-object-protocol', reason: 'Does SwiftUI track only properties the body reads?' }
    const { result } = await run(baseArgs(), {
      'apple-docs': () => ({ ...laneResult('apple-docs'), snapshotRequests: [request] }),
    })
    assert.deepEqual(laneOf(result, 'apple-docs').snapshotRequests, [request])
    assert.equal(laneOf(result, 'apple-docs').status, 'researched')

    const bad = await run(baseArgs(), {
      'apple-docs': () => ({ ...laneResult('apple-docs'), snapshotRequests: [{ page: '' , reason: 'x' }] }),
    })
    assert.match(laneOf(bad.result, 'apple-docs').reason, /malformed.*snapshotRequests/)
  },

  async 'a dead lane is NOT RESEARCHED with a reason and its siblings are kept — catches one death failing the whole fan-out'() {
    const { result, logs } = await run(baseArgs(), {
      packages: () => { throw new Error('terminal API error') },
      'apple-docs': () => null,
    })
    assert.equal(laneOf(result, 'packages').status, 'not-researched')
    assert.match(laneOf(result, 'packages').reason, /terminal API error/)
    assert.equal(laneOf(result, 'apple-docs').status, 'not-researched')
    assert.match(laneOf(result, 'apple-docs').reason, /no result/)
    assert.equal(laneOf(result, 'codebase').status, 'researched')
    assert.equal(laneOf(result, 'codebase').claims.length, 1)
    assert.equal(laneOf(result, 'prior-decisions').status, 'researched')
    assert.equal(result.status, 'incomplete')
    assert.ok(logs.some(l => /NOT RESEARCHED: apple-docs, packages/.test(l)), logs.join('\n'))
  },

  async 'a malformed lane return is NOT RESEARCHED naming the defect — catches unvalidated lane output reaching the claims file'() {
    const good = laneResult('packages')
    const malformed = [
      ['not an object', 'lane result'],
      [{ ...good, lane: 'codebase' }, 'lane'],
      [{ ...good, claims: undefined }, 'claims'],
      [{ ...good, claims: [{ ...good.claims[0], status: 'supported' }] }, 'status'],
      [{ ...good, claims: [{ ...good.claims[0], id: 'packages-finding' }] }, 'id'],
      [{ ...good, claims: [{ ...good.claims[0], lane: 'codebase' }] }, 'lane'],
      [{ ...good, claims: [{ ...good.claims[0], citation: { ...good.claims[0].citation, kind: 'web' } }] }, 'citation.kind'],
      [{ ...good, probes: [] }, 'probe'],
      [{ ...good, probes: [{ claimId: 'ev-not-a-claim-here', swift: 'x' }] }, 'claimId'],
      [{ ...good, needsDecision: [{ ...ask('Which?'), options: ['only one'] }] }, 'options'],
      [{ ...good, needsDecision: [{ ...ask('Which?'), recommendation: 'neither' }] }, 'recommendation'],
      [{ ...good, needsDecision: [{ ...ask('Which?'), evidence: 'ev-x' }] }, 'evidence'],
    ]
    for (const [bad, field] of malformed) {
      const { result } = await run(baseArgs(), { packages: () => bad })
      const lane = laneOf(result, 'packages')
      assert.equal(lane.status, 'not-researched', JSON.stringify(bad))
      assert.match(lane.reason, new RegExp(`malformed.*${field.replace('.', '\\.')}`), lane.reason)
      assert.equal(laneOf(result, 'codebase').status, 'researched')
    }
  },

  async 'two asking lanes produce one early return carrying both asks — catches a return per ask or an ask dropped'() {
    const { result } = await run(baseArgs(), {
      codebase: () => laneResult('codebase', { needsDecision: [ask('One LogClient or one per module?')] }),
      packages: () => laneResult('packages', { needsDecision: [ask('Pin TCA 1.26 or 1.27?', 'Pin 1.26')] }),
    })
    assert.equal(result.status, 'needs-decision')
    assert.deepEqual(
      result.needsDecision.map(d => [d.lane, d.question]),
      [['codebase', 'One LogClient or one per module?'], ['packages', 'Pin TCA 1.26 or 1.27?']],
    )
    assert.equal(result.needsDecision[1].recommendation, 'Pin 1.26')
    assert.equal(laneOf(result, 'codebase').status, 'needs-decision')
    assert.equal(laneOf(result, 'apple-docs').status, 'researched')
  },

  async 'resume with one answer changes only the asking lane\'s prompts — catches every lane re-running on resume'() {
    const Q = 'One LogClient or one per module?'
    const behave = {
      codebase: (prompt, n) =>
        prompt.includes('Keep one client')
          ? laneResult('codebase', { claimSuffix: 'answered' })
          : laneResult('codebase', { needsDecision: [ask(Q)] }),
      packages: () => laneResult('packages', { needsDecision: [ask('Pin TCA 1.26 or 1.27?', 'Pin 1.26')] }),
    }
    const first = await run(baseArgs(), behave)
    assert.equal(first.result.status, 'needs-decision')
    const resumed = await run(baseArgs({ answers: [{ question: Q, answer: 'Keep one client' }] }), behave)

    // Every first-round prompt replays byte-for-byte, in the same order, so the cache serves it.
    const firstPrompts = first.calls.map(c => [c.opts.label, c.prompt])
    assert.deepEqual(resumed.calls.slice(0, firstPrompts.length).map(c => [c.opts.label, c.prompt]), firstPrompts)
    const fresh = resumed.calls.slice(firstPrompts.length)
    assert.deepEqual(fresh.map(c => c.lane), ['codebase'])
    assert.ok(fresh[0].prompt.includes('Keep one client') && fresh[0].prompt.includes(Q))
    for (const call of resumed.calls.filter(c => c.lane !== 'codebase')) assert.ok(!call.prompt.includes('Keep one client'))

    assert.equal(laneOf(resumed.result, 'codebase').status, 'researched')
    assert.equal(laneOf(resumed.result, 'codebase').claims[0].id, 'ev-codebase-finding-answered')
    assert.deepEqual(resumed.result.needsDecision.map(d => d.lane), ['packages'])
    assert.deepEqual(resumed.result.unusedAnswers, [])
  },

  async 'a follow-up that asks again returns only the new ask, and the chain replays on the next resume — catches answers lost between rounds'() {
    const Q1 = 'One LogClient or one per module?'
    const Q2 = 'Sign logs with a subsystem?'
    const behave = {
      codebase: prompt => {
        if (prompt.includes('Subsystem yes')) return laneResult('codebase', { claimSuffix: 'final' })
        if (prompt.includes('Keep one client')) return laneResult('codebase', { needsDecision: [ask(Q2, 'Subsystem yes')] })
        return laneResult('codebase', { needsDecision: [ask(Q1)] })
      },
    }
    const a1 = [{ question: Q1, answer: 'Keep one client' }]
    const round2 = await run(baseArgs({ answers: a1 }), behave)
    assert.deepEqual(round2.result.needsDecision.map(d => d.question), [Q2])
    const round3 = await run(baseArgs({ answers: [...a1, { question: Q2, answer: 'Subsystem yes' }] }), behave)
    const prior = round2.calls.map(c => c.prompt)
    assert.deepEqual(round3.calls.slice(0, prior.length).map(c => c.prompt), prior)
    assert.equal(round3.calls.length, prior.length + 1)
    assert.equal(laneOf(round3.result, 'codebase').claims[0].id, 'ev-codebase-finding-final')
    assert.equal(round3.result.status, 'complete')
  },

  async 'an answer no lane asked is reported, not silently dropped — catches a mistyped question looking answered'() {
    const { result, logs } = await run(baseArgs({ answers: [{ question: 'Never asked?', answer: 'yes' }] }))
    assert.deepEqual(result.unusedAnswers, ['Never asked?'])
    assert.equal(result.status, 'complete')
    assert.ok(logs.some(l => l.includes('Never asked?')))
  },

  async 'reresearch runs one lane over the named claim ids — catches a stale claim re-running the whole fan-out'() {
    const ids = ['ev-packages-effect-run-cancellable', 'ev-packages-store-scope-signature']
    const { result, calls } = await run(
      baseArgs({ mode: 'reresearch', tier: 'quick', lanes: lanes(['packages']), claimIds: ids }),
    )
    assert.equal(calls.length, 1)
    assert.equal(calls[0].lane, 'packages')
    for (const id of ids) assert.ok(calls[0].prompt.includes(id), id)
    assert.match(calls[0].prompt, /stale/)
    assert.equal(result.mode, 'reresearch')
    assert.deepEqual(result.claimIds, ids)
    assert.deepEqual(result.lanes.map(l => l.lane), ['packages'])
  },

  async 'the return reports the output tokens the budget counted across the run and every lane call — catches design research cost left unrecorded or invented'() {
    const result = await runWithBudget(baseArgs(), { behave: { packages: () => null } })
    assert.equal(result.telemetry.outputTokens, 4000)
    assert.deepEqual(result.telemetry.agents, [
      { label: 'research:codebase', returned: true },
      { label: 'research:apple-docs', returned: true },
      { label: 'research:packages', returned: false },
      { label: 'research:prior-decisions', returned: true },
    ])
    assert.ok(result.telemetry.unavailable.some(u => /per-agent tokens/.test(u)))
    assert.ok(!result.telemetry.unavailable.some(u => /^output tokens: /.test(u)))
  },

  async 'with no budget in the runtime the token count is null and says why — catches a zero standing in for an unknown cost'() {
    const { result } = await run(baseArgs())
    assert.equal(result.telemetry.outputTokens, null)
    assert.ok(result.telemetry.unavailable.some(u => /^output tokens: /.test(u)))
    assert.equal(result.telemetry.agents.length, 4)
  },

  async 'a budget that throws leaves the token count null with a reason — catches a runtime error sinking the whole research return'() {
    const budget = { total: null, spent: () => { throw new Error('no budget this turn') }, remaining: () => Infinity }
    const result = await scriptWithBudget(baseArgs({ lanes: lanes(['codebase']) }), async () => laneResult('codebase'), () => {}, () => {}, budget)
    assert.equal(result.status, 'complete')
    assert.equal(result.telemetry.outputTokens, null)
    assert.ok(result.telemetry.unavailable.some(u => /^output tokens: /.test(u)))
  },

  async 'answer rounds are telemetry agents of their own — catches a resumed lane call missing from the run\'s record'() {
    const q = 'Split the queue client per feature?'
    let asked = false
    const result = await runWithBudget(baseArgs({ lanes: lanes(['codebase']), answers: [{ question: q, answer: 'Keep one client' }] }), {
      behave: { codebase: () => { if (asked) return laneResult('codebase'); asked = true; return laneResult('codebase', { needsDecision: [ask(q)] }) } },
    })
    assert.equal(result.telemetry.outputTokens, 2000)
    assert.deepEqual(result.telemetry.agents.map(a => a.label), ['research:codebase', 'answer:codebase:1'])
  },

  async 'the script touches no filesystem, network, clock or randomness — catches a workflow reading packs itself or breaking resume'() {
    const banned = [/\bimport\b/, /\brequire\s*\(/, /\bfetch\s*\(/, /\bprocess\./, /\bnode:/, /readFile|writeFile/,
      /XMLHttpRequest|WebSocket/, /Date\.now|new Date\s*\(|Math\.random/]
    const code = rawSource.replace(/\/\/.*$/gm, '')
    for (const pattern of banned) assert.ok(!pattern.test(code), `script matches ${pattern}`)
  },
}

// Captures the workflow's return for the gate's design-telemetry fixtures (the command is in
// plugin/gate/Tests/Fixtures/README.md). Runs only when asked, never as a test.
if (process.env.DESIGN_TELEMETRY_CAPTURE_DIR) {
  const dir = process.env.DESIGN_TELEMETRY_CAPTURE_DIR
  mkdirSync(dir, { recursive: true })
  const measured = await runWithBudget(baseArgs(), { startSpent: 18250, perCall: 3127 })
  writeFileSync(join(dir, 'research-result.json'), JSON.stringify(measured, null, 2) + '\n')
  const { result: unmeasured } = await run(baseArgs({ lanes: lanes(['codebase']) }))
  writeFileSync(join(dir, 'research-result-no-budget.json'), JSON.stringify(unmeasured, null, 2) + '\n')
}

let failed = 0
for (const [name, test] of Object.entries(tests)) {
  try {
    await test()
    console.log(`ok   ${name}`)
  } catch (error) {
    failed++
    console.log(`FAIL ${name}\n     ${String(error.message).split('\n').join('\n     ')}`)
  }
}
if (failed) {
  console.log(`${failed} failed`)
  process.exit(1)
}
