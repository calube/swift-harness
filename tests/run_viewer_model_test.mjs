// Checks the run viewer's pure functions: merging a partial RunView, laying out the timeline,
// zoom and label fit, open spans, and a task's links and activity.
// Run: node tests/run_viewer_model_test.mjs
// Regressions caught: a partial that replaces every span, overlapping parallel tasks, a label
// clipped inside a narrow bar, an open span with no end drawn as zero width, a link list read one
// way, activity out of time order, and a header that hides a run's time box.
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'

const source = readFileSync(new URL('../plugin/viewer/run-view-model.js', import.meta.url), 'utf8')
// The page loads it as a classic script that sets 1 global; here that global is a local object, in
// this realm so deep equality sees plain arrays.
const sandbox = {}
new Function('globalThis', source)(sandbox)
const M = sandbox.RunViewModel

const t0 = Date.parse('2026-10-03T14:00:00.000Z')
const at = (minutes) => new Date(t0 + minutes * 60000).toISOString()
const span = (id, parent, phase, start, end, extra = {}) => ({
  id, parent, phase, task: null, gateRun: null, start: at(start), end: end == null ? null : at(end),
  outcome: null, approximate: false, ...extra,
})
const task = (id, extra = {}) => ({
  id, status: 'done', model: 'opus', deps: [], writes: [], gate: 'push', covers: [], commits: [], gateRun: null,
  mergeGateRun: null, createdAt: at(1), mergedAt: null, tokens: null, ...extra,
})
const runView = (extra = {}) => ({
  schemaVersion: 1, cursor: 'c0',
  run: { id: 'run-1', plan: 'sample', preset: 'default', startedAt: at(0), endedAt: at(40), state: 'done' },
  spec: [], tasks: [], roles: [], spans: [], gates: [], proofs: [], halts: [], damage: [], ...extra,
})

const tests = {
  'evidenceHref reaches a report folder\'s copies through the view\'s evidence base, and a live page\'s run files through ../runs/ — catches a final report whose step links leave its folder'() {
    assert.equal(M.evidenceHref('r1', 'qa/01 a.flow/video.mp4', 2500, 'runs/'), 'runs/r1/qa/01%20a.flow/video.mp4#t=2.5')
    assert.equal(M.evidenceHref('r1', 'qa/sheet.png', null, 'runs/'), 'runs/r1/qa/sheet.png')
    assert.equal(M.evidenceHref('r1', 'qa/sheet.png', null, null), '../runs/r1/qa/sheet.png')
    assert.equal(M.evidenceHref('r1', 'qa/sheet.png'), '../runs/r1/qa/sheet.png')
  },

  'snapshotText names when a report of a run that hadn\'t ended was taken and its state, and nothing for a final report — catches a mid-run report mistaken for the final one'() {
    assert.equal(M.snapshotText({ state: 'running', snapshotAt: '2026-10-04T05:17:00.000Z' }), 'Snapshot at 2026-10-04 05:17 UTC, run still running')
    assert.equal(M.snapshotText({ state: 'halted', snapshotAt: '2026-10-04T05:17:00.000Z' }), 'Snapshot at 2026-10-04 05:17 UTC, run still halted')
    assert.equal(M.snapshotText({ state: 'done', snapshotAt: null }), null)
    assert.equal(M.snapshotText({ state: 'running' }), null)
  },

  '2 parallel task spans land on 2 rows and their children nest under each — catches overlap'() {
    const spans = M.normalize(runView({
      spans: [
        span('run', null, 'run', 0, 40),
        span('t1', 'run', 'task', 10, 30, { task: 'one' }),
        span('t1w', 't1', 'worker', 10, 20, { task: 'one' }),
        span('t1r', 't1', 'review', 20, 30, { task: 'one' }),
        span('t2', 'run', 'task', 12, 32, { task: 'two' }),
        span('t2w', 't2', 'worker', 12, 25, { task: 'two' }),
      ],
    })).spans
    const rows = M.lanes(spans, [])
    const rowOf = (id) => rows.findIndex((row) => row.spans.some((s) => s.id === id))
    assert.notEqual(rowOf('t1'), rowOf('t2'), 'parallel tasks share a row')
    assert.equal(rowOf('t1w'), rowOf('t1r'), "a task's stages split across rows")
    assert.ok(rowOf('t1') < rowOf('t1w') && rowOf('t1w') < rowOf('t2'), "task one's stages are not under it")
    assert.ok(rowOf('t2') < rowOf('t2w'), "task two's stages are not under it")
    assert.equal(rows[rowOf('t1w')].depth, rows[rowOf('t1')].depth + 1)
    for (const row of rows) {
      const sorted = [...row.spans].sort((a, b) => a.start - b.start)
      sorted.slice(1).forEach((s, i) => assert.ok(s.start >= sorted[i].end, `${s.id} overlaps ${sorted[i].id} in 1 row`))
    }
  },

  'at 4x the track is 4 times its 1x width — catches a zoom that scales the page'() {
    assert.equal(M.scale(1, 900), 900)
    assert.equal(M.scale(2, 900), 1800)
    assert.equal(M.scale(4, 900), 3600)
  },

  'a 30 px bar with a 10-character label shows no text — catches a clipped label'() {
    assert.equal(M.labelFits('gate ready', 30), false)
    assert.equal(M.labelFits('gate ready', 200), true)
  },

  'a span with no end lays out to the run\'s last event and reads never ended — catches an open span drawn as zero width'() {
    const view = runView({
      run: { id: 'run-1', plan: 'sample', preset: 'default', startedAt: at(0), endedAt: null, state: 'halted' },
      spans: [span('run', null, 'run', 0, 20), span('open', 'run', 'contract', 5, null)],
      halts: [{ task: null, reason: 'needs an answer', at: at(26), answer: null, waitMs: null }],
    })
    const { spans, wall } = M.normalize(view)
    const open = spans.find((s) => s.id === 'open')
    assert.equal(wall, 26)
    assert.equal(open.start, 5)
    assert.equal(open.end, 26)
    assert.equal(open.open, true)
    assert.equal(M.durationText(open), 'never ended')
    assert.equal(M.durationText(spans.find((s) => s.id === 'run')), '20m 00s')
  },

  'tokens not yet ingested read pending, never 0 — catches a running worker shown as free'() {
    assert.equal(M.fmtTokens(null), 'pending')
    assert.equal(M.fmtTokens({ input: 1000, output: 500, cacheRead: 2500, cacheWrite: 1000 }), '5k')
  },

  'blocks inverts the deps — catches a link list read 1 way'() {
    const view = runView({
      tasks: [task('store'), task('queue', { deps: ['store'] }), task('ui', { deps: ['store', 'queue'] })],
    })
    assert.deepEqual(M.blocks(view, 'store'), ['queue', 'ui'])
    assert.deepEqual(M.blocks(view, 'queue'), ['ui'])
    assert.deepEqual(M.blocks(view, 'ui'), [])
    assert.equal(M.waveOf(view, 'store'), 1)
    assert.equal(M.waveOf(view, 'ui'), 3)
  },

  'activity orders a task\'s worker start, gates, fix, review and merge by time — catches events read in array order'() {
    const view = runView({
      tasks: [task('queue', { commits: ['abc1234'], mergedAt: at(31), mergeGateRun: 'g3' })],
      spans: [
        span('run', null, 'run', 0, 40),
        span('t', 'run', 'task', 10, 31, { task: 'queue' }),
        span('r', 't', 'review', 26, 30, { task: 'queue' }),
        span('g2', 't', 'gate', 22, 25, { task: 'queue', gateRun: 'g2', outcome: 'ok' }),
        span('f', 't', 'fix', 18, 22, { task: 'queue' }),
        span('g1', 't', 'gate', 15, 18, { task: 'queue', gateRun: 'g1', outcome: 'red' }),
        span('w', 't', 'worker', 10, 15, { task: 'queue' }),
      ],
      gates: [
        { runId: 'g1', task: 'queue', command: 'check --tier push', verdict: 'RED', ms: 180000, tests: { passed: 1, failed: 0, skipped: 0 }, ruleCounts: { 'prove.not-proven': 1 }, steps: [] },
        { runId: 'g2', task: 'queue', command: 'check --tier push', verdict: 'GREEN', ms: 180000, tests: { passed: 1, failed: 0, skipped: 0 }, ruleCounts: {}, steps: [] },
      ],
    })
    const events = M.activity(view, 'queue')
    assert.deepEqual(events.map((e) => e.kind), ['created', 'worker', 'gate', 'fix', 'gate', 'review', 'merge'])
    assert.deepEqual(events.map((e) => e.text).filter((t) => t.startsWith('Gate')), ['Gate RED', 'Gate GREEN'])
    assert.deepEqual(events[2].codes, ['prove.not-proven'])
    assert.deepEqual(events.at(-1).codes, ['abc1234'])
    events.slice(1).forEach((e, i) => assert.ok(e.at >= events[i].at, `${e.kind} sorts before ${events[i].kind}`))
  },

  'a tool summary adds up a task\'s spans in the contract shape — catches a summary from 1 span only'() {
    const view = runView({
      spans: [
        span('t', null, 'task', 0, 10, { task: 'one' }),
        span('w', 't', 'worker', 0, 5, { task: 'one', tools: { calls: [{ tool: 'Edit', count: 2, ms: 100 }, { tool: 'Read', count: 3, ms: 50 }], otherCount: 1, ms: 160, files: ['Sources/A.swift'], droppedPaths: 1 } }),
        span('f', 't', 'fix', 5, 10, { task: 'one', tools: { calls: [{ tool: 'Edit', count: 1, ms: 40 }], otherCount: 0, ms: 40, files: ['Sources/A.swift', 'Tests/ATests.swift'], droppedPaths: 0 } }),
      ],
    })
    const summary = M.toolSummary(M.normalize(view).spans, 't')
    assert.deepEqual(summary.calls, [{ tool: 'Edit', count: 3, ms: 140 }, { tool: 'Read', count: 3, ms: 50 }])
    assert.equal(summary.otherCount, 1)
    assert.equal(summary.ms, 200)
    assert.deepEqual(summary.files, ['Sources/A.swift', 'Tests/ATests.swift'])
    assert.equal(summary.droppedPaths, 1)
  },

  'stalls flags a task whose last event is older than stall_min and not one with a fresh event — catches a stall measured from the span\'s start'() {
    const view = runView({
      run: { id: 'run-1', plan: 'sample', preset: 'default', startedAt: at(0), endedAt: null, state: 'running' },
      tasks: [task('quiet', { status: 'in-progress' }), task('busy', { status: 'in-progress' }), task('merged')],
      spans: [
        span('t-quiet', null, 'task', 1, null, { task: 'quiet' }),
        span('w-quiet', 't-quiet', 'worker', 2, null, { task: 'quiet' }),
        span('t-busy', null, 'task', 1, null, { task: 'busy' }),
        span('w-busy', 't-busy', 'worker', 2, 18, { task: 'busy' }),
        span('g-busy', 't-busy', 'gate', 19, null, { task: 'busy' }),
        span('t-merged', null, 'task', 1, 3, { task: 'merged' }),
      ],
    })
    assert.deepEqual(M.stalls(view, Date.parse(at(20)), 5), ['quiet'])
    assert.deepEqual(M.stalls(view, Date.parse(at(6)), 5), [], 'a task 4 minutes quiet is flagged before stall_min')
  },

  'a halt counts as open until its resume, and the now strip badges its task — catches a halt badge that outlives the resume'() {
    const view = runView({
      run: { id: 'run-1', plan: 'sample', preset: 'default', startedAt: at(0), endedAt: null, state: 'halted' },
      tasks: [task('a', { status: 'in-progress' }), task('b', { status: 'in-progress' })],
      spans: [
        span('t-a', null, 'task', 1, null, { task: 'a' }),
        span('r-a', 't-a', 'review', 3, null, { task: 'a' }),
        span('t-b', null, 'task', 1, null, { task: 'b' }),
      ],
      halts: [
        { task: 'a', reason: 'gate-red', at: at(4), answer: null, waitMs: null },
        { task: 'b', reason: 'gate-red', at: at(2), answer: 'retry', waitMs: 30000 },
      ],
    })
    assert.deepEqual(M.openHalts(view).map((h) => h.task), ['a'])
    const cards = M.workers(view, Date.parse(at(5)), 10)
    assert.deepEqual(cards.map((c) => [c.task, c.phase, c.halted, c.stalled]), [['a', 'review', true, false], ['b', 'task', false, false]])
    assert.equal(cards[0].elapsedMs, 4 * 60000)
    assert.equal(cards[0].lastEventMs, Date.parse(at(4)))
  },

  'the header names a run\'s time box with the times starts stop, the cutoff comes and the box ends, and nothing for a run without one — catches a viewer that hides the box a brownfield run must fit'() {
    const run = {
      ...runView().run,
      timeBox: { budgetMin: 45, source: 'config', startedAt: at(0), noNewStartsAt: at(32), cutoffAt: at(40), endsAt: at(45) },
    }
    assert.equal(M.timeBoxText(run), 'box 45 min (config): starts stop 14:32 UTC, cutoff 14:40 UTC, ends 14:45 UTC')
    assert.equal(M.timeBoxText({ ...run, timeBox: { ...run.timeBox, source: 'flag' } }).slice(0, 23), 'box 45 min (--time-box)')
    assert.equal(M.timeBoxText(runView().run), null)
    assert.equal(M.timeBoxText({ ...runView().run, timeBox: null }), null)
  },

  'latestGate picks the gate run whose span ended last, not the last gate record — catches a latest gate read in array order'() {
    const gateRow = (runId, verdict) => ({ runId, task: 'a', command: 'check --tier push', verdict, ms: 60000, tests: null, ruleCounts: {}, steps: [] })
    const view = runView({
      tasks: [task('a'), task('b')],
      spans: [
        span('gate:g2', null, 'gate', 9, 10, { task: 'a', gateRun: 'g2', outcome: 'ok' }),
        span('gate:g1', null, 'gate', 4, 5, { task: 'a', gateRun: 'g1', outcome: 'red' }),
      ],
      gates: [gateRow('g2', 'GREEN'), gateRow('g1', 'RED')],
    })
    assert.equal(M.latestGate(view, 'a')?.runId, 'g2')
    assert.equal(M.latestGate(view, 'b'), null)
  },

  'tabBadges counts what each tab hides: failed spans, blocked tasks, RED gates and retries, unproven tests, uncovered requirements and pending tokens — catches a badge that drifts from the view'() {
    const gateRow = (runId, taskID, verdict) => ({ runId, task: taskID, command: 'check --tier push', verdict, ms: 60000, tests: null, ruleCounts: {}, steps: [] })
    const view = runView({
      spec: [{ id: 'req-a', title: 'A', tasks: ['a'] }, { id: 'req-b', title: 'B', tasks: [] }],
      tasks: [
        task('a', { status: 'done', tokens: { input: 1, output: 1, cacheRead: 1, cacheWrite: 1 } }),
        task('b', { status: 'blocked' }),
        task('c', { status: 'in-progress' }),
        task('d', { status: 'in-progress' }),
        task('e', { status: 'pending' }),
      ],
      spans: [
        span('run', null, 'run', 0, 40),
        span('gate:g1', 'run', 'gate', 4, 5, { task: 'a', gateRun: 'g1', outcome: 'red' }),
        span('tier:g1:T1', 'gate:g1', 'tier', 4, 5, { task: 'a', gateRun: 'g1', outcome: 'red' }),
        span('step:g1:1', 'tier:g1:T1', 'step', 4, 5, { task: 'a', gateRun: 'g1', outcome: 'red' }),
        span('gate:g2', 'run', 'gate', 6, 7, { task: 'a', gateRun: 'g2', outcome: 'ok' }),
        span('gate:g3', 'run', 'gate', 8, 9, { task: 'a', gateRun: 'g3', outcome: 'ok' }),
        span('gate:g4', 'run', 'gate', 1, 2, { task: 'b', gateRun: 'g4', outcome: 'ok' }),
        span('t-b', 'run', 'task', 1, 12, { task: 'b', outcome: 'halted' }),
        span('w-c', 'run', 'worker', 2, null, { task: 'c' }),
      ],
      gates: [gateRow('g3', 'a', 'GREEN'), gateRow('g1', 'a', 'RED'), gateRow('g2', 'a', 'GREEN'), gateRow('g4', 'b', 'GREEN')],
      proofs: [
        { gateRun: 'g2', task: 'a', test: 'A/one()', outcome: 'proven', proofBase: null, assertion: null },
        { gateRun: 'g2', task: 'a', test: 'A/two()', outcome: 'passes-reverted', proofBase: null, assertion: null },
      ],
      halts: [{ task: 'd', reason: 'question', at: at(11), answer: null, waitMs: null }],
    })
    const counts = (badges) => Object.fromEntries(badges.map((b) => [b.key, b.n]))
    const b = M.tabBadges(view, {})
    assert.deepEqual(counts(b.overview), { halted: 1 })
    // The RED gate counts once, not once per tier and step it holds.
    assert.deepEqual(counts(b.timeline), { failed: 2, unended: 1 })
    assert.deepEqual(counts(b.board), { blocked: 2, active: 1 })
    assert.deepEqual(counts(b.graph), { merged: 1 })
    assert.match(b.graph[0].text, /1\/5/)
    assert.deepEqual(counts(b.spec), { uncovered: 1 })
    // g2 and g3 ran after a's RED g1; b's single run is no retry.
    assert.deepEqual(counts(b.gates), { red: 1, retries: 2, unproven: 1 })
    assert.deepEqual(counts(b.tokens), { pending: 4 })
    assert.equal(b.gates.find((x) => x.key === 'red').kind, 'bad')
    for (const list of Object.values(b)) for (const badge of list) assert.ok(badge.n > 0, `${badge.key} shows a zero badge`)
  },

  'failureReason takes the builder\'s reason, a step row takes its gate\'s, and an open span in a report never ended — catches a red popover with no reason or a live span called failed'() {
    const reason = 'area.test-failed: 46 tests fail on the merged branch.'
    const view = runView({
      spans: [
        span('g', null, 'gate', 1, 4, { gateRun: 'r1', outcome: 'red', failureReason: reason }),
        span('w', null, 'warmup', 0, 1, { outcome: 'red', failureReason: 'Base commit\'s tests already fail; 5 recorded as baseline.' }),
        span('o', null, 'plan', 0, null),
        span('k', null, 'plan', 0, 1, { outcome: 'ok' }),
        span('x', null, 'review', 0, 1, { outcome: 'red' }),
      ],
    })
    const byId = Object.fromEntries(view.spans.map((s) => [s.id, s]))
    assert.equal(M.failureReason(view, byId.w, false), 'Base commit\'s tests already fail; 5 recorded as baseline.')
    assert.equal(M.failureReason(view, { id: 'g:t2:test', phase: 'step', gateRun: 'r1', outcome: 'red', open: false }, false), reason)
    assert.equal(M.failureReason(view, byId.o, false), 'Never ended; no end event recorded.')
    assert.equal(M.failureReason(view, byId.o, true), null)
    assert.equal(M.failureReason(view, byId.k, false), null)
    assert.equal(M.failureReason(view, byId.x, false), 'No reason recorded.')
    const excused = runView({ spans: [span('s', null, 'step', 0, 1, { gateRun: 'r2', outcome: 'red', baseline: true, failureReason: 'Fails at the base commit too; the baseline excused it.' })] })
    assert.equal(M.failureReason(excused, { id: 'g2:t1:area-test', phase: 'step', gateRun: 'r2', outcome: 'red', open: false }, false), 'Fails at the base commit too; the baseline excused it.')
  },

  'tabBadges leaves a warm-up step the baseline recorded out of the failed count — catches an expected base failure counted as the run\'s fault'() {
    const view = runView({
      spans: [
        span('w', null, 'warmup', 0, 1, { outcome: 'red', baseline: true }),
        span('x', null, 'warmup', 1, 2, { outcome: 'red', baseline: false }),
      ],
    })
    assert.deepEqual(M.tabBadges(view, {}).timeline.map((b) => [b.key, b.n]), [['failed', 1]])
  },

  'in live mode tabBadges counts stalled tasks against the clock and no open span as never ended — catches a live run read as a finished report'() {
    const view = runView({
      run: { id: 'run-1', plan: 'sample', preset: 'default', startedAt: at(0), endedAt: null, state: 'running' },
      tasks: [task('quiet', { status: 'in-progress' })],
      spans: [span('t-quiet', null, 'task', 1, null, { task: 'quiet' }), span('w-quiet', 't-quiet', 'worker', 2, null, { task: 'quiet' })],
    })
    const keys = (badges) => Object.fromEntries(badges.map((x) => [x.key, x.n]))
    assert.deepEqual(keys(M.tabBadges(view, { now: Date.parse(at(20)), stallMin: 5 }).timeline), { stalled: 1 })
    assert.deepEqual(keys(M.tabBadges(view, { now: Date.parse(at(4)), stallMin: 5 }).timeline), {})
    assert.deepEqual(keys(M.tabBadges(view, { now: Date.parse(at(20)), stallMin: null }).timeline), {}, 'a stall counted with no stall_min')
  },

  'validationGroups puts a row under each task it runs after in ledger order, ends each group with its waiting rows, and keeps rows with no task last — catches a shared check shown under 1 task or a waiting row read as run'() {
    const row = (n, result, runsAfter, waitingOn = []) => ({ row: n, requirement: 'req-a', layer: 'acceptance', check: 'c' + n, runsAfter, result, message: null, exitStatus: null, ms: 0, evidence: [], waitingOn, qaRun: 'q1', at: at(5), output: [], outputCut: false })
    const view = runView({
      tasks: [task('store'), task('list'), task('share', { status: 'pending' })],
      validation: { plan: 'sample', counts: { pass: 1, red: 0, unverified: 0, waiting: 1 }, rows: [
        row(1, 'waiting', ['store', 'share'], ['share']),
        row(2, 'pass', ['list']),
        row(3, 'unverified', []),
        row(4, 'pass', ['store']),
      ] },
    })
    const groups = M.validationGroups(view).map((g) => [g.task, g.rows.map((r) => r.row), g.waiting.map((r) => r.row)])
    assert.deepEqual(groups, [['store', [4], [1]], ['list', [2], []], ['share', [], [1]], [null, [3], []]])
    assert.deepEqual(M.validationGroups(runView()), [])
  },

  'validationBadges carries the red, unverified and waiting counts and none for pass or zero — catches a red check that shows from no tab'() {
    const view = runView({ validation: { plan: 'sample', counts: { pass: 3, red: 1, unverified: 2, waiting: 0 }, rows: [] } })
    assert.deepEqual(M.validationBadges(view).map((b) => [b.key, b.kind, b.n, b.text]), [['red', 'bad', 1, '1 red'], ['unverified', 'warn', 2, '2 unverified']])
    assert.deepEqual(M.validationBadges(runView({ validation: null })), [])
  },

  'a qa.check span reads as qa check on the timeline — catches a raw event kind as a bar label'() {
    assert.equal(M.normalize(runView({ spans: [span('qa:q1:1', null, 'qa.check', 1, 2)] }), null).spans[0].label, 'qa check')
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
