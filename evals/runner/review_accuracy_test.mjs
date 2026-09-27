// Scorer checks for review-accuracy, on synthetic review artifacts. No model calls.
// Run: node evals/runner/review_accuracy_test.mjs
// Regressions caught: a finding on the right line of the wrong file counting as a hit; a hit that
// only a dropped (unverified) finding made counting after the verifier; a clean case with a merge
// verdict scored wrong.
import assert from 'node:assert/strict'
import { mkdirSync, mkdtempSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { matches, scoreTrial } from './review_accuracy.mjs'

const defect = { id: 'd', file: 'A.swift', lines: [10, 13] }
assert.equal(matches({ file: 'A.swift', line: 15 }, defect), true, 'within slack')
assert.equal(matches({ file: 'A.swift', line: 20 }, defect), false, 'outside slack')
assert.equal(matches({ file: 'B.swift', line: 11 }, defect), false, 'wrong file')

function run(pre, post, verdict) {
  const dir = mkdtempSync(join(tmpdir(), 'ra-'))
  mkdirSync(join(dir, 'review-findings'))
  writeFileSync(join(dir, 'review-findings/concurrency.json'), JSON.stringify({ findings: pre }))
  writeFileSync(join(dir, 'review.json'), JSON.stringify({ verdict, findings: post.map((f) => ({ finding: f, focuses: ['concurrency'] })), dropped: [] }))
  return dir
}
const hit = { file: 'A.swift', line: 11, severity: 'major', category: 'race', title: 't' }
const noise = { file: 'C.swift', line: 3, severity: 'minor', category: 'style', title: 'n' }

const found = scoreTrial({ defects: [defect] }, run([hit, noise], [hit], 'fix-then-merge'))
assert.equal(found.after.seeded[0].blocking, true)
assert.equal(found.verdictOk, true)
assert.equal(found.before.unlabelled.length, 1, 'the style note is unmatched before the verifier')

const droppedOnly = scoreTrial({ defects: [defect] }, run([hit], [], 'merge'))
assert.equal(droppedOnly.before.seeded[0].found, true)
assert.equal(droppedOnly.after.seeded[0].found, false, 'a finding the verifier dropped is not a hit after it')
assert.equal(droppedOnly.verdictOk, false)

const clean = scoreTrial({ defects: [], known: [{ file: 'C.swift', lines: [1, 5] }] }, run([noise], [noise], 'merge'))
assert.equal(clean.verdictOk, true)
assert.equal(clean.after.real, 1, 'a known real issue is not left to label')
console.log('review accuracy scorer: ok')
