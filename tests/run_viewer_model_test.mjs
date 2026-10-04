// Checks the run viewer's pure functions: merging a partial RunView, laying out the timeline,
// zoom and label fit, open spans, and a task's links and activity.
// Run: node tests/run_viewer_model_test.mjs
// Regressions caught: a partial that replaces every span, overlapping parallel tasks, a label
// clipped inside a narrow bar, an open span with no end drawn as zero width, a link list read one
// way, and activity out of time order.
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
  'apply merges a partial span by id and keeps every other span — catches a replace-all merge'() {
    const view = runView({
      spans: [span('run', null, 'run', 0, 40), span('a', 'run', 'plan', 1, 5), span('b', 'run', 'contract', 5, null)],
    })
    const merged = M.apply(view, { cursor: 'c1', spans: [{ ...span('b', 'run', 'contract', 5, 9), outcome: 'ok' }] })
    assert.deepEqual(merged.spans.map((s) => s.id), ['run', 'a', 'b'])
    assert.equal(merged.spans[2].end, at(9))
    assert.equal(merged.spans[2].outcome, 'ok')
    assert.equal(merged.cursor, 'c1')
    assert.equal(view.spans[2].end, null, 'apply changed its input')
  },

  'apply appends a span the view does not hold yet — catches a merge that only updates'() {
    const view = runView({ spans: [span('run', null, 'run', 0, 40)] })
    const merged = M.apply(view, { spans: [span('new', 'run', 'plan', 2, 3)] })
    assert.deepEqual(merged.spans.map((s) => s.id), ['run', 'new'])
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
