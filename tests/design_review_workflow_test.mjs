// Runs workflows/design-review.js against stubbed reviewer agents with real async delays.
// Run: node tests/design_review_workflow_test.mjs
// Regressions caught: a dead or malformed reviewer taking its siblings down; a revise round
// re-running every reviewer; the pre-mortem leaking into standard tier; a verifier's reordered
// or partial answer verifying the wrong finding; a return that `swiftgate review-synth --design`
// cannot read.
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
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

// What review-publish-amend.md actually has on hand to build `previous`: review-log.jsonl entries
// (finding id + disposition) and the finding's own title, never the earlier round's full return.
const reducedPrevious = (result, names) => ({
  reviews: names.map(name => {
    const entry = reviewOf(result, name)
    return {
      reviewer: name,
      status: entry.status,
      findings: entry.findings.map((f, i) => ({
        id: `design-20260925T180000Z/review-1/${i + 1}`,
        disposition: 'dismissed',
        summary: f.title,
      })),
    }
  }),
})

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

// The script with the runtime's `budget` in scope. `spent` counts the whole turn's output tokens,
// so each stub agent call adds its own output to it. Reviewers finish in the reverse of their
// start order, so a record kept in completion order would come back scrambled.
const scriptWithBudget = new AsyncFunction('args', 'agent', 'log', 'phase', 'budget', source)
async function runWithBudget(args, { startSpent = 5000, perCall = 500, behave = {}, budget } = {}) {
  let spent = startSpent
  const runtimeBudget = budget ?? { total: null, spent: () => spent, remaining: () => Infinity }
  const agent = async (prompt, opts) => {
    if (opts.agentType === VERIFIER) {
      await delay(4)
      spent += perCall
      return confirmAll(findingsInPrompt(prompt))
    }
    const reviewer = reviewerOfAgentType[opts.agentType]
    await delay([30, 20, 5, 1][ALL.indexOf(reviewer)])
    spent += perCall
    const fn = behave[reviewer]
    return fn ? await fn(prompt) : { findings: [finding()] }
  }
  return scriptWithBudget(args, agent, () => {}, () => {}, runtimeBudget)
}

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

// Resolves the real `swiftgate` binary, building it through `plugin/bin/swiftgate` when it isn't
// already built — never skips. Prefers the checkout's debug build: it is fresh under `swift test`,
// and a cold shim build would otherwise run every time this file does.
function resolveSwiftgateBinary(pluginRoot = root) {
  const debug = join(pluginRoot, 'gate/.build/debug/swiftgate')
  if (existsSync(debug)) return debug
  const shim = join(pluginRoot, 'bin/swiftgate')
  const cacheDir = mkdtempSync(join(tmpdir(), 'swiftgate-shim-'))
  // SWIFTGATE_BUILD_CONFIG keeps this a debug build (fast); a fresh SWIFTGATE_CACHE_DIR means
  // exactly one hash directory comes out, so the built binary's path needs no hash replication.
  execFileSync(shim, ['--version'], {
    stdio: 'pipe',
    env: { ...process.env, SWIFTGATE_BUILD_CONFIG: 'debug', SWIFTGATE_CACHE_DIR: cacheDir },
  })
  const binDir = join(cacheDir, 'bin')
  const hashes = existsSync(binDir) ? readdirSync(binDir) : []
  if (hashes.length !== 1) {
    throw new Error(`plugin/bin/swiftgate did not produce exactly one binary under ${binDir} (found ${hashes.length})`)
  }
  const binary = join(binDir, hashes[0], 'swiftgate')
  if (!existsSync(binary)) throw new Error(`plugin/bin/swiftgate did not produce ${binary}`)
  return binary
}

const tests = {
  async 'invalid args fail fast with a named error before any reviewer runs — catches a silent default reviewing the wrong thing'() {
    const first = (await run(baseArgs())).result
    const previous = reducedPrevious(first, ['challenger'])
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
      [baseArgs({ packs: packs(['challenger']), reviewers: ['challenger'], previous: { reviews: [] } }), 'MissingPreviousResultError'],
      [baseArgs({ packs: [], reviewers: ['challenger'], previous }), 'MissingPackPathError'],
      // Extra data for reviewers this round doesn't re-run is exactly the bloat the reduced shape
      // exists to rule out.
      [
        baseArgs({
          packs: packs(['challenger']),
          reviewers: ['challenger'],
          previous: reducedPrevious(first, ['challenger', 'standards-reviewer']),
        }),
        'InvalidArgsError',
      ],
      [
        baseArgs({
          packs: packs(['challenger']),
          reviewers: ['challenger'],
          previous: { reviews: [{ reviewer: 'challenger', status: 'fine', findings: [] }] },
        }),
        'InvalidArgsError',
      ],
      [
        baseArgs({
          packs: packs(['challenger']),
          reviewers: ['challenger'],
          previous: { reviews: [{ reviewer: 'challenger', status: 'reviewed', findings: [{ id: 'x', disposition: 'ignored', summary: 'y' }] }] },
        }),
        'InvalidArgsError',
      ],
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

  async 'standard tier runs all three reviewers at once — catches reviewers serialized behind each other'() {
    const { maxInFlight } = await run(baseArgs())
    assert.equal(maxInFlight, 3)
  },

  async 'deep tier never has more than 3 reviewer chains in flight — catches the fourth breaking the §11 fan-out cap'() {
    const { maxInFlight } = await run(baseArgs({ tier: 'deep', packs: packs(ALL) }))
    assert.equal(maxInFlight, 3)
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

  async 'a revise round runs only the named reviewers and leaves the rest to their own earlier files — catches cost blow-up and a carried reviewer being re-sent in full'() {
    const behave = {
      challenger: (prompt, n) => ({ findings: n === 1 ? [finding({ severity: 'blocker' })] : [] }),
      'evidence-auditor': () => ({ findings: [finding({ severity: 'minor', location: { anchor: 'risks' } })] }),
    }
    const first = await run(baseArgs(), behave)
    assert.deepEqual(first.perReviewer, { 'evidence-auditor': 1, 'standards-reviewer': 1, challenger: 1 })
    assert.deepEqual(first.perVerifier, { 'evidence-auditor': 1, challenger: 1 })

    // The same stubs, so the per-reviewer counters carry across the round.
    const previous = reducedPrevious(first.result, ['challenger'])
    assert.ok(JSON.stringify(previous).length < 500, 'the reduced previous is nowhere near the 16 KB bound')
    const revise = await run(baseArgs({ packs: packs(['challenger']), reviewers: ['challenger'], previous }), {
      ...behave,
      challenger: (prompt, n) => ({ findings: [finding({ severity: 'major', category: 'still-open' })] }),
    })
    assert.deepEqual(revise.perReviewer, { challenger: 1 })
    assert.deepEqual(revise.perVerifier, { challenger: 1 })
    assert.deepEqual(revise.calls.map(c => c.reviewer), ['challenger'])
    assert.ok(
      revise.calls[0].prompt.includes('Decision rests on an unverified claim'),
      'the re-run reviewer sees its earlier finding\'s summary',
    )
    assert.deepEqual(reviewOf(revise.result, 'challenger').findings.map(f => f.category), ['still-open'])
    // Only the reviewer this round actually ran comes back; a carried reviewer's full file already
    // lives on disk from the earlier round and isn't reproduced here.
    assert.deepEqual(revise.result.reviews.map(r => r.reviewer), ['challenger'])
    assert.ok(!reviewOf(revise.result, 'evidence-auditor'))
    assert.ok(!reviewOf(revise.result, 'standards-reviewer'))
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

  async 'a verifier that reorders or drops entries judges each finding by its own entry — catches one verifier slip swapping verdicts between findings'() {
    const race = finding({ title: 'Queue flushes twice', severity: 'major' })
    const cache = finding({ title: 'Cache never expires', category: 'stale-cache', severity: 'blocker' })
    const risk = finding({ title: 'No rollback path', location: { anchor: 'risks' }, category: 'missing-rollback', severity: 'minor' })
    const verdicts = {
      'Queue flushes twice': { verified: true, verification_note: 'race traced' },
      'Cache never expires': { verified: false, severity: 'minor', verification_note: 'TTL set in the Decision' },
      'No rollback path': { verified: true, verification_note: 'Risks omits rollback' },
    }
    const judged = f => ({ ...f, ...verdicts[f.title] })

    const reordered = await run(baseArgs(), {
      challenger: () => ({ findings: [race, cache, risk] }),
      verify: findings => ({ findings: [...findings].reverse().map(judged) }),
    })
    const [r1, c1, k1] = reviewOf(reordered.result, 'challenger').findings
    assert.deepEqual([r1.title, r1.verified, r1.severity], ['Queue flushes twice', true, 'major'])
    assert.deepEqual([c1.title, c1.verified, c1.severity], ['Cache never expires', false, 'minor'])
    assert.deepEqual([k1.title, k1.verified, k1.location.anchor], ['No rollback path', true, 'risks'])

    // The verifier drops the first entry and renames the cache finding's title: the cache finding
    // still pairs by anchor, category and kind, and the dropped one is unverified, never borrowed.
    const dropped = await run(baseArgs(), {
      challenger: () => ({ findings: [race, cache, risk] }),
      verify: findings => ({
        findings: [judged(findings[1]), judged(findings[2])].map(f =>
          f.category === 'stale-cache' ? { ...f, title: 'Cache entries never expire' } : f),
      }),
    })
    const [r2, c2, k2] = reviewOf(dropped.result, 'challenger').findings
    assert.equal(r2.verified, false)
    assert.match(r2.verification_note, /no verifier entry matched/)
    assert.deepEqual([c2.title, c2.verified, c2.severity], ['Cache never expires', false, 'minor'])
    assert.equal(k2.verified, true)
    reordered.result.reviews.forEach(assertReviewerFile)
    dropped.result.reviews.forEach(assertReviewerFile)
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
    const previous = reducedPrevious(first.result, ['pre-mortem'])
    const revise = await run(baseArgs({ tier: 'deep', packs: packs(['pre-mortem']), reviewers: ['pre-mortem'], previous }))
    assert.deepEqual(revise.perReviewer, { 'pre-mortem': 1 })
    assert.deepEqual(revise.result.reviews.map(r => r.reviewer), ['pre-mortem'])
    assert.deepEqual(revise.result.carried, CORE)
  },

  async 'the return is what review-synth --design reads, checked against the real command — catches the workflow and the gate drifting'() {
    const { result } = await run(baseArgs({ tier: 'deep', packs: packs(ALL) }), {
      'evidence-auditor': () => ({ findings: [finding({ severity: 'blocker' })] }),
      challenger: () => ({ findings: [finding({ severity: 'minor', category: 'blind-spot', location: { anchor: 'risks' } })] }),
      'pre-mortem': () => { throw new Error('died') },
    })
    result.reviews.forEach(assertReviewerFile)
    // Builds swiftgate through plugin/bin/swiftgate when it isn't already built; never skips this
    // check silently.
    const binary = resolveSwiftgateBinary()
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

  async 'a previous over the 16 KB bound is rejected, naming the fix — catches the headless tool input ceiling silently truncating a revise round'() {
    const bulky = {
      reviews: [
        {
          reviewer: 'challenger',
          status: 'reviewed',
          findings: Array.from({ length: 400 }, (_, i) => ({
            id: `design-20260925T180000Z/review-1/${i + 1}`,
            disposition: 'dismissed',
            summary: 'x'.repeat(40),
          })),
        },
      ],
    }
    assert.ok(JSON.stringify(bulky).length > 16 * 1024, 'the fixture must actually be over the bound')
    let ran = 0
    await assert.rejects(
      script(
        baseArgs({ packs: packs(['challenger']), reviewers: ['challenger'], previous: bulky }),
        async () => { ran++ },
        () => {},
        () => {},
      ),
      error => error.name === 'PreviousTooLargeError' || assert.fail(`expected PreviousTooLargeError, got ${error.name}: ${error.message}`),
    )
    assert.equal(ran, 0)
  },

  async 'a realistic previous built only from review-log dispositions and finding titles round-trips into the re-run reviewer\'s prompt — catches the workflow needing more than review-log can supply'() {
    const first = await run(baseArgs(), { challenger: () => ({ findings: [finding({ severity: 'blocker' })] }) })
    // What review-publish-amend.md has on hand after appending to review-log.jsonl: the finding id
    // it wrote, the disposition it recorded, and the finding's own title — never the full reviewer
    // file this workflow returned.
    const previous = {
      reviews: [
        {
          reviewer: 'challenger',
          status: 'reviewed',
          findings: [
            {
              id: 'design-20260925T180000Z/review-1/1',
              disposition: 'accepted',
              summary: reviewOf(first.result, 'challenger').findings[0].title,
            },
          ],
        },
      ],
    }
    const revise = await run(baseArgs({ packs: packs(['challenger']), reviewers: ['challenger'], previous }), {
      challenger: () => ({ findings: [finding({ severity: 'major', category: 'still-open' })] }),
    })
    assert.ok(revise.calls[0].prompt.includes('design-20260925T180000Z/review-1/1'))
    assert.ok(revise.calls[0].prompt.includes('accepted'))
    assert.ok(revise.calls[0].prompt.includes('Decision rests on an unverified claim'))
    assert.deepEqual(revise.result.reviews.map(r => r.reviewer), ['challenger'])
    assert.deepEqual(revise.result.carried, ['evidence-auditor', 'standards-reviewer'])
  },

  async 'a missing swiftgate binary fails the check rather than skipping it — catches the real review-synth check silently passing unrun'() {
    const bogusRoot = mkdtempSync(join(tmpdir(), 'design-review-workflow-no-binary-'))
    try {
      assert.throws(() => resolveSwiftgateBinary(bogusRoot))
    } finally {
      rmSync(bogusRoot, { recursive: true, force: true })
    }
  },

  async 'the return reports the output tokens the budget counted across the round and every reviewer and verifier call in reviewer order — catches design review cost left unrecorded or invented'() {
    const result = await runWithBudget(baseArgs(), { behave: { challenger: () => null } })
    assert.equal(result.telemetry.outputTokens, 2500)
    assert.deepEqual(result.telemetry.agents, [
      { label: 'review:evidence-auditor', returned: true },
      { label: 'verify:evidence-auditor', returned: true },
      { label: 'review:standards-reviewer', returned: true },
      { label: 'verify:standards-reviewer', returned: true },
      { label: 'review:challenger', returned: false },
    ])
    assert.ok(result.telemetry.unavailable.some(u => /per-agent tokens/.test(u)))
    assert.ok(!result.telemetry.unavailable.some(u => /^output tokens: /.test(u)))
  },

  async 'with no budget in the runtime the review token count is null and says why — catches a zero standing in for an unknown cost'() {
    const { result } = await run(baseArgs())
    assert.equal(result.telemetry.outputTokens, null)
    assert.ok(result.telemetry.unavailable.some(u => /^output tokens: /.test(u)))
    assert.deepEqual(result.telemetry.agents.map(a => a.label), ['review:evidence-auditor', 'review:standards-reviewer', 'review:challenger'])
  },

  async 'a reviewer that throws is a telemetry agent that did not return — catches a failed call vanishing from the record'() {
    const result = await runWithBudget(baseArgs(), { behave: { 'standards-reviewer': () => { throw new Error('agent crashed') } } })
    const entry = result.telemetry.agents.find(a => a.label === 'review:standards-reviewer')
    assert.deepEqual(entry, { label: 'review:standards-reviewer', returned: false })
    assert.equal(result.telemetry.agents.some(a => a.label === 'verify:standards-reviewer'), false)
  },
}

// Captures the workflow's return for the gate's design-telemetry fixtures (the command is in
// plugin/gate/Tests/Fixtures/README.md). Runs only when asked, never as a test.
if (process.env.DESIGN_TELEMETRY_CAPTURE_DIR) {
  const dir = process.env.DESIGN_TELEMETRY_CAPTURE_DIR
  mkdirSync(dir, { recursive: true })
  const measured = await runWithBudget(baseArgs(), { startSpent: 41020, perCall: 2211 })
  writeFileSync(join(dir, 'review-result.json'), JSON.stringify(measured, null, 2) + '\n')
  const { result: unmeasured } = await run(baseArgs())
  writeFileSync(join(dir, 'review-result-no-budget.json'), JSON.stringify(unmeasured, null, 2) + '\n')
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
