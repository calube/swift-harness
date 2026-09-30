// Walks the build skill's start on a plan with a surface through the real binary in a temp
// repository: one real push gate with a cold SwiftPM build of its package. It has a script of its
// own, apart from skill_gate_walks_test.mjs, so each cold build gets its own 60s
// repository-script timeout and the two run side by side.
// Run: node tests/skill_surface_baseline_walk_test.mjs
// Regression caught: a build halted by the surface it builds on, or a real red waved through as
// the surface's baseline.
import assert from 'node:assert/strict'
import {
  buildGatesFor,
  buildSkillFiles,
  surfaceBaselineProblems,
  surfaceBaselineRule,
  surfaceBaselineWalk,
} from './skill_commands_test.mjs'

const tests = {
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
