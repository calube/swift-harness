// Scoring and label checks for the corpus runner. Run: node evals/runner/corpus_test.mjs
// Regressions caught: a finding the labels don't name passing its case, which would hide every
// false positive; a planted rule counted as recalled when swiftgate missed it; a false positive
// charged to the rule a case plants; a mislabelled case (a near-miss that expects findings) loading.
import assert from 'node:assert/strict'
import { mkdirSync, mkdtempSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { loadCases, perRule, scoreCase } from './corpus.mjs'

const positive = { kind: 'positive', expect: ['det.date-init'] }
const nearMiss = { kind: 'near-miss', expect: [] }

assert.deepEqual(scoreCase(positive, ['det.date-init']), {
  found: ['det.date-init'], missed: [], unexpected: [], passed: true,
})
const extra = scoreCase(positive, ['det.date-init', 'det.uuid-init'])
assert.equal(extra.passed, false, 'an unlabelled finding fails the case')
assert.deepEqual(extra.unexpected, ['det.uuid-init'])
const missed = scoreCase(positive, [])
assert.equal(missed.passed, false)
assert.deepEqual(missed.missed, ['det.date-init'])
assert.equal(scoreCase(nearMiss, ['det.date-init']).passed, false, 'a near-miss with a finding fails')

const results = [
  { name: 'hit', labels: positive, ...scoreCase(positive, ['det.date-init']) },
  { name: 'miss', labels: { kind: 'evasion', expect: ['det.date-init'] }, ...scoreCase({ kind: 'evasion', expect: ['det.date-init'] }, []) },
  { name: 'noisy', labels: nearMiss, ...scoreCase(nearMiss, ['det.date-init']) },
  { name: 'quiet', labels: nearMiss, ...scoreCase(nearMiss, []) },
]
const [date] = perRule(results)
assert.equal(date.rule, 'det.date-init')
assert.deepEqual(date.positive, [1, 1], 'positives recalled / planted')
assert.deepEqual(date.evasion, [0, 1], 'evasions are counted apart from positives')
assert.equal(date.falsePositives, 1)
assert.equal(date.negatives, 2)
assert.deepEqual(date.falsePositiveCases, ['noisy'])

const corpus = join(mkdtempSync(join(tmpdir(), 'corpus-test-')), 'lint')
const writeCase = (name, labels) => {
  mkdirSync(join(corpus, name), { recursive: true })
  writeFileSync(join(corpus, name, 'labels.json'), JSON.stringify(labels))
}
writeCase('ok', positive)
assert.equal(loadCases(corpus)[0].gate, 'lint', 'the corpus directory names the swiftgate command')
writeCase('bad', { kind: 'near-miss', expect: ['det.date-init'] })
assert.throws(() => loadCases(corpus), /expects no findings/)

console.log('corpus runner: ok')
