// Grader and case-loading checks for the thin runner. No model calls.
// Run: node evals/runner/session_test.mjs
// Regressions caught: a grader file's escaped regex read with different backslashes than
// `claude plugin eval` reads it, so the same case grades differently under the 2 runners; a
// swiftgate command in the transcript counted as a RED verdict; a real RED missed because the
// agent printed the report through a JSON filter; tool_order passing when the
// `after` call never happened; a tool_used input_match matching a skill whose args only mention
// the name; a command grader passing on a non-zero exit; the judge digest dropping hook feedback;
// a trial scored while the gate was still building and every hook was off; a judge failing a
// long final message it only saw the first 1,500 characters of.
import assert from 'node:assert/strict'
import { existsSync, mkdirSync, mkdtempSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { parseValue, splitFrontmatter } from './frontmatter.mjs'
import { digest, gradeCode, hooksInactive, isScored, judgePrompt, keepFiles, loadCase, parseTrace, scoreRun } from './session.mjs'

const here = dirname(fileURLToPath(import.meta.url))
const cases = resolve(here, '../cases')

assert.deepEqual(parseValue('[Read, Glob, "Bash"]'), ['Read', 'Glob', 'Bash'])
assert.deepEqual(parseValue('{ tool: Edit, input_match: "Foo\\\\.swift" }'), { tool: 'Edit', input_match: 'Foo\\.swift' })
assert.equal(parseValue("'it''s'"), "it's")
assert.throws(() => parseValue('"\\q"'), /unknown escape/)
assert.deepEqual(splitFrontmatter('---\nmax_turns: 4\n---\n\nbody\n'), { data: { max_turns: 4 }, body: 'body' })
assert.equal(
  splitFrontmatter('---\nrun: |\n  a\n\n    b\nnext: 1\n---\n').data.run, 'a\n\n  b\n',
  'a literal block keeps its blank lines and relative indentation',
)

const tdd = loadCase(join(resolve(here, '../sessions'), 'skills/tdd/decrement-floors-at-zero'))
assert.equal(tdd.maxTurns, 40)
const hidden = tdd.graders.find((g) => g.name === 'hidden-floor-test')
assert.match(hidden.run, /\n\n@MainActor\nstruct HiddenFloorTests {\n  @Test/, 'the hidden test survives parsing intact')
assert.match(hidden.run, /\nSWIFT\n"\$sg" test --tier t1 --json\n$/)
assert.ok(tdd.scaffold, 'the case links the shared scaffold')
const red = tdd.graders.find((g) => g.name === 'swiftgate-red-seen')
const order = tdd.graders.find((g) => g.name === 'test-before-reducer')
const routing = loadCase(join(cases, 'routing/tdd/add-test-for-reducer'))
const loads = routing.graders.find((g) => g.name === 'loads-tdd')

const line = (m) => JSON.stringify(m)
const use = (name, input) => line({ type: 'assistant', message: { content: [{ type: 'tool_use', name, input }] } })
const result = (text) => line({ type: 'user', message: { content: [{ type: 'tool_result', content: text }] } })
const run = (lines, extra = {}) => {
  const traceText = lines.join('\n')
  return { messages: parseTrace(traceText), traceText, hooksText: '', diffText: '', createdFiles: [], workspace: tmpdir(), env: process.env, ...extra }
}

const history = (...runs) => {
  const workspace = mkdtempSync(join(tmpdir(), 'session-history-'))
  mkdirSync(join(workspace, '.harness/runs'), { recursive: true })
  const lines = runs.map(([command, verdict]) => line({ command, durationMilliseconds: 1, findingCount: 0, runID: 'r', schemaVersion: 1, tiers: [{ tier: 'T1', verdict }], verdict }))
  writeFileSync(join(workspace, '.harness/runs/history.jsonl'), lines.join('\n') + '\n')
  return { workspace }
}
const command = use('Bash', { command: '"$SG" test --tier t1 --json # expect verdict RED' })
assert.equal(gradeCode(red, run([command, result('RED')], history(['test t1', 'RED'], ['test t1', 'GREEN']))).passed, true, 'a RED run passes, however the agent printed it')
assert.equal(gradeCode(red, run([command, result('"verdict" : "RED"')], history(['test t1', 'BLOCKED']))).passed, false, 'a BLOCKED run fails, whatever the transcript says')
assert.equal(gradeCode(red, run([], history(['hook stop', 'RED'], ['test t1', 'GREEN']))).passed, false, "the stop hook's RED isn't the agent's")
assert.equal(gradeCode(red, run([])).passed, false, 'no run history fails')

const testEdit = use('Edit', { file_path: '/w/Packages/CounterFeature/Tests/CounterCoreTests/CounterFeatureTests.swift' })
const coreEdit = use('Edit', { file_path: '/w/Packages/CounterFeature/Sources/CounterCore/CounterFeature.swift' })
assert.equal(gradeCode(order, run([testEdit, coreEdit])).passed, true)
assert.equal(gradeCode(order, run([coreEdit, testEdit])).passed, false, 'reducer first fails')
assert.equal(gradeCode(order, run([testEdit])).passed, false, 'no reducer edit fails')

assert.equal(gradeCode(loads, run([use('Skill', { skill: 'swift-harness:tdd' })])).passed, true)
assert.equal(gradeCode(loads, run([use('Skill', { skill: 'swift-harness:test-gate', args: 'after tdd' })])).passed, false)

assert.equal(gradeCode({ type: 'command', run: 'exit 0' }, run([])).passed, true)
assert.equal(gradeCode({ type: 'command', run: 'echo GREEN; exit 3' }, run([])).passed, false)
assert.equal(gradeCode({ type: 'command', run: 'echo BLOCKED', stdout_match: 'GREEN' }, run([])).passed, false)

const dir = mkdtempSync(join(tmpdir(), 'session-test-'))
writeFileSync(join(dir, 'x'), '')
assert.equal(gradeCode({ type: 'file_exists', path: 'Packages/**/Tests/**/*.swift' }, run([], { createdFiles: ['Packages/A/Tests/ATests/NewTests.swift'] })).passed, true)
assert.equal(gradeCode({ type: 'file_exists', path: 'Packages/**/Tests/**/*.swift' }, run([], { createdFiles: ['Packages/A/Sources/A/New.swift'] })).passed, false)

assert.equal(hooksInactive('{"additionalContext":"swiftgate enforcement is warming up: swiftgate is being built"}'), true, 'a warming gate makes the trial an error')
assert.equal(hooksInactive('{"additionalContext":"Session id: abc"}'), false)

const longFinal = 'questions '.repeat(250) + 'END-OF-MESSAGE'
const finalRun = run([line({ type: 'assistant', message: { content: [{ type: 'text', text: longFinal }] } })])
assert.match(judgePrompt({ criteria: 'x' }, finalRun), /END-OF-MESSAGE/, 'the judge sees a long final message whole')

const kws = mkdtempSync(join(tmpdir(), 'keep-ws-'))
mkdirSync(join(kws, '.harness/runs/r1/review-findings'), { recursive: true })
writeFileSync(join(kws, '.harness/runs/r1/review.json'), '{}')
writeFileSync(join(kws, '.harness/runs/r1/review-findings/concurrency.json'), '{}')
writeFileSync(join(kws, '.harness/runs/r1/log.txt'), 'x')
const kdest = mkdtempSync(join(tmpdir(), 'keep-dest-'))
keepFiles(kws, /\.harness\/runs\/[^/]+\/(review\.json|review-findings\/[^/]+\.json)$/, kdest)
assert.ok(existsSync(join(kdest, '.harness/runs/r1/review-findings/concurrency.json')), 'keep copies matching files with their paths')
assert.ok(!existsSync(join(kdest, '.harness/runs/r1/log.txt')), 'and only those')

const hookFeedback = line({ type: 'user', message: { content: [{ type: 'text', text: 'Stop hook feedback:\nswiftgate RED' }] } })
assert.match(digest(parseTrace(hookFeedback)), /Stop hook feedback/)

const verdicts = (arm) => [
  { weight: 1, passed: true, scored: isScored({}, arm) },
  { weight: 1, passed: false, scored: isScored({ arm: 'with-only' }, arm) },
]
assert.deepEqual(scoreRun(verdicts('without')), { score: 1, passed: true }, 'a with-only grader is left out of the without arm')
assert.deepEqual(scoreRun(verdicts('with')), { score: 0.5, passed: false }, 'and still scores in the with arm')

console.log('session runner: ok')
