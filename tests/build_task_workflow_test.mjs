// Runs workflows/build-task.js against stubbed build-worker and reviewer agents.
// Run: node tests/build_task_workflow_test.mjs
// Regressions caught: a gate-only preset still paying for reviewers; a second fix pass, or a fix
// pass reusing the first worker instead of a fresh one; a design conflict reviewed or "fixed"
// instead of going straight back to the orchestrator; a return whose keys drift from `TaskReturn`,
// so `build check-return` rejects it; a `review: null` return, which check-return fails as
// `build-return.review-missing`; a `final` task-proof preset still paying for per-task prove and
// mutate, or a `per-task` one silently skipping them; the verifier run as a discovery reviewer; an
// unverified blocker or major starting a fix pass or blocking the task; a reordered verifier
// answer verifying the wrong finding; a verifier never told where the testing playbook lives, so
// a playbook-rule finding can never block.
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
// The agent that runs `swiftgate judge diff-risk` for classified review, told apart from any other
// plain agent by its label.
const CLASSIFIER = 'general-purpose'
const CLASSIFIER_LABEL = /^diff-risk:/
// The only agents a task may spawn: the stages, each of which runs its own span calls.
const STAGE_AGENTS = [WORKER, VERIFIER, ...Object.keys(REVIEWERS)]
const BUILD_RUN = '20261003T101500Z-9a1b2c3d'
// The plugin under test, which every launch names, and the shim inside it every stage runs.
const PLUGIN_ROOT = '/plugins/swift-harness'
const SG = `${PLUGIN_ROOT}/bin/swiftgate`
// A `swiftgate <subcommand>` not reached through a path: the shell resolves it through PATH, which
// may hold an older installed plugin whose gate code and run store aren't the ones under test.
const BARE_SWIFTGATE = /(?<![\w/.-])swiftgate\s+[a-z][a-z-]*/g

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
  buildRun: BUILD_RUN,
  pluginRoot: PLUGIN_ROOT,
  ...extra,
})

// A task in a brownfield clone: a slice gate, the pinned model, prove-only proof, classified
// review, and the worktree's state root under its git dir.
const brownfieldArgs = (extra = {}) => {
  const args = {
    task: 'search-task',
    plan: 'search',
    worktree: '/work/search-task',
    branch: 'search/search-task',
    writeSet: ['Core/src/search.rs'],
    taskGate: 'slice',
    tests: [],
    contextPack: '/work/repo/.git/worktrees/search-task/swift-harness/context-pack/worker-search-task.md',
    model: 'claude-sonnet-5-5',
    review: 'classified',
    taskProof: 'prove',
    planSurface: null,
    stateRoot: '/work/repo/.git/worktrees/search-task/swift-harness',
    base: 'search/plan',
    buildRun: BUILD_RUN,
    pluginRoot: PLUGIN_ROOT,
    ...extra,
  }
  for (const key of Object.keys(args)) if (args[key] === undefined) delete args[key]
  return args
}

const brownfieldReturn = (overrides = {}) =>
  workerReturn({ task: 'search-task', gate: { tier: 'slice', verdict: 'GREEN', runId: '20261004T141801Z-79b9bebf' }, testsAdded: [], ...overrides })

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
// `diffRisk` is what the diff-risk agent returns (a function gets the prompt, an Error is thrown);
// by default the command printed no level because the clone has no judge.
// `swiftgate` is the fake `swiftgate events span` every stage agent runs its own span lines
// against; a stage's return gets the `span` its start printed unless the scripted return sets one.
const noJudge = { level: null, by: null, path: null, glob: null, reason: "the clone's config has no [judge] section", exitStatus: 1 }
// What the diff-risk agent returns for a level the judge rated.
const judged = level => ({ level, by: 'judge', path: null, glob: null, reason: null, exitStatus: 0 })
async function run(args, { workers = [workerReturn()], reviews = {}, verifies = {}, swiftgate = fakeSwiftgate(), diffRisk = noJudge } = {}) {
  const calls = []
  let inFlight = 0
  let maxReviewersInFlight = 0
  const perReviewer = {}
  const perVerifier = {}
  const stage = async (prompt, opts) => {
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
      return typeof next === 'function' ? next(findings, prompt) : structuredClone(next)
    }
    const reviewer = REVIEWERS[opts.agentType]
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
  const agent = async (prompt, opts) => {
    calls.push({ prompt, opts })
    if (opts.agentType === CLASSIFIER) {
      assert.match(opts.label ?? '', CLASSIFIER_LABEL, `a plain agent ran that is not the diff-risk classifier: ${opts.label}`)
      assert.ok(!prompt.includes('events span'), 'the diff-risk classifier was handed a span call')
      if (diffRisk instanceof Error) throw diffRisk
      return typeof diffRisk === 'function' ? diffRisk(prompt) : structuredClone(diffRisk)
    }
    assert.ok(STAGE_AGENTS.includes(opts.agentType), `an agent that is not a stage ran: ${opts.agentType} (${opts.label})`)
    const span = swiftgate.open(prompt)
    return swiftgate.close(prompt, span, opts.agentType, await stage(prompt, opts))
  }
  const logs = []
  const result = await script(args, agent, message => logs.push(message))
  const workerCalls = calls.filter(c => c.opts.agentType === WORKER)
  const reviewerCalls = calls.filter(c => ![WORKER, VERIFIER, CLASSIFIER].includes(c.opts.agentType))
  const verifyCalls = calls.filter(c => c.opts.agentType === VERIFIER)
  const classifierCalls = calls.filter(c => c.opts.agentType === CLASSIFIER)
  return { result, calls, workerCalls, reviewerCalls, verifyCalls, classifierCalls, maxReviewersInFlight, logs }
}

// A stage prompt's 2 span lines: the start it runs first and the end it runs last, with
// `<span>` and `<outcome>` for the agent to fill.
const SPAN_START_LINE = /^1\. Before anything else, run `([^`]+)`/m
const SPAN_END_LINE = /^2\. Last, [^`]*run `([^`]+)`/m
const spanLines = prompt => ({ start: SPAN_START_LINE.exec(prompt)?.[1], end: SPAN_END_LINE.exec(prompt)?.[1] })
const commandWords = command =>
  (command.slice(command.indexOf('events span ')).match(/'[^']*'|\S+/g) ?? []).map(w => w.replace(/^'|'$/g, ''))
const flagIn = (words, name) => (words.includes(name) ? words[words.indexOf(name) + 1] : undefined)

// The outcome a stage agent ends its span with, by the rule its prompt states for its kind.
function stageOutcome(agentType, value) {
  if (agentType === WORKER) return { 'ready-to-merge': 'ok', 'gate-red': 'red', 'design-conflict': 'abandoned' }[value.outcome] ?? 'red'
  if (agentType === VERIFIER) {
    const blocks = (value.findings ?? []).some(f => f.verified === true && ['blocker', 'major'].includes(f.severity))
    return blocks ? 'red' : 'ok'
  }
  return 'ok'
}

// A fake `swiftgate events span` that stage agents run their own span lines against. It answers
// each command as the real one would and records every start and end in call order. `exit(n,
// command)` forces the n-th command's exit status; `off` answers every start as telemetry-off does.
function fakeSwiftgate({ exit = () => 0, off = false } = {}) {
  const events = []
  const commands = []
  let next = 0
  let n = 0
  const exec = command => {
    commands.push(command)
    n++
    const forced = exit(n, command)
    if (forced) return { exitStatus: forced, stdout: '' }
    const words = commandWords(command)
    if (words[2] === 'start') {
      if (off) return { exitStatus: 0, stdout: '' }
      const id = (++next).toString(16).padStart(16, '0')
      events.push({ kind: 'start', id, phase: flagIn(words, '--phase'), buildRun: flagIn(words, '--build-run'), task: flagIn(words, '--task'), role: flagIn(words, '--role'), parent: flagIn(words, '--parent') })
      return { exitStatus: 0, stdout: id }
    }
    assert.equal(words[2], 'end', `unexpected span command ${command}`)
    const id = words[3]
    if (!events.some(e => e.kind === 'start' && e.id === id) || events.some(e => e.kind === 'end' && e.id === id)) {
      return { exitStatus: 1, stdout: '' }
    }
    events.push({ kind: 'end', id, outcome: flagIn(words, '--outcome') })
    return { exitStatus: 0, stdout: `events span end: recorded ${flagIn(words, '--outcome')} for span ${id}` }
  }
  // Step 1 of the prompt: the span id, or null when the start printed nothing or failed.
  const open = prompt => {
    const { start } = spanLines(prompt)
    if (!start) return null
    const r = exec(start)
    return r.exitStatus === 0 && r.stdout ? r.stdout : null
  }
  // Step 2: an agent that returned an object ends its span by its rule and returns the id.
  const close = (prompt, span, agentType, value) => {
    if (!value || typeof value !== 'object' || Array.isArray(value)) return value
    if (Object.prototype.hasOwnProperty.call(value, 'span')) return value
    const { end } = spanLines(prompt)
    if (span !== null && end) exec(end.replace('<span>', span).replace('<outcome>', stageOutcome(agentType, value)))
    return { ...value, span }
  }
  const starts = () => events.filter(e => e.kind === 'start')
  const endOf = id => events.find(e => e.kind === 'end' && e.id === id)
  return { open, close, events, commands, starts, endOf }
}

// Each start names the task and build run, its parent ended before it started, and it ended itself.
function assertSpanChain(sg, buildRun, task) {
  for (const start of sg.starts()) {
    assert.equal(start.task, task, `span ${start.phase} names task ${start.task}`)
    assert.equal(start.buildRun, buildRun)
    assert.ok(sg.endOf(start.id), `span ${start.phase} ${start.id} never ended`)
    if (start.parent === undefined) continue
    const parentEnd = sg.events.indexOf(sg.endOf(start.parent))
    assert.ok(parentEnd >= 0 && parentEnd < sg.events.indexOf(start), `span ${start.phase} started before its parent ended`)
  }
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
  async 'a task run records its stages in order, each parented to the one before — catches stages started flat'() {
    const sg = fakeSwiftgate()
    const { result } = await run(baseArgs(), {
      workers: [workerReturn(), workerReturn({ commits: ['77aa001'] })],
      reviews: { architecture: [{ findings: [finding()] }] },
      swiftgate: sg,
    })
    assert.equal(result.outcome, 'ready-to-merge')
    const shape = sg.starts().map(s => {
      const parent = sg.starts().find(p => p.id === s.parent)
      return `${s.phase}:${s.role}<${parent ? parent.phase : '-'}=${sg.endOf(s.id).outcome}`
    })
    assert.deepEqual(shape.sort(), [
      'fix:build-worker<verify=ok',
      'review:review<fix=ok',
      'review:review<fix=ok',
      'review:review<worker=ok',
      'review:review<worker=ok',
      'verify:review<review=red',
      'worker:build-worker<-=ok',
    ].sort())
    assertSpanChain(sg, BUILD_RUN, 'catalog-list-reducer')
    const fix = sg.starts().find(s => s.phase === 'fix')
    assert.equal(sg.starts().find(s => s.id === fix.parent).phase, 'verify', 'the fix pass is not parented to the verify that blocked')
  },

  async 'a red gate parents the fix pass to the worker and ends the worker red — catches a fix span hung off nothing'() {
    const sg = fakeSwiftgate()
    const { result } = await run(baseArgs({ review: 'gate' }), { workers: [red(), workerReturn()], swiftgate: sg })
    assert.equal(result.outcome, 'ready-to-merge')
    const [worker, fix, ...rest] = sg.starts()
    assert.deepEqual([worker.phase, fix.phase, rest.length], ['worker', 'fix', 0])
    assert.equal(fix.parent, worker.id)
    assert.equal(sg.endOf(worker.id).outcome, 'red')
    assert.equal(sg.endOf(fix.id).outcome, 'ok')
    assertSpanChain(sg, BUILD_RUN, 'catalog-list-reducer')
  },

  async 'no worker, review, verify, fix or diff-risk prompt names a bare swiftgate command, in either profile, with or without a plan surface — catches a stage running the swiftgate on PATH instead of the plugin under test'() {
    // The pattern itself: a bare command matches, the shim and a swiftgate:allow comment don't.
    assert.deepEqual(
      'run `swiftgate check --tier fast`, then swiftgate surface-check x; /p/bin/swiftgate check; // swiftgate:allow rule'.match(BARE_SWIFTGATE),
      ['swiftgate check', 'swiftgate surface-check'],
    )
    const blocking = { architecture: [{ findings: [finding()] }] }
    const runs = [
      await run(baseArgs(), { workers: [red(), workerReturn({ commits: ['77aa001'] })] }),
      await run(baseArgs({ planSurface: '1a2b3c4d' }), { workers: [workerReturn(), workerReturn({ commits: ['77aa001'] })], reviews: blocking }),
      await run(baseArgs({ taskProof: 'final' }), { workers: [workerReturn(), workerReturn({ commits: ['77aa001'] })], reviews: blocking }),
      await run(brownfieldArgs(), {
        workers: [brownfieldReturn({ outcome: 'gate-red', gate: { tier: 'slice', verdict: 'RED', runId: '20261004T141540Z-be184a1a' }, redReason: 'no-progress' }), brownfieldReturn()],
        diffRisk: judged('high'),
        reviews: { architecture: [{ findings: [finding({ file: 'Core/src/search.rs' })] }] },
      }),
    ]
    const labels = new Set()
    const bare = []
    for (const { calls } of runs) {
      for (const { prompt, opts } of calls) {
        labels.add(opts.label.replace(/:.*/, ''))
        for (const command of prompt.match(BARE_SWIFTGATE) ?? []) bare.push(`${opts.label}: ${command}`)
      }
    }
    assert.deepEqual([...labels].sort(), ['build', 'diff-risk', 'fix', 'review', 'verify'])
    assert.deepEqual(bare, [])
  },

  async 'a launch without pluginRoot throws naming it before any agent runs, in either profile — catches stages falling back to the swiftgate on PATH'() {
    for (const make of [baseArgs, brownfieldArgs]) {
      const { pluginRoot, ...args } = make()
      const calls = []
      await assert.rejects(
        script(args, async (p, o) => calls.push(o), () => {}),
        /build-task: pluginRoot is required/,
      )
      assert.equal(calls.length, 0)
    }
  },

  async 'every worker, review, verify and fix prompt opens its own span first and closes it last — catches a stage prompt missing its span start or end'() {
    const { calls } = await run(baseArgs({ pluginRoot: '/plugins/swift-harness' }), {
      workers: [workerReturn(), workerReturn({ commits: ['77aa001'] })],
      reviews: { architecture: [{ findings: [finding()] }] },
    })
    const seen = new Set()
    const stage = c => (c.opts.agentType === WORKER ? (c.opts.label.startsWith('fix:') ? 'fix' : 'worker') : c.opts.agentType === VERIFIER ? 'verify' : 'review')
    for (const c of calls) {
      const phase = stage(c)
      seen.add(phase)
      const { start, end } = spanLines(c.prompt)
      assert.ok(start, `${c.opts.label}: no span start line`)
      assert.ok(end, `${c.opts.label}: no span end line`)
      const words = commandWords(start)
      assert.ok(start.startsWith('/plugins/swift-harness/bin/swiftgate events span start'), `${c.opts.label}: ${start}`)
      assert.equal(flagIn(words, '--phase'), phase, c.opts.label)
      assert.equal(flagIn(words, '--build-run'), BUILD_RUN, c.opts.label)
      assert.equal(flagIn(words, '--task'), 'catalog-list-reducer', c.opts.label)
      assert.equal(flagIn(words, '--role'), phase === 'worker' || phase === 'fix' ? 'build-worker' : 'review', c.opts.label)
      assert.equal(end, '/plugins/swift-harness/bin/swiftgate events span end <span> --outcome <outcome>', c.opts.label)
      assert.match(c.prompt, /return it as "span"/, `${c.opts.label}: never says to return the span id`)
      assert.match(c.prompt, /Empty output means telemetry is off[^.]*: either way return "span": null and skip step 2/, `${c.opts.label}: no telemetry-off rule`)
      assert.match(c.prompt, /If it fails, go on: your return stays the same/, `${c.opts.label}: a failed end may change the return`)
      const rule = /where <outcome> is ([^.]*)\./.exec(c.prompt)?.[1] ?? ''
      if (phase === 'worker' || phase === 'fix') {
        assert.match(rule, /`ok` when you return ready-to-merge, `red` when you return gate-red, and `abandoned` when you return design-conflict/, `${c.opts.label}: ${rule}`)
      } else if (phase === 'verify') {
        assert.match(rule, /`red` when you return any finding verified true at severity blocker or major, else `ok`/, `${c.opts.label}: ${rule}`)
      } else assert.equal(rule, '`ok`', `${c.opts.label}: ${rule}`)
      assert.ok(c.opts.schema.required.includes('span'), `${c.opts.label}: the schema does not require "span"`)
    }
    assert.deepEqual([...seen].sort(), ['fix', 'review', 'verify', 'worker'])
  },

  async 'no agent runs only for a span: every agent is a stage or the diff-risk classifier — catches a helper agent spent per span call'() {
    const scenarios = [
      [baseArgs(), { workers: [workerReturn(), workerReturn({ commits: ['77aa001'] })], reviews: { architecture: [{ findings: [finding()] }] } }, 7],
      [baseArgs({ review: 'gate' }), { workers: [red(), workerReturn()] }, 2],
      [brownfieldArgs(), { workers: [brownfieldReturn()], diffRisk: judged('high') }, 4],
    ]
    for (const [args, behave, expected] of scenarios) {
      const { calls } = await run(args, behave)
      for (const c of calls) {
        assert.notEqual(c.opts.model, 'haiku', `a haiku agent ran: ${c.opts.label}`)
        assert.ok(!/^span:/.test(c.opts.label ?? ''), `a span agent ran: ${c.opts.label}`)
      }
      assert.equal(calls.length, expected, calls.map(c => c.opts.label).join(', '))
    }
  },

  async 'a stage that returns a malformed span id is logged and never names it to a later stage — catches agent text run as a shell word'() {
    const { result, reviewerCalls, logs } = await run(baseArgs(), { workers: [workerReturn({ span: 'x; rm -rf ~' })] })
    assert.equal(result.outcome, 'ready-to-merge')
    assert.ok(!Object.prototype.hasOwnProperty.call(result, 'span'), 'the span key reached the TaskReturn')
    for (const c of reviewerCalls) {
      assert.ok(!c.prompt.includes('rm -rf'), 'the bad span id reached a review prompt')
      assert.equal(flagIn(commandWords(spanLines(c.prompt).start), '--parent'), undefined)
    }
    assert.ok(logs.some(l => /span/.test(l) && /worker/.test(l) && l.includes('rm -rf')), `no log names the bad span id: ${logs.join(' | ')}`)
  },

  async 'a span call that exits 1 leaves the task outcome unchanged and is logged — catches telemetry failing a task'() {
    const behave = () => ({
      workers: [workerReturn(), workerReturn({ commits: ['77aa001'] })],
      reviews: { architecture: [{ findings: [finding()] }] },
    })
    const clean = await run(baseArgs(), behave())
    for (const exit of [() => 1, (n, command) => (command.includes(' end ') ? 1 : 0)]) {
      const sg = fakeSwiftgate({ exit })
      const failing = await run(baseArgs(), { ...behave(), swiftgate: sg })
      assert.deepEqual(failing.result, clean.result)
      assert.equal(failing.calls.length, clean.calls.length, 'a failed span call spawned another agent')
      assert.ok(sg.commands.length > 0, 'no span call ran')
    }
    const startsFail = await run(baseArgs(), { ...behave(), swiftgate: fakeSwiftgate({ exit: (n, command) => (command.includes(' start ') ? 1 : 0) }) })
    assert.ok(startsFail.logs.some(l => /span/.test(l) && /worker/.test(l)), `no log names the stage left without a span: ${startsFail.logs.join(' | ')}`)
  },

  async 'telemetry off runs no span end and spawns no extra agent — catches an end run on an id telemetry never printed'() {
    const sg = fakeSwiftgate({ off: true })
    const { result, calls } = await run(baseArgs({ review: 'gate' }), { swiftgate: sg })
    assert.equal(result.outcome, 'ready-to-merge')
    assert.equal(calls.length, 1)
    assert.deepEqual(sg.commands.map(c => commandWords(c)[2]), ['start'])
  },

  async 'a task started with no build run, or a malformed one, throws a named error before any agent — catches stage spans silently dropped'() {
    for (const buildRun of [undefined, '', 'x; rm -rf ~', 42, null]) {
      const calls = []
      const args = baseArgs({ buildRun })
      if (buildRun === undefined) delete args.buildRun
      await assert.rejects(script(args, async (p, o) => calls.push(o), () => {}), /^Error: build-task: buildRun /, JSON.stringify(buildRun))
      assert.equal(calls.length, 0)
    }
    const calls = []
    const missing = baseArgs()
    delete missing.buildRun
    await assert.rejects(script(missing, async (p, o) => calls.push(o), () => {}), /buildRun is required/)
  },

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
    const gate = `${SG} check --tier fast --base main --prove --mutate`
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
        assert.ok(prompt.includes(`${SG} check --tier fast --base main`), 'a final worker prompt lacks its task gate')
        assert.ok(prompt.includes('Task proof: final'), 'a final worker prompt does not name its proof mode')
      }
      const perTask = await run(baseArgs({ review: 'gate', taskProof: 'per-task' }), behave)
      assert.equal(perTask.workerCalls.length, behave.workers.length)
      for (const { prompt } of perTask.workerCalls) {
        assert.ok(prompt.includes(`${SG} check --tier fast --base main --prove --mutate`), 'a per-task worker prompt skips proof')
        assert.ok(prompt.includes('Task proof: per-task'), 'a per-task worker prompt does not name its proof mode')
      }
    }
  },

  async 'every worker prompt\'s task gate turns on impact, coverage and the app build under both task proofs — catches a task gate that passes what the merge gate then fails'() {
    const behave = { workers: [red(), workerReturn()] }
    for (const [taskProof, gate] of [
      ['per-task', `${SG} check --tier fast --base main --prove --mutate --impact --coverage --app-build`],
      ['final', `${SG} check --tier fast --base main --impact --coverage --app-build`],
    ]) {
      const { workerCalls } = await run(baseArgs({ review: 'gate', taskProof }), behave)
      assert.equal(workerCalls.length, 2)
      for (const { prompt } of workerCalls) {
        assert.ok(prompt.includes(gate), `a ${taskProof} worker prompt lacks ${gate}:\n${prompt}`)
      }
    }
  },

  async 'the worker schema requires exactly TaskReturn keys and its span, and the return drops the span — catches a schema drifting from the type check-return decodes'() {
    const { workerCalls, result } = await run(baseArgs({ review: 'gate' }))
    const { schema } = workerCalls[0].opts
    assert.equal(schema.type, 'object')
    assert.deepEqual([...schema.required].sort(), [...TASK_RETURN_KEYS, 'span'].sort())
    assert.deepEqual(Object.keys(schema.properties).sort(), [...TASK_RETURN_KEYS, 'redReason', 'span'].sort())
    assert.deepEqual(Object.keys(result).sort(), [...TASK_RETURN_KEYS].sort())
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

  async 'a commit sha, surface commit or gate run id out of its format is unusable at the worker stage and goes to the fix pass — catches a quoted sha that passes the stage and fails check-return'() {
    // The surfaceCommit a worker returned in the fourth memos trial, quotes and all.
    const quoted = '"7c3becaa"'
    const cases = [
      ['surfaceCommit', workerReturn({ surfaceCommit: quoted })],
      ['surfaceCommit', workerReturn({ surfaceCommit: '7C3BECAA' })],
      ['surfaceCommit', workerReturn({ surfaceCommit: 'HEAD~1' })],
      ['surfaceCommit', workerReturn({ surfaceCommit: '7c3bec' })],
      ['surfaceCommit', workerReturn({ surfaceCommit: 'a'.repeat(41) })],
      ['commits', workerReturn({ commits: [quoted] })],
      ['commits', workerReturn({ commits: ['3f2a91c', 'main'] })],
      ['gate', workerReturn({ gate: { tier: 'fast', verdict: 'GREEN', runId: '"20260926T141502Z-4c1eab90"' } })],
      ['gate', workerReturn({ gate: { tier: 'fast', verdict: 'GREEN', runId: '../20260926T141502Z-4c1eab90' } })],
    ]
    for (const [field, first] of cases) {
      const { workerCalls, result } = await run(baseArgs({ review: 'gate' }), { workers: [first, workerReturn({ commits: ['77aa001'] })] })
      assert.equal(workerCalls.length, 2, `${JSON.stringify(first[field])} passed the worker stage`)
      assert.match(workerCalls[1].prompt, /unusable/, 'the fix pass does not learn the return was unusable')
      assert.ok(workerCalls[1].prompt.includes(field), `the fix pass is not told ${field} was wrong`)
      assert.equal(result.surfaceCommit, null)
      assertTaskReturn(result, 'gate')
    }
    await assert.rejects(
      run(baseArgs({ review: 'gate' }), { workers: [red(), workerReturn({ commits: ['77aa001'], surfaceCommit: quoted })] }),
      /surfaceCommit/,
    )
    // A full 40-hex sha and a 7-hex short one both stand.
    for (const sha of ['7c3becaa', '0d989707f82c33f74bb852edd8965ec88fcf041b']) {
      const { workerCalls, result } = await run(baseArgs({ review: 'gate' }), { workers: [workerReturn({ commits: [sha], surfaceCommit: sha })] })
      assert.equal(workerCalls.length, 1, sha)
      assert.equal(result.surfaceCommit, sha)
    }
    const schema = (await run(baseArgs({ review: 'gate' }))).workerCalls[0].opts.schema
    const hex = new RegExp(schema.properties.surfaceCommit.pattern)
    assert.ok(hex.test('7c3becaa') && !hex.test(quoted), 'the schema leaves surfaceCommit unpatterned')
    assert.equal(schema.properties.commits.items.pattern, schema.properties.surfaceCommit.pattern)
    const runID = new RegExp(schema.properties.gate.properties.runId.pattern)
    assert.ok(runID.test('20261004T141801Z-79b9bebf') && !runID.test('r-green'), 'the schema leaves gate.runId unpatterned')
  },

  async 'every stage schema patterns its span id as 16 lowercase hex, so the runtime makes a stage retry a quoted one — catches the 3 span ids the fifth memos trial lost to quotes'() {
    // The span id the store worker stage returned in the fifth memos trial, quotes and all.
    const quoted = '"44b7bfe58637a914"'
    const { calls } = await run(baseArgs({ review: 'full' }), { reviews: { architecture: [{ findings: [finding({ severity: 'minor' })] }] } })
    const schemas = new Map(calls.filter(c => STAGE_AGENTS.includes(c.opts.agentType)).map(c => [c.opts.agentType, c.opts.schema]))
    assert.deepEqual([...schemas.keys()].sort(), [...STAGE_AGENTS].sort(), 'a stage never ran, so its schema went unchecked')
    for (const [agentType, schema] of schemas) {
      const span = schema.properties.span
      assert.ok(span.pattern, `${agentType}'s span is unpatterned`)
      const id = new RegExp(span.pattern)
      assert.ok(id.test('44b7bfe58637a914'), `${agentType} refuses a real span id`)
      for (const bad of [quoted, '44B7BFE58637A914', '44b7bfe58637a91', `${'44b7bfe58637a914'}0`]) {
        assert.ok(!id.test(bad), `${agentType} takes ${bad} as a span id`)
      }
      assert.deepEqual(span.type, ['string', 'null'], `${agentType} no longer takes a null span`)
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
      workers: [red(), workerReturn({ commits: ['77aa001'], gate: { tier: 'fast', verdict: 'GREEN', runId: '20260926T151000Z-000000a2' } })],
    })
    assert.equal(workerCalls.length, 2)
    assert.ok(workerCalls[1].prompt.includes('20260926T150000Z-0000beef'), 'fix prompt lacks the red run id')
    assert.ok(!workerCalls[0].prompt.includes('20260926T150000Z-0000beef'))
    assert.equal(workerCalls[1].opts.agentType, WORKER)
    assert.equal(result.outcome, 'ready-to-merge')
    assert.deepEqual(result.commits, ['3f2a91c', '77aa001'], 'both attempts land on the branch')
    assert.equal(result.gate.runId, '20260926T151000Z-000000a2')
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

  async 'a verified playbook-rule major blocks when the verifier is handed the plugin\'s testing playbook — catches test-quality findings citing P1–P11 dropped as unverifiable'() {
    const pluginRoot = '/plugins/swift-harness/'
    const playbook = '/plugins/swift-harness/docs/testing-playbook.md'
    const hollow = finding({
      kind: 'standards-violation', rule: 'P2', category: 'would-not-fail', file: 'Tests/CatalogCoreTests/CatalogListTests.swift',
      line: 12, title: 'testLoads passes with the append reverted',
    })
    // A verifier can only confirm a P rule it can read: without the playbook's path it refutes.
    const verifyByPlaybook = (findings, prompt) => ({
      findings: findings.map(f => ({ ...f, verified: prompt.includes(playbook), verification_note: 'P2 read in the playbook' })),
    })
    const { workerCalls, reviewerCalls, verifyCalls, result } = await run(baseArgs({ pluginRoot }), {
      workers: [workerReturn(), workerReturn({ commits: ['77aa001'] })],
      reviews: { 'test-quality': [{ findings: [hollow] }] },
      verifies: { 'test-quality': [verifyByPlaybook] },
    })
    assert.equal(workerCalls.length, 2, 'a verified P2 major did not start the fix pass')
    assert.ok(workerCalls[1].prompt.includes(hollow.title))
    for (const { prompt } of [...reviewerCalls, ...verifyCalls]) {
      assert.ok(prompt.includes(playbook), 'an agent prompt lacks the testing playbook')
      assert.ok(prompt.includes('/plugins/swift-harness/docs/standards.md'), 'an agent prompt lacks the standards')
    }
    assert.ok(!workerCalls[0].prompt.includes(playbook), 'the worker prompt changed')
    assertTaskReturn(result, 'full')
    for (const bad of ['relative/root', '', 42]) {
      await assert.rejects(script(baseArgs({ pluginRoot: bad }), async () => {}, () => {}), /build-task: pluginRoot/)
    }
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
        assert.ok(prompt.includes(`${SG} surface-check <stub sha>`), 'the prompt does not check a stub with surface-check')
        assert.ok(prompt.includes('return its sha as surfaceCommit'), 'the prompt does not return the stub as surfaceCommit')
        assert.ok(!prompt.includes('<surface commit> when the task adds API'), 'the prompt still asks for a surface of its own')
      }
    }
  },

  async 'with a null plan surface the worker prompt and schema are today\'s, byte for byte — catches a design plan\'s workers told about a plan surface'() {
    const head =
      'Build this task and return one TaskReturn JSON object with "review": null, plus "span".\n\n' +
      'Task: catalog-list-reducer (plan catalog).\n' +
      'Worktree: /work/app-catalog-catalog-list-reducer, branch catalog/catalog-list-reducer, already checked out.\n' +
      'Write set: Sources/CatalogCore/CatalogList.swift, Tests/CatalogCoreTests/CatalogListTests.swift.\n'
    const shim =
      `Swiftgate: ${SG}, the plugin under test. Run every gate command through that path, never a bare \`swiftgate\`: ` +
      "the one on PATH may be another install, whose gate code and run store aren't this build's.\n"
    const tail =
      'Tests to turn green: test-catalog-list-loads-first-page.\n' +
      'Context pack: /work/app/.harness/context-pack/worker-catalog-list-reducer.md. Read it first.\n\nRun-viewer span: '
    const expected = {
      'per-task':
        head + 'Task proof: per-task.\n' + shim +
        `Task gate: ${SG} check --tier fast --base main --prove --mutate --impact --coverage --app-build, ` +
        'plus --proof-base <surface commit> when the task adds API.\n' + tail,
      final:
        head + 'Task proof: final.\n' + shim +
        `Task gate: ${SG} check --tier fast --base main --impact --coverage --app-build, ` +
        "plus --proof-base <surface commit> when the task adds API. The build's final ready gate proves and mutates every task at once.\n" +
        tail,
    }
    for (const [taskProof, prompt] of Object.entries(expected)) {
      const { workerCalls } = await run(baseArgs({ review: 'gate', taskProof }))
      assert.equal(workerCalls[0].prompt.slice(0, prompt.length), prompt)
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

  async 'the brownfield preset rejects a model alias and runs the worker on a pinned id — catches a brownfield worker on whatever model an alias names today'() {
    for (const model of ['sonnet', 'opus']) {
      const calls = []
      await assert.rejects(
        script(brownfieldArgs({ model }), async (p, o) => calls.push(o), () => {}),
        /brownfield profile/,
        model,
      )
      assert.equal(calls.length, 0)
    }
    for (const model of ['claude-sonnet-5-5', 'claude-opus-5-5']) {
      const { workerCalls, result } = await run(brownfieldArgs({ model }), { workers: [brownfieldReturn()] })
      assert.equal(workerCalls[0].opts.model, model)
      assert.equal(result.outcome, 'ready-to-merge')
    }
    const owned = await run(baseArgs({ model: 'claude-sonnet-5-5', review: 'gate' }))
    assert.equal(owned.workerCalls[0].opts.model, 'claude-sonnet-5-5', 'an owned preset refused a pinned id')
  },

  async 'a prove task gate passes --prove and never --mutate, from the plan branch, in every worker prompt — catches prove-only proof still mutating, or a slice gated against main'() {
    const behave = { workers: [brownfieldReturn({ outcome: 'gate-red', gate: { tier: 'slice', verdict: 'RED', runId: '20261004T141540Z-be184a1a' }, redReason: 'no-progress' }), brownfieldReturn()] }
    const { workerCalls } = await run(brownfieldArgs(), behave)
    assert.equal(workerCalls.length, 2)
    for (const { prompt } of workerCalls) {
      assert.ok(prompt.includes(`${SG} check --tier slice --base search/plan --prove`), `no prove gate:\n${prompt}`)
      assert.ok(!prompt.includes('--mutate'), `a prove worker prompt asks for --mutate:\n${prompt}`)
      assert.ok(!prompt.includes('--base main'), `a brownfield prompt gates against main:\n${prompt}`)
      assert.ok(prompt.includes('Task proof: prove'), 'the prompt does not name its proof mode')
    }
  },

  async 'paths a worker writes and reads come from the state root in a brownfield clone, and stay .harness in an owned one — catches task-status.json written where check-return never looks'() {
    const behave = { workers: [brownfieldReturn({ outcome: 'gate-red', gate: { tier: 'slice', verdict: 'RED', runId: '20261004T141540Z-be184a1a' }, redReason: 'no-progress' }), brownfieldReturn()] }
    const { workerCalls } = await run(brownfieldArgs(), behave)
    const state = brownfieldArgs().stateRoot
    assert.ok(workerCalls[0].prompt.includes(`State root: ${state}`), workerCalls[0].prompt)
    assert.ok(workerCalls[0].prompt.includes(`${state}/task-status.json`), workerCalls[0].prompt)
    assert.ok(workerCalls[1].prompt.includes(`read it in ${state}/runs/`), workerCalls[1].prompt)
    assert.ok(!workerCalls[1].prompt.includes('.harness'), `a brownfield prompt names .harness:\n${workerCalls[1].prompt}`)
    assert.match(workerCalls[0].opts.schema.properties.gate.properties.runId.description, new RegExp(`${state}/runs/history.jsonl`))
    const owned = await run(baseArgs({ review: 'gate' }), { workers: [red(), workerReturn()] })
    assert.ok(owned.workerCalls[1].prompt.includes("read it in the worktree's .harness/runs/"), owned.workerCalls[1].prompt)
  },

  async 'classified review with no diff-risk answer runs 1 reviewer at medium, verified on the pinned Opus id, and says so — catches classified review silently skipped or run at full depth'() {
    const findings = [finding({ file: 'Core/src/search.rs' })]
    const { reviewerCalls, verifyCalls, result, logs } = await run(brownfieldArgs(), {
      workers: [brownfieldReturn(), brownfieldReturn({ commits: ['77aa001'] })],
      reviews: { 'test-quality': [{ findings }, { findings: [] }] },
    })
    const firstRound = reviewerCalls.filter(c => c.prompt.includes('3f2a91c') && !c.prompt.includes('77aa001'))
    assert.deepEqual(firstRound.map(c => c.opts.agentType), ['swift-harness:test-quality'])
    for (const c of reviewerCalls) assert.equal(c.opts.model, 'claude-sonnet-5-5')
    assert.ok(verifyCalls.length >= 1)
    for (const c of verifyCalls) assert.equal(c.opts.model, 'claude-opus-5-5')
    assert.equal(result.review.mode, 'classified')
    assert.match(result.notes, /medium/)
    assert.match(result.notes, /diff-risk/)
    assert.ok(logs.some(l => /diff-risk/.test(l)), 'the medium fallback is not logged')
    assertTaskReturn(result, 'classified')
  },

  async 'classified review takes its depth from swiftgate judge diff-risk: low runs the gate only, high the full review — catches every brownfield task reviewed at medium whatever its risk'() {
    const low = await run(brownfieldArgs(), { workers: [brownfieldReturn()], diffRisk: judged('low') })
    assert.equal(low.result.outcome, 'ready-to-merge')
    assert.equal(low.reviewerCalls.length, 0, 'a low-risk change was reviewed')
    assert.match(low.result.notes, /classified at low by swiftgate judge diff-risk/)
    assertTaskReturn(low.result, 'classified')

    const high = await run(brownfieldArgs(), { workers: [brownfieldReturn()], diffRisk: judged('high') })
    assert.deepEqual(high.reviewerCalls.map(c => c.opts.agentType).sort(), ['swift-harness:architecture', 'swift-harness:test-quality'])
    assert.match(high.result.notes, /classified at high/)

    const call = high.classifierCalls[0]
    assert.equal(high.classifierCalls.length, 1)
    assert.ok(call.prompt.includes(`cd /work/search-task && ${SG} judge diff-risk --base search/plan --json`), call.prompt)
    assert.equal(call.opts.model, 'claude-sonnet-5-5')
  },

  async 'a sensitive path rates high with its glob and path in the review line run report reads, and a level with no named source falls back — catches every depth reported as the judge\'s, as in the fifth memos trial'() {
    const sensitive = { level: 'high', by: 'sensitive', path: 'store/auth.go', glob: 'store/**', reason: null, exitStatus: 0 }
    const { result, reviewerCalls, classifierCalls } = await run(brownfieldArgs(), { workers: [brownfieldReturn()], diffRisk: sensitive })
    assert.deepEqual(reviewerCalls.map(c => c.opts.agentType).sort(), ['swift-harness:architecture', 'swift-harness:test-quality'])
    // The exact line BrownfieldRunReport parses back into "because the sensitive glob … matches …".
    assert.ok(result.notes.split('\n').includes('review: classified at high because the sensitive glob store/** matches store/auth.go'), result.notes)
    assert.ok(!/by swiftgate judge diff-risk/.test(result.notes), result.notes)
    const schema = classifierCalls[0].opts.schema
    assert.deepEqual(schema.required.filter(k => ['by', 'path', 'glob'].includes(k)).sort(), ['by', 'glob', 'path'])

    for (const diffRisk of [{ ...judged('high'), by: null }, { ...sensitive, path: null }]) {
      const fell = await run(brownfieldArgs(), { workers: [brownfieldReturn()], diffRisk })
      assert.match(fell.result.notes, /classified at medium, because diff-risk gave no level/, JSON.stringify(diffRisk))
    }
  },

  async 'a diff-risk agent that fails or answers outside the levels falls back to medium and logs why — catches a broken classifier skipping review or crashing the task'() {
    for (const diffRisk of [new Error('agent died'), { level: 'critical', reason: null, exitStatus: 0 }, { level: 'low', reason: null, exitStatus: 2 }, null]) {
      const { result, reviewerCalls, logs } = await run(brownfieldArgs(), { workers: [brownfieldReturn()], diffRisk })
      assert.deepEqual(reviewerCalls.map(c => c.opts.agentType), ['swift-harness:test-quality'], JSON.stringify(diffRisk))
      assert.match(result.notes, /classified at medium, because diff-risk gave no level/)
      assert.ok(logs.some(l => /diff-risk gave no level/.test(l)), JSON.stringify(logs))
    }
    const { logs } = await run(brownfieldArgs(), { workers: [brownfieldReturn()], diffRisk: new Error('agent died') })
    assert.ok(logs.some(l => l.includes('agent died')), JSON.stringify(logs))
  },

  async 'diff-risk is asked once per task, after a green gate, and never in the owned profile — catches a fix pass re-rating the task or an owned build paying for a classifier'() {
    const behave = {
      workers: [brownfieldReturn({ outcome: 'gate-red', gate: { tier: 'slice', verdict: 'RED', runId: '20261004T141540Z-be184a1a' }, redReason: 'no-progress' }), brownfieldReturn()],
      diffRisk: judged('low'),
    }
    const fixed = await run(brownfieldArgs(), behave)
    assert.equal(fixed.classifierCalls.length, 1)
    assert.equal(fixed.result.outcome, 'ready-to-merge')
    const owned = await run(baseArgs())
    assert.equal(owned.classifierCalls.length, 0)
  },

  async 'brownfield-only modes fail under an owned task gate, and owned modes under a slice gate — catches a preset mixing the profiles'() {
    const accepted = await run(brownfieldArgs(), { workers: [brownfieldReturn()] })
    assert.equal(accepted.result.outcome, 'ready-to-merge', 'a well-formed brownfield launch was refused')
    const cases = [
      baseArgs({ review: 'classified' }),
      baseArgs({ taskProof: 'prove' }),
      baseArgs({ review: 'gate', stateRoot: '/work/app-catalog-catalog-list-reducer/.harness', base: 'main', taskGate: 'merge' }),
      brownfieldArgs({ review: 'full' }),
      brownfieldArgs({ review: 'gate' }),
      brownfieldArgs({ taskProof: 'per-task' }),
      brownfieldArgs({ stateRoot: undefined }),
      brownfieldArgs({ stateRoot: 'relative/swift-harness' }),
      brownfieldArgs({ stateRoot: '/work/search-task/.harness' }),
      brownfieldArgs({ base: undefined }),
    ]
    for (const args of cases) {
      const calls = []
      await assert.rejects(script(args, async (p, o) => calls.push(o), () => {}), /build-task/, JSON.stringify(args))
      assert.equal(calls.length, 0)
    }
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
