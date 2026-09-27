// Scorer checks for review-accuracy, on synthetic review artifacts. No model calls.
// Run: node evals/runner/review_accuracy_test.mjs
// Regressions caught: a finding on the right line of the wrong file counting as a hit; a hit that
// only a dropped (unverified) finding made counting after the verifier; a clean case with a merge
// verdict scored wrong; a seeded defect that synthesis filed as pre-existing counting as found; an
// unmatched finding in review.json going uncounted.
import assert from 'node:assert/strict'
import { mkdirSync, mkdtempSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { matches, scoreTrial } from './review_accuracy.mjs'

const defect = { id: 'd', file: 'A.swift', lines: [10, 13] }
assert.equal(matches({ file: 'A.swift', line: 15 }, defect), true, 'within slack')
assert.equal(matches({ file: 'A.swift', line: 20 }, defect), false, 'outside slack')
assert.equal(matches({ file: 'B.swift', line: 11 }, defect), false, 'wrong file')

function run(pre, post, verdict, extra = {}) {
  const dir = mkdtempSync(join(tmpdir(), 'ra-'))
  mkdirSync(join(dir, 'review-findings'))
  writeFileSync(join(dir, 'review-findings/concurrency.json'), JSON.stringify({ findings: pre }))
  writeFileSync(join(dir, 'review.json'), JSON.stringify({ verdict, findings: post.map((f) => ({ finding: f, focuses: ['concurrency'] })), dropped: [], ...extra }))
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
const baseline = scoreTrial(
  { defects: [], known: [{ file: 'C.swift', lines: [1, 5] }] },
  run([noise], [], 'merge', { preExisting: [{ finding: { ...noise, severity: 'major' }, focuses: ['concurrency'] }] }),
)
assert.equal(baseline.verdictOk, true)
assert.equal(baseline.preExisting.count, 1)
assert.equal(baseline.preExisting.real, 1, 'a known baseline issue reported as pre-existing is real')

const misfiled = scoreTrial({ defects: [defect] }, run([hit], [], 'merge', { preExisting: [{ finding: hit, focuses: ['concurrency'] }] }))
assert.equal(misfiled.after.seeded[0].found, false, 'a seeded defect filed as pre-existing is not a hit')
assert.equal(misfiled.preExisting.seeded[0].found, true, 'and the misfiling is reported')

const lost = scoreTrial({ defects: [defect] }, run([hit], [hit], 'fix-then-merge', { unmatched: [{ focus: 'concurrency', finding: noise, preExisting: false }] }))
assert.equal(lost.unmatched, 1, 'review.json unmatched entries are counted')

const race = scoreTrial({ defects: [defect] }, run([hit], [hit], 'fix-then-merge'))
assert.equal(race.after.seeded[0].blocker, false, 'major is blocking but not a blocker')
console.log('review accuracy scorer: ok')
