// Grader and case-loading checks for the thin runner. No model calls.
// Run: node evals/runner/session_test.mjs
// Regressions caught: a grader file's escaped regex read with different backslashes than
// `claude plugin eval` reads it, so the same case grades differently under the 2 runners; a
// swiftgate command in the transcript counted as a RED verdict; tool_order passing when the
// `after` call never happened; a tool_used input_match matching a skill whose args only mention
// the name; a command grader passing on a non-zero exit; the judge digest dropping hook feedback.
import assert from 'node:assert/strict'
import { mkdtempSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { parseValue, splitFrontmatter } from './frontmatter.mjs'
import { digest, gradeCode, loadCase, parseTrace } from './session.mjs'

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

const redReport = JSON.stringify({ verdict: 'RED' }, null, 2).replace(/":/g, '" :')
const blockedReport = redReport.replace('RED', 'BLOCKED')
const command = use('Bash', { command: '"$SG" test --tier t1 --json # expect verdict RED' })
assert.equal(gradeCode(red, run([command, result(redReport)])).passed, true, 'a RED report passes')
assert.equal(gradeCode(red, run([command, result(blockedReport)])).passed, false, 'a BLOCKED report fails')

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

const hookFeedback = line({ type: 'user', message: { content: [{ type: 'text', text: 'Stop hook feedback:\nswiftgate RED' }] } })
assert.match(digest(parseTrace(hookFeedback)), /Stop hook feedback/)

console.log('session runner: ok')
