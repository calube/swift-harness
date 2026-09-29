// Walks the build skill's gate lines through the real binary in temp repositories, each walk a
// real push gate with a cold SwiftPM build of its package. They run apart from
// skill_commands_test.mjs so these cold builds, the step a loaded machine slows most, don't share
// its 60s repository-script timeout with its text checks.
// Run: node tests/skill_gate_walks_test.mjs
// Regressions caught: a build stopped by the surface it builds on, and a real red waved through
// as the surface's baseline.
import assert from 'node:assert/strict'
import {
  buildGatesFor,
  buildGateWalk,
  buildSkillFiles,
  surfaceBaselineProblems,
  surfaceBaselineRule,
  surfaceBaselineWalk,
} from './skill_commands_test.mjs'

const tests = {
  'the build skill\'s green-main check is GREEN through the real binary on main right after a surface that adds an untested module, and its merge gate still judges the task — catches a build stopped by the surface it builds on'() {
    const files = buildSkillFiles()
    const surfaced = buildGateWalk(buildGatesFor(files, { surfaceCommit: '<surfaceCommit>' }).filter(gate => gate.file === 'skills/build/SKILL.md'))
    assert.deepEqual(surfaced.results.map(r => [r.kind, r.verdict]), [['green-main', 'GREEN'], ['merge', 'RED']],
      surfaced.results.map(r => r.gating.join(', ')).join('\n'))
    assert.deepEqual(surfaced.results[1].gating, ['impact.untested-change Packages/Core/Sources/Feed/Feed.swift'])
    const plain = buildGateWalk(buildGatesFor(files, {}).filter(gate => gate.file === 'skills/build/SKILL.md'))
    assert.deepEqual(plain.results.map(r => [r.kind, r.verdict, r.gating]), [
      ['green-main', 'RED', ['impact.untested-change Packages/Core/Sources/Feed/Feed.swift']],
      ['merge', 'RED', ['impact.untested-change Packages/Core/Sources/Feed/Feed.swift']],
    ], 'the old lines no longer reproduce the surface\'s RED green-main check')
  },

  'the build skill takes a surface\'s untested new module as its green-main baseline without asking, and still halts on any other gating finding — catches a build halted by the surface it builds on, or a real red waved through'() {
    const files = buildSkillFiles()
    const skill = files['skills/build/SKILL.md']
    assert.deepEqual(surfaceBaselineProblems(skill), [])
    const rule = surfaceBaselineRule(skill)
    assert.equal(rule.rule, 'coverage.no-t1-tests')
    const gates = buildGatesFor(files, { surfaceCommit: '<surfaceCommit>' }).filter(gate => gate.file === 'skills/build/SKILL.md')
    const walk = surfaceBaselineWalk(gates, rule)
    assert.deepEqual([walk.verdict, walk.gating], ['RED', [
      'coverage.diff .', 'coverage.no-t1-tests Packages/Core/Sources/Feed', 'coverage.no-t1-tests Packages/Core/Sources/Legacy',
    ]])
    assert.deepEqual([walk.alone, walk.all, walk.beside], ['baseline', 'halt', {
      'coverage.diff .': 'halt', 'coverage.no-t1-tests Packages/Core/Sources/Legacy': 'halt',
    }])
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
