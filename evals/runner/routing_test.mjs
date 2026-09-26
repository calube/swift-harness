import assert from 'node:assert/strict'
import { test } from 'node:test'
import { expand } from './seed_routing.mjs'
import { score, skillCalls, tagsOf } from './routing.mjs'

test('skillCalls reads Skill calls in order and ignores other tools', () => {
  const trace = [
    JSON.stringify({ type: 'assistant', message: { content: [{ type: 'tool_use', name: 'Skill', input: { skill: 'swift-harness:tdd', args: 'test-gate later' } }] } }),
    JSON.stringify({ type: 'assistant', message: { content: [{ type: 'tool_use', name: 'Read', input: { file_path: 'swift-harness:review' } }] } }),
    JSON.stringify({ type: 'assistant', message: { content: [{ type: 'tool_use', name: 'Skill', input: { skill: 'swift-harness:test-gate' } }] } }),
    '{"truncated": ',
  ].join('\n')
  assert.deepEqual(skillCalls(trace), ['swift-harness:tdd', 'swift-harness:test-gate'])
})

test('tagsOf reads the inline tag list', () => {
  assert.deepEqual(tagsOf('name: x\ntags: [routing, split-40, load-none]\n'), ['routing', 'split-40', 'load-none'])
})

test('score counts a wrong extra load as a false positive and first load in the confusion table', () => {
  const t = (c, expect, loaded, passed) => ({ case: c, forSkill: 'tdd', expect, kind: 'x', passed, loaded })
  const s = score([
    t('a', 'tdd', ['tdd'], true),
    t('a', 'tdd', [], false),
    t('b', 'none', ['tdd'], false),
    t('c', 'test-gate', ['tdd', 'test-gate'], false),
  ])
  assert.deepEqual(s.perSkill.tdd, { expectedTrials: 2, loadedTrials: 3, tp: 1, fp: 2, fn: 1, precision: 1 / 3, recall: 0.5 })
  assert.equal(s.perSkill['test-gate'].recall, 1)
  assert.equal(s.perSkill['test-gate'].precision, 1)
  assert.deepEqual(s.confusion, { tdd: { tdd: 1, none: 1 }, none: { tdd: 1 }, 'test-gate': { tdd: 1 } })
  assert.deepEqual(s.flaky, ['a'])
  assert.equal(s.passAllK, 0)
})

test('seeds: 120 round-1 cases, paraphrases share a split, near-misses never expect their own skill', () => {
  const all = expand().filter((c) => c.round === 1)
  assert.equal(all.length, 120)
  const splits = {}
  for (const c of all) (splits[`${c.skill}/${c.slug}`] ??= new Set()).add(c.split)
  assert.ok(Object.values(splits).every((s) => s.size === 1))
  assert.ok(all.filter((c) => c.kind === 'near-miss').every((c) => c.expect !== c.skill))
  for (const skill of new Set(all.map((c) => c.skill))) {
    const mine = all.filter((c) => c.skill === skill)
    assert.equal(mine.length, 20, skill)
    assert.equal(mine.filter((c) => c.split === 40).length, 8, skill)
  }
})

test('seeds: round 2 adds only tdd and test-gate cases, with unique names', () => {
  const all = expand()
  const r2 = all.filter((c) => c.round === 2)
  assert.ok(r2.length > 0)
  assert.deepEqual([...new Set(r2.map((c) => c.skill))].sort(), ['tdd', 'test-gate'])
  const names = all.map((c) => `${c.skill}/${c.slug}-${c.variant}`)
  assert.equal(new Set(names).size, names.length)
})
