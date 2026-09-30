// Checks the tool that turns the filled-in blind labelling sheet into the judge's labels.json.
// Run: node tests/judge_labelling_sheet_test.mjs
// Regressions caught: a person's answer recorded as the agent's or not at all, an answer that isn't
// one of the question's options written as a label, a skipped question filled in with a guess, and
// a sheet that asks something other than what the judge asks.
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { applySheet, formatLabels, questions, renderSheet, sheetKey } from './judge_labelling_sheet.mjs'

const root = new URL('..', import.meta.url).pathname

function agentCase(id) {
  return {
    declaredTier: 'T1',
    expected: { 'asserts-implementation': 'no', 'fails-if-broken': 'yes', 'name-specificity': 'specific', tier: 'T1' },
    id, label: 'good', labeller: 'agent',
  }
}

const labels = { cases: [agentCase('old-case')], questionSet: 'test-quality@1', schema: 1 }
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
