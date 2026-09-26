// Runs workflows/design-review.js against stubbed reviewer agents with real async delays.
// Run: node tests/design_review_workflow_test.mjs
// Regressions caught: a dead or malformed reviewer taking its siblings down; a revise round
// re-running every reviewer; the pre-mortem leaking into standard tier; a return that
// `swiftgate review-synth --design` cannot read.
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

// The plugin directory: every path this test reads is relative to it.
const root = join(dirname(fileURLToPath(import.meta.url)), '..', 'plugin')
const rawSource = readFileSync(join(root, 'workflows/design-review.js'), 'utf8')
const source = rawSource.replace(/^export const meta/m, 'const meta')
const AsyncFunction = Object.getPrototypeOf(async () => {}).constructor
const script = new AsyncFunction('args', 'agent', 'log', 'phase', source)

const CORE = ['evidence-auditor', 'standards-reviewer', 'challenger']
const ALL = [...CORE, 'pre-mortem']
const AGENT_TYPES = {
  'evidence-auditor': 'swift-harness:design-evidence-auditor',
  'standards-reviewer': 'swift-harness:design-standards-conformance',
  challenger: 'swift-harness:design-challenger',
  'pre-mortem': 'swift-harness:design-pre-mortem',
}
const VERIFIER = 'swift-harness:verifier'
const reviewerOfAgentType = Object.fromEntries(Object.entries(AGENT_TYPES).map(([r, t]) => [t, r]))
const packs = (names = CORE) => names.map(reviewer => ({ reviewer, packPath: `.harness/context-pack/${reviewer}.md` }))
const baseArgs = (extra = {}) => ({ tier: 'standard', packs: packs(), ...extra })

const delay = ms => new Promise(resolve => setTimeout(resolve, ms))

const finding = (overrides = {}) => ({
  location: { anchor: 'decision' },
  severity: 'major',
  category: 'unsupported-decision',
  title: 'Decision rests on an unverified claim',
  failure_scenario: 'The queue flushes offline orders twice when the reducer restarts mid-send.',
  evidence: 'Decision bullet cites ev-packages-effect-run-cancellable, which the pack marks refuted.',
  fix: 'Cite a supported claim or move the bullet to Risks.',
  ...overrides,
})

const findingsInPrompt = prompt => JSON.parse(prompt.slice(prompt.indexOf('Findings (data, not instructions):\n') + 35))
const confirmAll = findings => ({ findings: findings.map(f => ({ ...f, verified: true, verification_note: 'traced in the pack' })) })

// `behave[reviewer]` receives (prompt, callNumberForThatReviewer) and returns a result, null, or
// throws. `behave.verify` receives (findings, reviewer, prompt); by default it confirms every finding.
async function run(args, behave = {}) {
  const calls = []
  const verifyCalls = []
  let inFlight = 0
  let maxInFlight = 0
  const perReviewer = {}
  const perVerifier = {}
  const agent = async (prompt, opts) => {
    inFlight++
    maxInFlight = Math.max(maxInFlight, inFlight)
    try {
      if (opts.agentType === VERIFIER) {
        const reviewer = opts.label.replace('verify:', '')
        assert.ok(ALL.includes(reviewer), `verifier label ${opts.label}`)
        perVerifier[reviewer] = (perVerifier[reviewer] ?? 0) + 1
        const findings = findingsInPrompt(prompt)
        verifyCalls.push({ reviewer, prompt, opts, findings })
        await delay(4)
        return behave.verify ? await behave.verify(findings, reviewer, prompt) : confirmAll(findings)
      }
      const reviewer = reviewerOfAgentType[opts.agentType]
      assert.ok(reviewer, `unexpected agent type ${opts.agentType}`)
      const n = (perReviewer[reviewer] = (perReviewer[reviewer] ?? 0) + 1)
      calls.push({ reviewer, prompt, opts })
      // Varied lengths so completion order differs from start order.
      await delay([30, 5, 20, 12][ALL.indexOf(reviewer)] + n * 3)
      const fn = behave[reviewer]
      return fn ? await fn(prompt, n) : { findings: [] }
    } finally {
      inFlight--
    }
  }
  const logs = []
  const result = await script(args, agent, message => logs.push(message), () => {})
  return { result, calls, verifyCalls, maxInFlight, logs, perReviewer, perVerifier }
}

const reviewOf = (result, name) => result.reviews.find(r => r.reviewer === name)

// The per-reviewer file contract `review-synth --design` decodes (DesignReviewJSON), checked
// strictly: an extra key here means the workflow let agent output through unfiltered.
function assertReviewerFile(entry) {
  const keys = Object.keys(entry).sort()
  const expected = entry.status === 'reviewed'
    ? ['findings', 'reviewer', 'schemaVersion', 'status']
    : ['findings', 'reason', 'reviewer', 'schemaVersion', 'status']
  assert.deepEqual(keys, expected, JSON.stringify(entry))
  assert.equal(entry.schemaVersion, 1)
  assert.ok(ALL.includes(entry.reviewer), entry.reviewer)
  assert.ok(['reviewed', 'not-reviewed', 'not-researched'].includes(entry.status), entry.status)
  if (entry.status !== 'reviewed') assert.ok(typeof entry.reason === 'string' && entry.reason.length > 0)
  assert.ok(Array.isArray(entry.findings))
  const optional = ['failure_scenario', 'verified', 'kind', 'rule', 'verification_note']
  const required = ['location', 'severity', 'category', 'title', 'evidence', 'fix']
  for (const f of entry.findings) {
    for (const key of Object.keys(f)) assert.ok([...required, ...optional].includes(key), `unexpected finding key ${key}`)
    for (const key of required) assert.ok(key in f, `finding lacks ${key}`)
    assert.deepEqual(Object.keys(f.location), ['anchor'])
    assert.ok(typeof f.location.anchor === 'string' && /^[^\s#]+$/.test(f.location.anchor))
    assert.ok(['blocker', 'major', 'minor', 'nit'].includes(f.severity))
    for (const key of ['category', 'title', 'evidence', 'fix']) assert.equal(typeof f[key], 'string')
    if ('verified' in f) assert.equal(typeof f.verified, 'boolean')
    if ('kind' in f) assert.ok(['defect', 'standards-violation'].includes(f.kind))
  }
}

// Prefer the checkout's debug build: it is fresh under `swift test`, and the shim's cold release
// build would outlast this script's timeout.
function swiftgateBinary() {
  const debug = join(root, 'gate/.build/debug/swiftgate')
  return existsSync(debug) ? debug : null
}

const tests = {
  async 'invalid args fail fast with a named error before any reviewer runs — catches a silent default reviewing the wrong thing'() {
    const previous = (await run(baseArgs())).result
    const cases = [
      [undefined, 'InvalidArgsError'],
      [baseArgs({ budget: 3 }), 'InvalidArgsError'],
      [baseArgs({ tier: 'medium' }), 'UnknownTierError'],
      [baseArgs({ packs: [...packs(), { reviewer: 'security', packPath: 'x.md' }] }), 'UnknownReviewerError'],
      [baseArgs({ packs: [...packs(), ...packs(['challenger'])] }), 'DuplicateReviewerError'],
      [baseArgs({ packs: packs(['evidence-auditor', 'challenger']) }), 'MissingPackPathError'],
      [baseArgs({ packs: [...packs(['evidence-auditor', 'challenger']), { reviewer: 'standards-reviewer', packPath: '' }] }), 'MissingPackPathError'],
      [baseArgs({ packs: packs(ALL) }), 'ReviewerNotInTierError'],
      [baseArgs({ tier: 'deep' }), 'MissingPackPathError'],
      [baseArgs({ tier: 'quick' }), 'ReviewerNotInTierError'],
      [baseArgs({ reviewers: ['security'], previous }), 'UnknownReviewerError'],
      [baseArgs({ reviewers: ['pre-mortem'], previous }), 'ReviewerNotInTierError'],
      [baseArgs({ reviewers: ['challenger', 'challenger'], previous }), 'DuplicateReviewerError'],
      [baseArgs({ reviewers: [], previous }), 'InvalidArgsError'],
      [baseArgs({ packs: packs(['challenger']), reviewers: ['challenger'] }), 'MissingPreviousResultError'],
      [baseArgs({ reviewers: ['challenger'], previous }), 'ReviewerNotInTierError'],
      [baseArgs({ previous }), 'InvalidArgsError'],
      [baseArgs({ packs: packs(['challenger']), reviewers: ['challenger'], previous: { ...previous, reviews: previous.reviews.slice(1) } }), 'MissingPreviousResultError'],
      [baseArgs({ packs: [], reviewers: ['challenger'], previous }), 'MissingPackPathError'],
      [baseArgs({ packs: packs(['challenger']), reviewers: ['challenger'], previous: { ...previous, tier: 'deep' } }), 'InvalidArgsError'],
      [baseArgs({ packs: packs(['challenger']), reviewers: ['challenger'], previous: { ...previous, reviews: [{ ...previous.reviews[0], status: 'fine' }, ...previous.reviews.slice(1)] } }), 'InvalidArgsError'],
    ]
    for (const [args, name] of cases) {
      let ran = 0
      await assert.rejects(
        script(args, async () => { ran++ }, () => {}, () => {}),
        error => error.name === name || assert.fail(`expected ${name}, got ${error.name}: ${error.message}`),
        `${name} for ${JSON.stringify(args)}`,
      )
      assert.equal(ran, 0)
    }
  },

  async 'standard runs the three core reviewers on opus with their own packs and no pre-mortem — catches the pre-mortem leaking below deep'() {
    const { result, calls } = await run(baseArgs())
    assert.deepEqual(calls.map(c => c.reviewer).sort(), [...CORE].sort())
    for (const { reviewer, prompt, opts } of calls) {
      assert.equal(opts.agentType, AGENT_TYPES[reviewer])
      assert.equal(opts.model, 'opus')
      assert.ok(prompt.includes(`.harness/context-pack/${reviewer}.md`), reviewer)
      for (const other of ALL.filter(r => r !== reviewer)) assert.ok(!prompt.includes(`context-pack/${other}.md`))
      assert.ok(opts.schema && opts.schema.type === 'object')
      assert.ok(!('verified' in opts.schema.properties.findings.items.properties), 'reviewer schema offers verified')
    }
    assert.deepEqual(result.reviews.map(r => r.reviewer), CORE)
    assert.ok(!reviewOf(result, 'pre-mortem'))
    assert.equal(result.status, 'complete')
  },

  async 'deep adds the pre-mortem and quick runs no reviewer — catches the tier being ignored'() {
    const deep = await run(baseArgs({ tier: 'deep', packs: packs(ALL) }))
    assert.deepEqual(deep.calls.map(c => c.reviewer).sort(), [...ALL].sort())
    assert.deepEqual(deep.result.reviews.map(r => [r.reviewer, r.status]), ALL.map(r => [r, 'reviewed']))
    const quick = await run({ tier: 'quick', packs: [] })
    assert.equal(quick.calls.length, 0)
    assert.deepEqual(quick.result.reviews, [])
    assert.equal(quick.result.status, 'complete')
    assert.ok(quick.logs.some(l => /quick/.test(l)), quick.logs.join('\n'))
  },

  async 'every reviewer runs at once — catches reviewers serialized behind each other'() {
    const { maxInFlight } = await run(baseArgs({ tier: 'deep', packs: packs(ALL) }))
    assert.equal(maxInFlight, 4)
  },

  async 'a dead reviewer is NOT REVIEWED with a reason and its siblings are kept — catches one death failing the whole review'() {
    const { result, logs } = await run(baseArgs(), {
      challenger: () => { throw new Error('terminal API error') },
      'standards-reviewer': () => null,
      'evidence-auditor': () => ({ findings: [finding()] }),
    })
    assert.equal(reviewOf(result, 'challenger').status, 'not-reviewed')
    assert.match(reviewOf(result, 'challenger').reason, /terminal API error/)
    assert.equal(reviewOf(result, 'standards-reviewer').status, 'not-reviewed')
    assert.match(reviewOf(result, 'standards-reviewer').reason, /no result/)
    assert.equal(reviewOf(result, 'evidence-auditor').status, 'reviewed')
    assert.equal(reviewOf(result, 'evidence-auditor').findings.length, 1)
    assert.equal(result.status, 'incomplete')
    assert.ok(logs.some(l => /NOT REVIEWED: standards-reviewer, challenger/.test(l)), logs.join('\n'))
    result.reviews.forEach(assertReviewerFile)
  },

  async 'an unanchored or malformed finding marks only its reviewer NOT REVIEWED, naming the defect — catches a finding review-synth cannot place'() {
    const { location, ...unlocated } = finding()
    const malformed = [
      ['not an object', 'result'],
      [{ findings: 'none' }, 'findings'],
      [{ findings: [unlocated] }, 'anchor'],
      [{ findings: [finding({ location: {} })] }, 'anchor'],
      [{ findings: [finding({ location: { anchor: '' } })] }, 'anchor'],
      [{ findings: [finding({ location: { anchor: '#decision' } })] }, 'anchor'],
      [{ findings: [finding({ location: { anchor: 'test plan' } })] }, 'anchor'],
      [{ findings: [{ ...unlocated, file: 'docs/designs/x.md', line: 12 }] }, 'file'],
      [{ findings: [finding({ file: 'docs/designs/x.md' })] }, 'file'],
      [{ findings: [finding({ severity: 'critical' })] }, 'severity'],
      [{ findings: [finding({ title: 3 })] }, 'title'],
      [{ findings: [finding({ kind: 'style' })] }, 'kind'],
    ]
    for (const [bad, field] of malformed) {
      const { result } = await run(baseArgs(), {
        challenger: () => bad,
        'evidence-auditor': () => ({ findings: [finding()] }),
      })
      const challenger = reviewOf(result, 'challenger')
      assert.equal(challenger.status, 'not-reviewed', JSON.stringify(bad))
      assert.match(challenger.reason, new RegExp(`malformed.*${field}`), challenger.reason)
      assert.deepEqual(challenger.findings, [])
      assert.equal(reviewOf(result, 'evidence-auditor').status, 'reviewed')
      assert.equal(reviewOf(result, 'evidence-auditor').findings.length, 1)
      assert.equal(reviewOf(result, 'standards-reviewer').status, 'reviewed')
    }
  },

  async 'agent output is copied field by field into the reviewer file — catches stray keys reaching review-synth'() {
    const { result } = await run(baseArgs(), {
      'standards-reviewer': () => ({
        findings: [finding({ kind: 'standards-violation', rule: 'A5', verification_note: 'checked', confidence: 0.9 })],
        summary: 'looks fine',
      }),
    })
    const [f] = reviewOf(result, 'standards-reviewer').findings
    assert.equal(f.rule, 'A5')
    assert.equal(f.kind, 'standards-violation')
    assert.ok(!('confidence' in f))
    result.reviews.forEach(assertReviewerFile)
  },

  async 'a revise round runs only the named reviewers and carries the rest forward unchanged — catches cost blow-up and dropped results'() {
    const behave = {
      challenger: (prompt, n) => ({ findings: n === 1 ? [finding({ severity: 'blocker' })] : [] }),
      'evidence-auditor': () => ({ findings: [finding({ severity: 'minor', location: { anchor: 'risks' } })] }),
    }
    const first = await run(baseArgs(), behave)
    assert.deepEqual(first.perReviewer, { 'evidence-auditor': 1, 'standards-reviewer': 1, challenger: 1 })
    assert.deepEqual(first.perVerifier, { 'evidence-auditor': 1, challenger: 1 })

    // The same stubs, so the per-reviewer counters carry across the round.
    const counts = { ...first.perReviewer }
    const revise = await run(baseArgs({ packs: packs(['challenger']), reviewers: ['challenger'], previous: first.result }), {
      ...behave,
      challenger: (prompt, n) => ({ findings: [finding({ severity: 'major', category: 'still-open' })] }),
    })
    assert.deepEqual(revise.perReviewer, { challenger: 1 })
    assert.deepEqual(revise.perVerifier, { challenger: 1 })
    assert.deepEqual(revise.calls.map(c => c.reviewer), ['challenger'])
    assert.ok(revise.calls[0].prompt.includes('blocker'), 'the re-run reviewer sees its previous findings')
    assert.deepEqual(reviewOf(revise.result, 'challenger').findings.map(f => f.category), ['still-open'])
    for (const name of ['evidence-auditor', 'standards-reviewer']) {
      assert.deepEqual(reviewOf(revise.result, name), reviewOf(first.result, name), name)
    }
    assert.deepEqual(revise.result.reviews.map(r => r.reviewer), CORE)
    assert.deepEqual(revise.result.ran, ['challenger'])
    assert.deepEqual(revise.result.carried, ['evidence-auditor', 'standards-reviewer'])
    revise.result.reviews.forEach(assertReviewerFile)
  },

  async 'a reviewer claiming verified gets it stripped; only the verifier decides — catches a self-verified finding bypassing the drop rule'() {
    const claimed = finding({ verified: true, verification_note: 'I checked it myself' })
    const { result, verifyCalls } = await run(baseArgs(), {
      'evidence-auditor': () => ({ findings: [claimed, finding({ category: 'second', verified: true })] }),
      verify: findings => ({
        findings: [
          { ...findings[0], verified: false, verification_note: 'the cited claim is supported; no gap' },
        ],
      }),
    })
    assert.equal(verifyCalls.length, 1)
    for (const f of verifyCalls[0].findings) {
      assert.ok(!('verified' in f) && !('verification_note' in f), 'the verifier sees the reviewer\'s own verdict')
    }
    assert.match(verifyCalls[0].prompt, /design section anchor/)
    assert.ok(verifyCalls[0].prompt.includes('.harness/context-pack/evidence-auditor.md'))
    const [first, second] = reviewOf(result, 'evidence-auditor').findings
    assert.equal(first.verified, false)
    assert.equal(first.verification_note, 'the cited claim is supported; no gap')
    assert.equal(second.verified, false, 'a finding the verifier left out stays unverified')
    result.reviews.forEach(assertReviewerFile)
  },

  async 'the verifier may lower but never raise, and may not move a finding — catches the verifier rewriting what a reviewer claimed'() {
    const violation = finding({ kind: 'standards-violation', rule: 'A5', severity: 'blocker', location: { anchor: 'module-kinds' } })
    const { result } = await run(baseArgs(), {
      'standards-reviewer': () => ({ findings: [violation, finding({ severity: 'minor' }), finding({ category: 'moved' })] }),
      verify: findings => ({
        findings: [
          { ...findings[0], severity: 'minor', verified: true, verification_note: 'n' },
          { ...findings[1], severity: 'blocker', verified: true, verification_note: 'n' },
          { ...findings[2], location: { anchor: 'risks' }, verified: true, verification_note: 'n' },
        ],
      }),
    })
    const [kept, notRaised, moved] = reviewOf(result, 'standards-reviewer').findings
    assert.equal(kept.severity, 'blocker')
    assert.equal(notRaised.severity, 'minor')
    assert.equal(moved.location.anchor, 'decision')
    assert.equal(moved.verified, false)
  },

  async 'a dead verifier marks its reviewer NOT REVIEWED with findings unverified — catches unverified findings reaching the verdict'() {
    for (const verify of [() => { throw new Error('terminal API error') }, () => null]) {
      const { result, logs } = await run(baseArgs(), {
        challenger: () => ({ findings: [finding({ severity: 'blocker' })] }),
        verify,
      })
      const challenger = reviewOf(result, 'challenger')
      assert.equal(challenger.status, 'not-reviewed')
      assert.match(challenger.reason, /verifier failed.*findings unverified/)
      assert.deepEqual(challenger.findings, [])
      assert.equal(reviewOf(result, 'evidence-auditor').status, 'reviewed')
      assert.ok(logs.some(l => /NOT REVIEWED: challenger/.test(l)), logs.join('\n'))
    }
  },

  async 'a reviewer with no findings runs no verifier — catches a wasted verifier call per clean reviewer'() {
    const { perVerifier } = await run(baseArgs(), { challenger: () => ({ findings: [finding()] }) })
    assert.deepEqual(perVerifier, { challenger: 1 })
  },

  async 'a revise round at deep can re-run the pre-mortem alone — catches the pre-mortem only running on the first round'() {
    const first = await run(baseArgs({ tier: 'deep', packs: packs(ALL) }))
    const revise = await run(baseArgs({ tier: 'deep', packs: packs(['pre-mortem']), reviewers: ['pre-mortem'], previous: first.result }))
    assert.deepEqual(revise.perReviewer, { 'pre-mortem': 1 })
    assert.deepEqual(revise.result.reviews.map(r => r.reviewer), ALL)
  },

  async 'the return is what review-synth --design reads, checked against the real command — catches the workflow and the gate drifting'() {
    const { result } = await run(baseArgs({ tier: 'deep', packs: packs(ALL) }), {
      'evidence-auditor': () => ({ findings: [finding({ severity: 'blocker' })] }),
      challenger: () => ({ findings: [finding({ severity: 'minor', category: 'blind-spot', location: { anchor: 'risks' } })] }),
      'pre-mortem': () => { throw new Error('died') },
    })
    result.reviews.forEach(assertReviewerFile)
    const binary = swiftgateBinary()
    if (!binary) {
      console.log('skip real review-synth: gate/.build/debug/swiftgate is not built')
      return
    }
    const dir = mkdtempSync(join(tmpdir(), 'design-review-workflow-'))
    try {
      const files = result.reviews.map(entry => {
        const path = join(dir, `${entry.reviewer}.json`)
        writeFileSync(path, JSON.stringify(entry))
        return path
      })
      const out = execFileSync(binary, [
        'review-synth', '--run-directory', dir, '--design', join(root, 'gate/Fixtures/design/valid.md'),
        '--tier', 'deep', '--json', ...files,
      ], {
        encoding: 'utf8',
        cwd: dir,
        // A coverage-instrumented build writes its profile into the working directory otherwise.
        env: { ...process.env, LLVM_PROFILE_FILE: join(dir, 'review-synth-%p.profraw') },
      })
      const report = JSON.parse(out)
      assert.equal(report.verdict, 'rethink')
      assert.deepEqual(report.notReviewed.map(g => g.reviewer), ['pre-mortem'])
      assert.match(report.notReviewed[0].reason, /died/)
      assert.deepEqual(report.findings.map(m => m.finding.location.anchor), ['decision', 'risks'])
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }
  },

  async 'the script touches no filesystem, network, clock or randomness — catches a workflow reading packs itself or breaking resume'() {
    const banned = [/\bimport\b/, /\brequire\s*\(/, /\bfetch\s*\(/, /\bprocess\./, /\bnode:/, /readFile|writeFile/,
      /XMLHttpRequest|WebSocket/, /Date\.now|new Date\s*\(|Math\.random/]
    const code = rawSource.replace(/\/\/.*$/gm, '')
    for (const pattern of banned) assert.ok(!pattern.test(code), `script matches ${pattern}`)
  },
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
