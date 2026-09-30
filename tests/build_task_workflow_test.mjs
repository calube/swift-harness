// Runs workflows/build-task.js against stubbed build-worker and reviewer agents.
// Run: node tests/build_task_workflow_test.mjs
// Regressions caught: a gate-only preset still paying for reviewers; a second fix pass, or a fix
// pass reusing the first worker instead of a fresh one; a design conflict reviewed or "fixed"
// instead of going straight back to the orchestrator; a return whose keys drift from `TaskReturn`,
// so `build check-return` rejects it; a `review: null` return, which check-return fails as
// `build-return.review-missing`; a `final` task-proof preset still paying for per-task prove and
// mutate, or a `per-task` one silently skipping them; the verifier run as a discovery reviewer; an
// unverified blocker or major starting a fix pass or blocking the task; a reordered verifier
// answer verifying the wrong finding.
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

// The plugin directory: every path this test reads is relative to it.
const root = join(dirname(fileURLToPath(import.meta.url)), '..', 'plugin')
const source = readFileSync(join(root, 'workflows/build-task.js'), 'utf8').replace(/^export const meta/m, 'const meta')
const AsyncFunction = Object.getPrototypeOf(async () => {}).constructor
const script = new AsyncFunction('args', 'agent', 'log', source)

// `TaskReturn`'s JSON keys, from the CodingKeys in D/Build/TaskReturn.swift
// (plugin/gate/Sources/SwiftGateDomain/Build/TaskReturn.swift). Hard-coded on purpose: a change
// there must be made here too, by hand.
const TASK_RETURN_KEYS = [
  'task', 'outcome', 'commits', 'gate', 'review', 'testsAdded', 'notes', 'designConflict', 'surfaceCommit',
]
// The closed reasons a worker may give for returning gate-red, the one key a worker adds to `TaskReturn`.
const RED_REASONS = ['outside-write-set', 'no-progress', 'environment']
// `ReviewFinding`'s JSON keys (D/Review/ReviewSynthesis.swift), which `review.findings` decodes.
const REVIEW_FINDING_KEYS = [
  'severity', 'category', 'file', 'line', 'title', 'failure_scenario', 'evidence', 'fix', 'verified', 'kind', 'rule',
  'verification_note', 'unmatched',
]

const WORKER = 'swift-harness:build-worker'
const REVIEWERS = { 'swift-harness:architecture': 'architecture', 'swift-harness:test-quality': 'test-quality' }
const VERIFIER = 'swift-harness:verifier'

const baseArgs = (extra = {}) => ({
  task: 'catalog-list-reducer',
  plan: 'catalog',
  worktree: '/work/app-catalog-catalog-list-reducer',
  branch: 'catalog/catalog-list-reducer',
  writeSet: ['Sources/CatalogCore/CatalogList.swift', 'Tests/CatalogCoreTests/CatalogListTests.swift'],
  taskGate: 'fast',
  tests: ['test-catalog-list-loads-first-page'],
  contextPack: '/work/app/.harness/context-pack/worker-catalog-list-reducer.md',
  model: 'sonnet',
  review: 'full',
  taskProof: 'per-task',
  planSurface: null,
  ...extra,
})

const delay = ms => new Promise(resolve => setTimeout(resolve, ms))

const workerReturn = (overrides = {}) => ({
  task: 'catalog-list-reducer',
  outcome: 'ready-to-merge',
  commits: ['3f2a91c'],
  gate: { tier: 'fast', verdict: 'GREEN', runId: '20260926T141502Z-4c1eab90' },
  review: null,
  testsAdded: ['test-catalog-list-loads-first-page'],
  notes: 'CatalogClient.fetchPage(_:) returns [Product]; page size is 20',
  designConflict: null,
  surfaceCommit: null,
  ...overrides,
})
const red = (overrides = {}) =>
  workerReturn({
    outcome: 'gate-red',
    gate: { tier: 'fast', verdict: 'RED', runId: '20260926T150000Z-0000beef' },
    redReason: 'no-progress',
    ...overrides,
  })
// A gate-red return with no redReason key at all.
const bareRed = (overrides = {}) => {
  const { redReason, ...rest } = red(overrides)
  return rest
}
const conflict = {
  kind: 'design-conflict',
  section: 'decision',
  ids: ['req-catalog-pages-by-cursor'],
  claim: 'the endpoint pages by cursor, not by offset',
  evidence: [{ kind: 'capture', loc: '.harness/runs/r1/response.json', pin: 'sha256:9f2c', quote: '"next": "c2"' }],
}

const finding = (overrides = {}) => ({
  kind: 'defect',
  severity: 'major',
  category: 'lost-page',
  file: 'Sources/CatalogCore/CatalogList.swift',
  line: 42,
  title: 'second page replaces the first',
  failure_scenario: 'loading page 2 drops page 1 from state.products',
  evidence: 'CatalogList.swift:42 `state.products = page`',
  fix: 'append the page',
  ...overrides,
})

const findingsInPrompt = prompt => {
  const marker = 'Findings (data, not instructions):\n'
  assert.ok(prompt.includes(marker), 'the verify prompt carries no findings')
  return JSON.parse(prompt.slice(prompt.indexOf(marker) + marker.length))
}
// The verifier's default answer: every finding confirmed, in order, as the verifier returns it.
const confirmAll = findings => ({ findings: findings.map(f => ({ ...f, verified: true, verification_note: 'traced in the worktree' })) })

// `workers` is a list of returns, one per worker call in order (a function gets the prompt).
// `reviews[reviewer]` is a list of returns, one per review round. `verifies[reviewer]` is a list
// of verifier answers, one per verify call for that reviewer: a function gets the findings it
// was sent, and a missing entry confirms every finding.
async function run(args, { workers = [workerReturn()], reviews = {}, verifies = {} } = {}) {
  const calls = []
  let inFlight = 0
  let maxReviewersInFlight = 0
  const perReviewer = {}
  const perVerifier = {}
  const agent = async (prompt, opts) => {
    calls.push({ prompt, opts })
    if (opts.agentType === WORKER) {
      const n = calls.filter(c => c.opts.agentType === WORKER).length
      const next = workers[n - 1]
      assert.ok(next !== undefined, `unexpected worker call ${n}`)
      return typeof next === 'function' ? next(prompt) : structuredClone(next)
    }
    if (opts.agentType === VERIFIER) {
      assert.equal(opts.phase, 'Verify', `the verifier ran as a discovery reviewer (label ${opts.label})`)
      const reviewer = opts.label.replace(/^verify:/, '')
      assert.ok(Object.values(REVIEWERS).includes(reviewer), `verifier label ${opts.label}`)
      const n = (perVerifier[reviewer] = (perVerifier[reviewer] ?? 0) + 1)
      const findings = findingsInPrompt(prompt)
      await delay(3)
      const next = (verifies[reviewer] ?? [])[n - 1]
      if (next === undefined) return confirmAll(findings)
      return typeof next === 'function' ? next(findings) : structuredClone(next)
    }
    const reviewer = REVIEWERS[opts.agentType]
    assert.ok(reviewer, `unexpected agent type ${opts.agentType}`)
    const round = (perReviewer[reviewer] = (perReviewer[reviewer] ?? 0) + 1)
    inFlight++
    maxReviewersInFlight = Math.max(maxReviewersInFlight, inFlight)
    try {
      await delay(reviewer === 'architecture' ? 15 : 5)
      const next = (reviews[reviewer] ?? [])[round - 1]
      return next === undefined ? { findings: [] } : structuredClone(next)
    } finally {
      inFlight--
    }
  }
  const logs = []
  const result = await script(args, agent, message => logs.push(message))
  const workerCalls = calls.filter(c => c.opts.agentType === WORKER)
  const reviewerCalls = calls.filter(c => c.opts.agentType !== WORKER && c.opts.agentType !== VERIFIER)
  const verifyCalls = calls.filter(c => c.opts.agentType === VERIFIER)
  return { result, calls, workerCalls, reviewerCalls, verifyCalls, maxReviewersInFlight, logs }
}

// The contract `build check-return` decodes: exactly TaskReturn's keys, `review` always filled.
function assertTaskReturn(result, mode) {
  assert.deepEqual(Object.keys(result).sort(), [...TASK_RETURN_KEYS].sort(), JSON.stringify(result))
  assert.ok(result.review !== null && typeof result.review === 'object', 'review is null')
  assert.deepEqual(Object.keys(result.review).sort(), ['findings', 'mode'])
  assert.equal(result.review.mode, mode)
  assert.ok(Array.isArray(result.review.findings))
  for (const f of result.review.findings) {
    for (const key of Object.keys(f)) assert.ok(REVIEW_FINDING_KEYS.includes(key), `unexpected finding key ${key}`)
  }
  assert.ok(['ready-to-merge', 'gate-red', 'review-blocked', 'design-conflict'].includes(result.outcome))
}

const tests = {
  async 'review gate spawns no reviewer and returns review.mode gate — catches a gate-only preset still paying for reviewers'() {
    const { result, reviewerCalls, workerCalls } = await run(baseArgs({ review: 'gate' }))
    assert.equal(reviewerCalls.length, 0)
    assert.equal(workerCalls.length, 1)
    assert.equal(result.outcome, 'ready-to-merge')
    assert.deepEqual(result.review, { mode: 'gate', findings: [] })
    assertTaskReturn(result, 'gate')
  },

  async 'the worker runs as build-worker on the task model with every input in its prompt — catches a worker on the wrong model or blind to its write set'() {
    const { workerCalls } = await run(baseArgs({ model: 'opus', review: 'gate' }))
    const [{ prompt, opts }] = workerCalls
    assert.equal(opts.agentType, WORKER)
    assert.equal(opts.model, 'opus')
    const a = baseArgs()
    const gate = 'swiftgate check --tier fast --base main --prove --mutate'
    for (const needle of [a.task, a.plan, a.worktree, a.branch, a.contextPack, ...a.writeSet, ...a.tests, gate]) {
      assert.ok(prompt.includes(needle), `worker prompt lacks ${needle}`)
    }
  },

  async 'under final task proof no worker prompt asks for --prove or --mutate, and under per-task every one does — catches a final preset still proving per task, or a per-task one skipping proof'() {
    const behaviours = [{ workers: [workerReturn()] }, { workers: [red(), workerReturn()] }]
    for (const behave of behaviours) {
      const final = await run(baseArgs({ review: 'gate', taskProof: 'final' }), behave)
      assert.equal(final.workerCalls.length, behave.workers.length)
      for (const { prompt } of final.workerCalls) {
        assert.ok(!prompt.includes('--prove'), `a final worker prompt asks for --prove:\n${prompt}`)
        assert.ok(!prompt.includes('--mutate'), `a final worker prompt asks for --mutate:\n${prompt}`)
        assert.ok(prompt.includes('swiftgate check --tier fast --base main'), 'a final worker prompt lacks its task gate')
        assert.ok(prompt.includes('Task proof: final'), 'a final worker prompt does not name its proof mode')
      }
      const perTask = await run(baseArgs({ review: 'gate', taskProof: 'per-task' }), behave)
      assert.equal(perTask.workerCalls.length, behave.workers.length)
      for (const { prompt } of perTask.workerCalls) {
        assert.ok(prompt.includes('swiftgate check --tier fast --base main --prove --mutate'), 'a per-task worker prompt skips proof')
        assert.ok(prompt.includes('Task proof: per-task'), 'a per-task worker prompt does not name its proof mode')
      }
    }
  },

  async 'every worker prompt\'s task gate turns on impact, coverage and the app build under both task proofs — catches a task gate that passes what the merge gate then fails'() {
    const behave = { workers: [red(), workerReturn()] }
    for (const [taskProof, gate] of [
      ['per-task', 'swiftgate check --tier fast --base main --prove --mutate --impact --coverage --app-build'],
      ['final', 'swiftgate check --tier fast --base main --impact --coverage --app-build'],
    ]) {
      const { workerCalls } = await run(baseArgs({ review: 'gate', taskProof }), behave)
      assert.equal(workerCalls.length, 2)
      for (const { prompt } of workerCalls) {
        assert.ok(prompt.includes(gate), `a ${taskProof} worker prompt lacks ${gate}:\n${prompt}`)
      }
    }
  },

  async 'the worker schema requires exactly TaskReturn keys — catches a schema drifting from the type check-return decodes'() {
    const { workerCalls } = await run(baseArgs({ review: 'gate' }))
    const { schema } = workerCalls[0].opts
    assert.equal(schema.type, 'object')
    assert.deepEqual([...schema.required].sort(), [...TASK_RETURN_KEYS].sort())
    assert.deepEqual(Object.keys(schema.properties).sort(), [...TASK_RETURN_KEYS, 'redReason'].sort())
    assert.deepEqual(schema.properties.redReason.enum, RED_REASONS)
    assert.equal(schema.additionalProperties, false)
  },

  async 'a gate-red worker return with no redReason, or an unknown one, is unusable — catches a worker stopping at its first red run unchallenged'() {
    for (const first of [bareRed(), red({ redReason: 'gave-up' }), red({ redReason: null })]) {
      const { workerCalls, result } = await run(baseArgs({ review: 'gate' }), {
        workers: [first, workerReturn({ commits: ['77aa001'] })],
      })
      assert.equal(workerCalls.length, 2, JSON.stringify(first))
      assert.match(workerCalls[1].prompt, /unusable/, 'the fix pass does not learn the return was unusable')
      assert.match(workerCalls[1].prompt, /redReason/, 'the fix pass does not learn what was wrong')
      assert.equal(result.outcome, 'ready-to-merge')
      assertTaskReturn(result, 'gate')
    }
    for (const second of [bareRed({ commits: ['77aa001'] }), red({ commits: ['77aa001'], redReason: 'tired' })]) {
      await assert.rejects(run(baseArgs({ review: 'gate' }), { workers: [red(), second] }), /redReason/)
    }
  },

  async 'a redReason on a return that is not gate-red is unusable — catches a reason the workflow would silently drop'() {
    const withReason = workerReturn({ redReason: 'no-progress' })
    const { workerCalls } = await run(baseArgs({ review: 'gate' }), { workers: [withReason, workerReturn()] })
    assert.equal(workerCalls.length, 2)
    assert.match(workerCalls[1].prompt, /redReason/)
    await assert.rejects(run(baseArgs({ review: 'gate' }), { workers: [red(), withReason] }), /redReason/)
  },

  async 'gate-red with no-progress goes to the fix pass with its reason, and the final return carries it in notes — catches the reason lost or a key check-return rejects'() {
    const { workerCalls, result } = await run(baseArgs({ review: 'gate' }), {
      workers: [
        red({ notes: 'swift.test-failure survived 3 fixes' }),
        red({ commits: ['77aa001'], redReason: 'environment', notes: 'simulator runtime missing' }),
      ],
    })
    assert.equal(workerCalls.length, 2)
    assert.match(workerCalls[1].prompt, /no-progress/, 'the fix pass is not told why the first attempt stopped')
    assert.equal(result.outcome, 'gate-red')
    assert.deepEqual(Object.keys(result).sort(), [...TASK_RETURN_KEYS].sort(), 'redReason leaked into the TaskReturn')
    assert.match(result.notes, /^simulator runtime missing\nredReason: environment$/)
    assertTaskReturn(result, 'gate')
  },

  async 'an unusable gate-red first attempt still hands its commits and surface commit to the final return — catches first-attempt commits dropped from what check-return sees'() {
    const { result } = await run(baseArgs({ review: 'gate' }), {
      workers: [bareRed({ surfaceCommit: '3f2a91c' }), workerReturn({ commits: ['77aa001'] })],
    })
    assert.deepEqual(result.commits, ['3f2a91c', '77aa001'])
    assert.equal(result.surfaceCommit, '3f2a91c')
  },

  async 'full review runs architecture and test-quality in parallel on the task commits — catches a serial or missing reviewer'() {
    const { result, reviewerCalls, maxReviewersInFlight, workerCalls } = await run(baseArgs())
    assert.deepEqual(reviewerCalls.map(c => REVIEWERS[c.opts.agentType]).sort(), ['architecture', 'test-quality'])
    assert.equal(maxReviewersInFlight, 2)
    for (const { prompt } of reviewerCalls) {
      assert.ok(prompt.includes('3f2a91c'), 'reviewer prompt lacks the commit')
      assert.ok(prompt.includes(baseArgs().worktree), 'reviewer prompt lacks the worktree')
    }
    assert.equal(workerCalls.length, 1)
    assert.equal(result.outcome, 'ready-to-merge')
    assertTaskReturn(result, 'full')
  },

  async 'a red gate after the fix pass returns gate-red with exactly 2 worker calls — catches a second fix pass'() {
    const gateMode = await run(baseArgs({ review: 'gate' }), { workers: [red(), red({ commits: ['3f2a91c', '77aa001'] })] })
    assert.equal(gateMode.workerCalls.length, 2)
    assert.equal(gateMode.result.outcome, 'gate-red')
    assertTaskReturn(gateMode.result, 'gate')

    const fullMode = await run(baseArgs(), {
      workers: [workerReturn(), red()],
      reviews: { architecture: [{ findings: [finding()] }] },
    })
    assert.equal(fullMode.workerCalls.length, 2)
    assert.equal(fullMode.reviewerCalls.length, 2, 'no review of a red fix pass')
    assert.equal(fullMode.result.outcome, 'gate-red')
    assertTaskReturn(fullMode.result, 'full')
  },

  async 'the fix pass is a fresh worker handed the red gate run — catches a fixer that never learns why it runs'() {
    const { workerCalls, result } = await run(baseArgs({ review: 'gate' }), {
      workers: [red(), workerReturn({ commits: ['77aa001'], gate: { tier: 'fast', verdict: 'GREEN', runId: 'g2' } })],
    })
    assert.equal(workerCalls.length, 2)
    assert.ok(workerCalls[1].prompt.includes('20260926T150000Z-0000beef'), 'fix prompt lacks the red run id')
    assert.ok(!workerCalls[0].prompt.includes('20260926T150000Z-0000beef'))
    assert.equal(workerCalls[1].opts.agentType, WORKER)
    assert.equal(result.outcome, 'ready-to-merge')
    assert.deepEqual(result.commits, ['3f2a91c', '77aa001'], 'both attempts land on the branch')
    assert.equal(result.gate.runId, 'g2')
  },

  async 'a fix pass that names no surface commit keeps the first attempt\'s — catches a proof base lost between attempts'() {
    const kept = await run(baseArgs({ review: 'gate' }), {
      workers: [red({ surfaceCommit: '1a2b3c4' }), workerReturn({ commits: ['77aa001'] })],
    })
    const replaced = await run(baseArgs({ review: 'gate' }), {
      workers: [red({ surfaceCommit: '1a2b3c4' }), workerReturn({ commits: ['77aa001'], surfaceCommit: '99ff000' })],
    })
    assert.equal(kept.result.surfaceCommit, '1a2b3c4')
    assert.equal(replaced.result.surfaceCommit, '99ff000')
  },

  async 'a blocking review finding gets one fix pass and a re-review — catches review findings never reaching a worker'() {
    const blocking = finding()
    const { workerCalls, reviewerCalls, result } = await run(baseArgs(), {
      workers: [workerReturn(), workerReturn({ commits: ['77aa001'] })],
      reviews: { architecture: [{ findings: [blocking] }, { findings: [] }] },
    })
    assert.equal(workerCalls.length, 2)
    assert.ok(workerCalls[1].prompt.includes(blocking.failure_scenario), 'fix prompt lacks the finding')
    assert.equal(reviewerCalls.length, 4)
    assert.equal(result.outcome, 'ready-to-merge')
    assert.deepEqual(result.review.findings, [])
    assertTaskReturn(result, 'full')
  },

  async 'blocking findings after the fix pass return review-blocked and no third worker — catches an unbounded fix loop'() {
    const { workerCalls, result } = await run(baseArgs(), {
      workers: [workerReturn(), workerReturn({ commits: ['77aa001'] })],
      reviews: { 'test-quality': [{ findings: [finding()] }, { findings: [finding({ severity: 'blocker' })] }] },
    })
    assert.equal(workerCalls.length, 2)
    assert.equal(result.outcome, 'review-blocked')
    assert.equal(result.review.findings.length, 1)
    assert.equal(result.review.findings[0].severity, 'blocker')
    assertTaskReturn(result, 'full')
  },

  async 'minor and nit findings pass without a fix pass — catches taste blocking a merge'() {
    const { workerCalls, result } = await run(baseArgs(), {
      reviews: { architecture: [{ findings: [finding({ severity: 'minor' }), finding({ severity: 'nit', line: 7 })] }] },
    })
    assert.equal(workerCalls.length, 1)
    assert.equal(result.outcome, 'ready-to-merge')
    assert.equal(result.review.findings.length, 2)
    assertTaskReturn(result, 'full')
  },

  async 'each reviewer\'s findings go to an independent verifier, which never reviews for discovery — catches the verifier used against its no-new-findings contract'() {
    const found = finding()
    const { reviewerCalls, verifyCalls } = await run(baseArgs(), {
      workers: [workerReturn(), workerReturn({ commits: ['77aa001'] })],
      reviews: { architecture: [{ findings: [{ ...found, verified: true, verification_note: 'I traced it' }] }] },
    })
    assert.ok(reviewerCalls.every(c => c.opts.agentType !== VERIFIER), 'a discovery reviewer runs as the verifier')
    assert.deepEqual(verifyCalls.map(c => c.opts.label), ['verify:architecture'], 'one verify call per reviewer with findings')
    const [sent] = findingsInPrompt(verifyCalls[0].prompt)
    assert.equal(sent.failure_scenario, found.failure_scenario)
    assert.ok(!('verified' in sent) && !('verification_note' in sent), "the verifier sees the reviewer's verdict")
    assert.ok(verifyCalls[0].prompt.includes(baseArgs().worktree), 'the verify prompt lacks the worktree')
    assert.ok(verifyCalls[0].prompt.includes(baseArgs().contextPack), 'the verify prompt lacks the context pack')
  },

  async 'an unverified blocker or major neither starts a fix pass nor blocks the task — catches a finding nobody reproduced blocking a merge'() {
    const refute = findings => ({ findings: findings.map(f => ({ ...f, verified: false, verification_note: 'a guard prevents it' })) })
    const first = await run(baseArgs(), {
      reviews: { architecture: [{ findings: [{ ...finding(), verified: true }] }], 'test-quality': [{ findings: [finding({ severity: 'blocker', line: 9 })] }] },
      verifies: { architecture: [refute], 'test-quality': [refute] },
    })
    assert.equal(first.workerCalls.length, 1, 'an unverified finding started a fix pass')
    assert.equal(first.result.outcome, 'ready-to-merge')
    assert.deepEqual(first.result.review.findings.map(f => f.verified), [false, false], 'unverified findings stay visible, marked')
    assertTaskReturn(first.result, 'full')

    const afterFix = await run(baseArgs(), {
      workers: [workerReturn(), workerReturn({ commits: ['77aa001'] })],
      reviews: { architecture: [{ findings: [finding()] }, { findings: [finding({ severity: 'blocker' })] }] },
      verifies: { architecture: [undefined, refute] },
    })
    assert.equal(afterFix.workerCalls.length, 2)
    assert.equal(afterFix.result.outcome, 'ready-to-merge', 'an unverified blocker after the fix pass blocked the task')
    assertTaskReturn(afterFix.result, 'full')
  },

  async 'a verifier that reorders its entries judges each finding by its own entry — catches a refuted finding blocking in a verified one\'s place'() {
    const real = finding({ title: 'second page replaces the first', line: 42 })
    const invented = finding({ title: 'page size ignored', category: 'page-size', line: 17, severity: 'blocker' })
    const { workerCalls, result } = await run(baseArgs(), {
      workers: [workerReturn(), workerReturn({ commits: ['77aa001'] })],
      reviews: { architecture: [{ findings: [real, invented] }] },
      verifies: {
        architecture: [findings => ({
          findings: [...findings].reverse().map(f => ({ ...f, verified: f.title === real.title, verification_note: 'n' })),
        })],
      },
    })
    assert.equal(workerCalls.length, 2)
    const handed = workerCalls[1].prompt
    assert.ok(handed.includes(real.failure_scenario) && handed.includes(real.title), 'the verified finding never reached the fix pass')
    assert.ok(!handed.includes(invented.title), 'the refuted finding reached the fix pass')
  },

  async 'the verifier may lower a severity but never raise one, and lowers a standards violation only with a reason — catches the verifier rewriting what a reviewer claimed'() {
    const violation = finding({ kind: 'standards-violation', rule: 'D7', category: 'logic-in-live-client', line: 30, title: 'filtering in the Live client' })
    const { workerCalls, result } = await run(baseArgs(), {
      workers: [workerReturn(), workerReturn({ commits: ['77aa001'] })],
      reviews: { architecture: [{ findings: [finding({ severity: 'minor' }), violation] }] },
      verifies: {
        architecture: [findings => ({
          findings: [
            { ...findings[0], severity: 'blocker', verified: true, verification_note: 'n' },
            { ...findings[1], severity: 'nit', verified: true, verification_note: 'n' },
          ],
        })],
      },
    })
    assert.equal(workerCalls.length, 2, 'the unexplained downgrade let a verified violation through')
    assert.ok(!workerCalls[1].prompt.includes('second page replaces the first'), 'the raised minor reached the fix pass')
    assert.ok(workerCalls[1].prompt.includes('filtering in the Live client'))
    assert.ok(workerCalls[1].prompt.includes('"severity": "major"'), 'the violation reached the fix pass at a lowered severity')
    assert.equal(result.outcome, 'ready-to-merge')
  },

  async 'a dead verifier, or one that returns no entry for a finding, blocks the task without a fix pass — catches unverified findings passing as reviewed'() {
    for (const verify of [null, () => { throw new Error('verifier died') }, () => ({ findings: [] })]) {
      const { workerCalls, result, logs } = await run(baseArgs(), {
        reviews: { 'test-quality': [{ findings: [finding({ severity: 'minor' })] }] },
        verifies: { 'test-quality': [verify === null ? () => null : verify] },
      })
      assert.equal(workerCalls.length, 1)
      assert.equal(result.outcome, 'review-blocked')
      assert.match(result.notes, /test-quality/)
      assert.ok(logs.some(l => /verif/.test(l)), logs.join('\n'))
      assertTaskReturn(result, 'full')
    }
  },

  async 'design-conflict returns at once with no reviewer and no fix — catches a conflict hidden behind a fix attempt'() {
    const { workerCalls, reviewerCalls, result } = await run(baseArgs(), {
      workers: [workerReturn({ outcome: 'design-conflict', commits: [], gate: null, designConflict: conflict })],
    })
    assert.equal(workerCalls.length, 1)
    assert.equal(reviewerCalls.length, 0)
    assert.equal(result.outcome, 'design-conflict')
    assert.deepEqual(result.designConflict, conflict)
    assert.equal(result.gate, null)
    assertTaskReturn(result, 'full')
  },

  async 'a failed reviewer blocks the task without a fix pass — catches an unreviewed task returned as ready-to-merge'() {
    const { workerCalls, result, logs } = await run(baseArgs(), { reviews: { architecture: [null] } })
    assert.equal(workerCalls.length, 1)
    assert.equal(result.outcome, 'review-blocked')
    assert.match(result.notes, /architecture/)
    assert.ok(logs.some(l => /architecture/.test(l)))
    assertTaskReturn(result, 'full')
  },

  async 'a malformed reviewer finding counts as a failed reviewer — catches agent output check-return cannot decode'() {
    const { result } = await run(baseArgs(), {
      reviews: { 'test-quality': [{ findings: [finding({ severity: 'critical' })] }] },
    })
    assert.equal(result.outcome, 'review-blocked')
    assert.deepEqual(result.review.findings, [])
    assertTaskReturn(result, 'full')
  },

  async 'a dead or off-contract first worker gets the fix pass; a second one throws — catches a fabricated return'() {
    const revived = await run(baseArgs({ review: 'gate' }), { workers: [null, workerReturn()] })
    assert.equal(revived.workerCalls.length, 2)
    assert.equal(revived.result.outcome, 'ready-to-merge')
    await assert.rejects(run(baseArgs({ review: 'gate' }), { workers: [null, null] }), /build-worker/)
    await assert.rejects(
      run(baseArgs({ review: 'gate' }), { workers: [workerReturn({ task: 'other' }), workerReturn({ outcome: 'review-blocked' })] }),
      /build-worker/,
    )
  },

  async 'review is never null in any path — catches build-return.review-missing'() {
    const scenarios = [
      [baseArgs({ review: 'gate' }), {}],
      [baseArgs({ review: 'gate' }), { workers: [red(), red()] }],
      [baseArgs({ review: 'gate' }), { workers: [workerReturn({ outcome: 'design-conflict', gate: null, designConflict: conflict })] }],
      [baseArgs(), {}],
      [baseArgs(), { workers: [red(), red()] }],
      [baseArgs(), { workers: [red(), workerReturn({ outcome: 'design-conflict', gate: null, designConflict: conflict })] }],
      [baseArgs(), { workers: [workerReturn(), workerReturn()], reviews: { architecture: [{ findings: [finding()] }, { findings: [finding()] }] } }],
      [baseArgs(), { reviews: { architecture: [null] } }],
    ]
    for (const [args, behave] of scenarios) {
      const { result } = await run(args, behave)
      assertTaskReturn(result, args.review)
    }
  },

  async 'reviewers narrows the review panel — catches the reviewers arg being ignored'() {
    const { reviewerCalls } = await run(baseArgs({ reviewers: ['test-quality'] }))
    assert.deepEqual(reviewerCalls.map(c => REVIEWERS[c.opts.agentType]), ['test-quality'])
  },

  async 'a missing or malformed planSurface arg throws build-task before any agent runs — catches a skill that forgets to pass the plan surface'() {
    const { planSurface, ...withoutSurface } = baseArgs()
    await assert.rejects(script(withoutSurface, async () => {}, () => {}), /^Error: build-task: planSurface is required/)
    for (const args of [withoutSurface, baseArgs({ planSurface: '' }), baseArgs({ planSurface: 42 }),
      baseArgs({ planSurface: 'HEAD' }), baseArgs({ planSurface: ['1a2b3c4d'] }), baseArgs({ planSurface: undefined })]) {
      const calls = []
      await assert.rejects(
        script(args, async (p, o) => calls.push(o), () => {}),
        /^Error: build-task: planSurface /,
        JSON.stringify(args),
      )
      assert.equal(calls.length, 0)
    }
  },

  async 'with a plan surface every worker prompt proves at it and forbids a surface of its own — catches a worker writing a second surface or proving at the wrong base'() {
    const sha = '1a2b3c4d5e6f'
    for (const taskProof of ['per-task', 'final']) {
      const { workerCalls } = await run(baseArgs({ review: 'gate', taskProof, planSurface: sha }), {
        workers: [red(), workerReturn({ commits: ['77aa001'] })],
      })
      assert.equal(workerCalls.length, 2)
      for (const { prompt } of workerCalls) {
        const gate = `--impact --coverage --app-build --proof-base ${sha}`
        assert.ok(prompt.includes(gate), `a ${taskProof} worker prompt lacks ${gate}:\n${prompt}`)
        assert.ok(prompt.includes(`Plan surface: ${sha}`), `a ${taskProof} worker prompt does not name the plan surface`)
        assert.ok(prompt.includes('write no surface commit of your own'), 'the prompt does not forbid a new surface')
        assert.ok(prompt.includes('swiftgate surface-check <stub sha>'), 'the prompt does not check a stub with surface-check')
        assert.ok(prompt.includes('return its sha as surfaceCommit'), 'the prompt does not return the stub as surfaceCommit')
        assert.ok(!prompt.includes('<surface commit> when the task adds API'), 'the prompt still asks for a surface of its own')
      }
    }
  },

  async 'with a null plan surface the worker prompt and schema are today\'s, byte for byte — catches a design plan\'s workers told about a plan surface'() {
    const head =
      'Build this task and return one TaskReturn JSON object with "review": null.\n\n' +
      'Task: catalog-list-reducer (plan catalog).\n' +
      'Worktree: /work/app-catalog-catalog-list-reducer, branch catalog/catalog-list-reducer, already checked out.\n' +
      'Write set: Sources/CatalogCore/CatalogList.swift, Tests/CatalogCoreTests/CatalogListTests.swift.\n'
    const tail =
      'Tests to turn green: test-catalog-list-loads-first-page.\n' +
      'Context pack: /work/app/.harness/context-pack/worker-catalog-list-reducer.md. Read it first.'
    const expected = {
      'per-task':
        head + 'Task proof: per-task.\n' +
        'Task gate: swiftgate check --tier fast --base main --prove --mutate --impact --coverage --app-build, ' +
        'plus --proof-base <surface commit> when the task adds API.\n' + tail,
      final:
        head + 'Task proof: final.\n' +
        'Task gate: swiftgate check --tier fast --base main --impact --coverage --app-build, ' +
        "plus --proof-base <surface commit> when the task adds API. The build's final ready gate proves and mutates every task at once.\n" +
        tail,
    }
    for (const [taskProof, prompt] of Object.entries(expected)) {
      const { workerCalls } = await run(baseArgs({ review: 'gate', taskProof }))
      assert.equal(workerCalls[0].prompt, prompt)
      const section = workerCalls[0].opts.schema.properties.designConflict.properties.section
      assert.deepEqual(section, { type: 'string', description: 'the design section anchor, e.g. decision' })
    }
  },

  async 'with a plan surface a design conflict must name a spec page section — catches a conflict citing a design section the plan does not have'() {
    const args = baseArgs({ planSurface: '1a2b3c4d' })
    const { workerCalls, result } = await run(args, {
      workers: [workerReturn({ outcome: 'design-conflict', commits: [], gate: null, designConflict: { ...conflict, section: 'surface', ids: ['slice-2-lists-saved-items'] } })],
    })
    assert.match(workerCalls[0].prompt, /spec page section: `slices`, `surface` or `modules`/)
    assert.deepEqual(workerCalls[0].opts.schema.properties.designConflict.properties.section.enum, ['slices', 'surface', 'modules'])
    assert.equal(result.outcome, 'design-conflict')
    assert.equal(result.designConflict.section, 'surface')

    const refused = await run(args, {
      workers: [workerReturn({ outcome: 'design-conflict', commits: [], gate: null, designConflict: conflict }), workerReturn({ commits: ['77aa001'] })],
    })
    assert.equal(refused.workerCalls.length, 2, 'a design-section conflict on a spec page plan went back as usable')
    assert.match(refused.workerCalls[1].prompt, /unusable.*spec page section/)
    await assert.rejects(
      run(args, { workers: [red(), workerReturn({ outcome: 'design-conflict', commits: [], gate: null, designConflict: conflict })] }),
      /spec page section/,
    )
  },

  async 'invalid args fail before any agent runs — catches a worker launched into the wrong branch or mode'() {
    const cases = [
      undefined,
      baseArgs({ budget: 3 }),
      baseArgs({ review: 'light' }),
      baseArgs({ model: 'haiku' }),
      baseArgs({ taskGate: 'slow' }),
      baseArgs({ branch: 'main' }),
      baseArgs({ worktree: 'relative/path' }),
      baseArgs({ writeSet: [] }),
      baseArgs({ reviewers: ['concurrency'] }),
      baseArgs({ reviewers: [] }),
      baseArgs({ review: 'gate', reviewers: ['architecture'] }),
      baseArgs({ reviewers: ['verifier'] }),
      baseArgs({ taskProof: 'sometimes' }),
      baseArgs({ taskProof: undefined }),
    ]
    for (const args of cases) {
      const calls = []
      await assert.rejects(
        script(args, async (p, o) => calls.push(o), () => {}),
        /build-task/,
        JSON.stringify(args),
      )
      assert.equal(calls.length, 0)
    }
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
