// Checks the tool that turns the filled-in blind labelling sheets (the test-quality set and the
// comment set) into each set's labels.json.
// Run: node tests/judge_labelling_sheet_test.mjs
// Regressions caught: a person's answer recorded as the agent's or not at all, an agent's answers
// recorded as a person's, an answer that isn't
// one of the question's options written as a label, a skipped question filled in with a guess, a
// sheet that asks something other than what the judge asks, and a comment case that lost the
// commit and path it came from.
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import {
  applyCommentSheet, applySheet, commentQuestions, fillSheet, formatLabels, questions, renderCommentSheet, renderSheet,
  sheetKey,
} from './judge_labelling_sheet.mjs'

const root = new URL('..', import.meta.url).pathname

function agentCase(id) {
  return {
    declaredTier: 'T1',
    expected: { 'asserts-implementation': 'no', 'fails-if-broken': 'yes', 'name-specificity': 'specific', tier: 'T1' },
    id, label: 'good', labeller: 'agent',
  }
}

const labels = { cases: [agentCase('old-case')], questionSet: 'test-quality@1', schema: 1 }

const commentLabels = { cases: [], questionSet: 'comments@1', schema: 1 }
const comments = [
  {
    id: 'case-0a1b2c', commit: 'a'.repeat(40), path: 'plugin/gate/Sources/A/A.swift',
    comment: '// Retries once because the first request after a cold start is dropped.',
    context: 'func send() {\n  retry(1)\n}',
  },
  {
    id: 'case-3d4e5f', commit: 'b'.repeat(40), path: 'examples/SampleApp/App/B.swift',
    comment: '/// Adds one to the count.', context: 'func increment() { count += 1 }',
  },
]
const commentIds = comments.map((item) => item.id)
const cases = [
  { id: 'old-case', declaredTier: 'T1', test: '@Test("a — catches b")\nfunc a() {}\n', diff: '+let a = 1\n' },
  { id: 'case-abc123', declaredTier: 'T2', test: '@Test("c — catches d")\nfunc c() {}\n', diff: '+let c = 2\n' },
]
const caseIds = cases.map((item) => item.id)

// Fills the answer lines of the case with `id`, leaving every other line as rendered.
function fill(sheet, id, answers) {
  let current
  return sheet.split('\n').map((line) => {
    const heading = line.match(/^## Case \d+ · key ([0-9a-f]{8})$/)
    if (heading) current = heading[1]
    const answer = line.match(/^Answer ([a-z-]+):$/)
    if (answer && current === sheetKey(id) && answers[answer[1]] !== undefined) return `${line} ${answers[answer[1]]}`
    return line
  }).join('\n')
}

const tests = {
  'a filled sheet produces person labels with exactly the answers given — catches a person\'s answers recorded as the agent\'s or dropped'() {
    let sheet = renderSheet({ labels, cases })
    sheet = fill(sheet, 'old-case', { 'fails-if-broken': 'no', tier: 'T2', 'name-specificity': 'vague', 'asserts-implementation': 'yes' })
    sheet = fill(sheet, 'case-abc123', { 'fails-if-broken': 'yes', tier: 'T2', 'name-specificity': 'specific', 'asserts-implementation': 'no' })
    const result = applySheet({ labels, sheet, caseIds })
    assert.deepEqual(result.errors, [])
    assert.deepEqual(result.labels.cases, [
      {
        declaredTier: 'T1', id: 'old-case', label: 'useless', labeller: 'person',
        expected: { 'fails-if-broken': 'no', tier: 'T2', 'name-specificity': 'vague', 'asserts-implementation': 'yes' },
      },
      {
        declaredTier: 'T2', id: 'case-abc123', label: 'good', labeller: 'person',
        expected: { 'fails-if-broken': 'yes', tier: 'T2', 'name-specificity': 'specific', 'asserts-implementation': 'no' },
      },
    ])
  },

  'an answer that isn\'t one of the options is rejected and nothing is written — catches a typo shipped as a label'() {
    const sheet = fill(renderSheet({ labels, cases }), 'case-abc123', { 'fails-if-broken': 'maybe', tier: 'T1' })
    const result = applySheet({ labels, sheet, caseIds })
    assert.equal(result.errors.length, 1)
    assert.match(result.errors[0], /fails-if-broken is 'maybe', not one of yes, no/)
    assert.deepEqual(result.labels, labels)
  },

  'a blank answer leaves that question unlabelled, and an unanswered case keeps its old entry — catches a skipped question filled in with a guess'() {
    const sheet = fill(renderSheet({ labels, cases }), 'case-abc123', { tier: 'T3' })
    const result = applySheet({ labels, sheet, caseIds })
    assert.deepEqual(result.errors, [])
    assert.deepEqual(result.labels.cases, [
      agentCase('old-case'),
      { declaredTier: 'T2', expected: { tier: 'T3' }, id: 'case-abc123', label: 'useless', labeller: 'person' },
    ])
  },

  'the sheet shows no case id, and a case missing from it is an error — catches an unblinded sheet or a case nobody was asked about'() {
    const sheet = renderSheet({ labels, cases })
    assert.doesNotMatch(sheet, /old-case|case-abc123/)
    const partial = renderSheet({ labels, cases: [cases[0]] })
    const result = applySheet({ labels, sheet: partial, caseIds })
    assert.match(result.errors.join('\n'), /case-abc123/)
  },

  'the sheet asks the judge\'s questions word for word — catches a sheet whose questions drifted from the judge\'s'() {
    const source = readFileSync(`${root}plugin/gate/Sources/SwiftGateDomain/Judge/Judge.swift`, 'utf8')
      .replace(/"\s*\n\s*\+\s*"/g, '')
    assert.equal(questions.length, 4)
    for (const { id, text } of questions) {
      assert.ok(source.includes(`id: "${id}",`), `${id} is not a judge question`)
      assert.ok(source.includes(`"${text}"`), `${id}'s text differs from the judge's`)
    }
  },

  'a filled comment sheet produces person labels with exactly the answers given — catches a person\'s comment answers recorded as the agent\'s or dropped'() {
    let sheet = renderCommentSheet({ cases: comments })
    sheet = fill(sheet, 'case-0a1b2c', { 'loses-fact': 'yes', 'right-size': 'yes' })
    sheet = fill(sheet, 'case-3d4e5f', { 'loses-fact': 'no', 'right-size': '' })
    const result = applyCommentSheet({ labels: commentLabels, sheet, caseIds: commentIds })
    assert.deepEqual(result.errors, [])
    assert.deepEqual(result.labels, {
      cases: [
        { expected: { 'loses-fact': 'yes', 'right-size': 'yes' }, id: 'case-0a1b2c', labeller: 'person' },
        { expected: { 'loses-fact': 'no' }, id: 'case-3d4e5f', labeller: 'person' },
      ],
      questionSet: 'comments@1', schema: 1,
    })
    assert.equal(result.person, 2)
  },

  'an unfilled comment sheet labels nothing — catches an agent\'s or a default answer written for a person'() {
    const result = applyCommentSheet({ labels: commentLabels, sheet: renderCommentSheet({ cases: comments }), caseIds: commentIds })
    assert.deepEqual(result.errors, [])
    assert.deepEqual(result.labels, commentLabels)
  },

  'a comment answer that isn\'t yes or no is rejected and nothing is written — catches a typo shipped as a comment label'() {
    const sheet = fill(renderCommentSheet({ cases: comments }), 'case-3d4e5f', { 'loses-fact': 'yes', 'right-size': 'maybe' })
    const result = applyCommentSheet({ labels: commentLabels, sheet, caseIds: commentIds })
    assert.equal(result.errors.length, 1)
    assert.match(result.errors[0], /right-size is 'maybe', not one of yes, no/)
    assert.deepEqual(result.labels, commentLabels)
  },

  'the comment sheet shows each case\'s comment, code and source but no case id, and a missing source or case is an error — catches an unblinded sheet or a case that lost where it came from'() {
    const sheet = renderCommentSheet({ cases: comments })
    assert.doesNotMatch(sheet, /case-0a1b2c|case-3d4e5f/)
    for (const item of comments) {
      assert.ok(sheet.includes(item.comment), 'the comment is missing')
      assert.ok(sheet.includes(item.context), 'the code after it is missing')
      assert.ok(sheet.includes(`Source: ${item.commit} ${item.path}`), 'the source is missing')
    }
    const noSource = sheet.replace(`Source: ${comments[1].commit} ${comments[1].path}`, '')
    const lost = applyCommentSheet({ labels: commentLabels, sheet: noSource, caseIds: commentIds })
    assert.match(lost.errors.join('\n'), /source line is missing/)
    const partial = renderCommentSheet({ cases: [comments[0]] })
    const result = applyCommentSheet({ labels: commentLabels, sheet: partial, caseIds: commentIds })
    assert.match(result.errors.join('\n'), /case-3d4e5f/)
  },

  'the comment sheet asks the comment judge\'s questions word for word — catches a sheet whose questions drifted from the judge\'s'() {
    const source = readFileSync(`${root}plugin/gate/Sources/SwiftGateDomain/Judge/Judge.swift`, 'utf8')
      .replace(/"\s*\n\s*\+\s*"/g, '')
    assert.deepEqual(commentQuestions.map((q) => q.id), ['loses-fact', 'right-size'])
    for (const { id, text } of commentQuestions) {
      assert.ok(source.includes(`id: "${id}",`), `${id} is not a judge question`)
      assert.ok(source.includes(`"${text}"`), `${id}'s text differs from the judge's`)
    }
    const sheet = renderCommentSheet({ cases: comments })
    for (const { id, text } of commentQuestions) assert.ok(sheet.includes(`- ${id}: ${text}`), `${id} is not asked`)
  },

  'answers from a file fill the sheet and apply as agent labels — catches an agent\'s answers recorded as a person\'s'() {
    const sheet = renderSheet({ labels, cases })
    const number = sheet.includes(`## Case 1 · key ${sheetKey('case-abc123')}`) ? 1 : 2
    const filled = fillSheet(sheet, [{
      case: number, key: sheetKey('case-abc123'),
      answers: { 'fails-if-broken': 'yes', tier: 'T2', 'name-specificity': 'partial', 'asserts-implementation': 'no' },
    }])
    assert.deepEqual(filled.errors, [])
    const result = applySheet({ labels, sheet: filled.sheet, caseIds, labeller: 'agent' })
    assert.deepEqual(result.errors, [])
    assert.deepEqual(result.labels.cases, [
      agentCase('old-case'),
      {
        declaredTier: 'T2', id: 'case-abc123', label: 'good', labeller: 'agent',
        expected: { 'fails-if-broken': 'yes', tier: 'T2', 'name-specificity': 'partial', 'asserts-implementation': 'no' },
      },
    ])
    assert.equal(result.person, 0)
  },

  'a skipped answer in the file leaves that question unlabelled — catches a null or skipped answer written as a label'() {
    const filled = fillSheet(renderCommentSheet({ cases: comments }), [
      { key: sheetKey('case-0a1b2c'), answers: { 'loses-fact': 'yes', 'right-size': null } },
      { key: sheetKey('case-3d4e5f'), answers: { 'loses-fact': null, 'right-size': null } },
    ])
    assert.deepEqual(filled.errors, [])
    const result = applyCommentSheet({ labels: commentLabels, sheet: filled.sheet, caseIds: commentIds, labeller: 'agent' })
    assert.deepEqual(result.errors, [])
    assert.deepEqual(result.labels.cases, [{ expected: { 'loses-fact': 'yes' }, id: 'case-0a1b2c', labeller: 'agent' }])
  },

  'a file answer for a key, case number or question the sheet lacks, or over a filled line, is an error — catches answers landing on the wrong case or overwriting a person\'s'() {
    const sheet = renderCommentSheet({ cases: comments })
    const key = sheetKey('case-0a1b2c')
    const number = sheet.includes(`## Case 1 · key ${key}`) ? 1 : 2
    const errors = (entries, text = sheet) => fillSheet(text, entries).errors.join('\n')
    assert.match(errors([{ key: 'ffffffff', answers: { 'loses-fact': 'yes' } }]), /ffffffff/)
    assert.match(errors([{ case: 3 - number, key, answers: { 'loses-fact': 'yes' } }]), /case number/)
    assert.match(errors([{ key, answers: { 'tier': 'T1' } }]), /tier/)
    assert.match(errors([{ key, answers: { 'loses-fact': 'yes' } }, { key, answers: { 'right-size': 'no' } }]), /twice/)
    const answered = fill(sheet, 'case-0a1b2c', { 'loses-fact': 'no' })
    assert.match(errors([{ key, answers: { 'loses-fact': 'yes' } }], answered), /already answered/)
  },

  'formatting the committed comment labels reproduces the file byte for byte — catches a rewrite that reorders or reformats every comment label'() {
    const text = readFileSync(`${root}plugin/gate/Fixtures/judge-comments/labels.json`, 'utf8')
    assert.equal(formatLabels(JSON.parse(text)), text)
  },

  'formatting the committed labels reproduces the file byte for byte — catches a rewrite that reorders or reformats every label'() {
    const text = readFileSync(`${root}plugin/gate/Fixtures/judge/labels.json`, 'utf8')
    assert.equal(formatLabels(JSON.parse(text)), text)
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
