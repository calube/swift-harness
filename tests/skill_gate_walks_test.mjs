// Walks the build skill's green-main and merge gate lines through the real binary in temp
// repositories; one of their push gates makes a cold SwiftPM build of its package. Each script
// holds at most one cold build (the other is skill_surface_baseline_walk_test.mjs): it is the step
// a loaded machine slows most, two in one script overran its 60s repository-script timeout at a
// load average near 120 on 16 cores, and separate scripts get separate timeouts and run side by
// side.
// Run: node tests/skill_gate_walks_test.mjs
// Regression caught: a build stopped by the surface it builds on.
import assert from 'node:assert/strict'
import {
  buildGatesFor,
  buildGateWalk,
  buildSkillFiles,
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
