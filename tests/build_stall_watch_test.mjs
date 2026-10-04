// Runs the build skill's stall watch, as its event loop documents it, against fake workflow
// transcript trees: a running workflow whose agents stopped moving, and one that has ended.
// Run: node tests/build_stall_watch_test.mjs
// Regression caught: a watch that outlives its workflow and prints `stalled` minutes after the
// workflow returned, as the store task's watch did in the fifth memos trial.
import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { mkdirSync, mkdtempSync, readFileSync, rmSync, utimesSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = join(dirname(fileURLToPath(import.meta.url)), '..', 'plugin')
const EVENT_LOOP = 'skills/build/references/event-loop.md'
const INTERVAL = '/bin/sleep 60'

// The 1 bash block under `## Stall watch`.
function stallWatchCommand() {
  const markdown = readFileSync(join(root, EVENT_LOOP), 'utf8')
  const section = markdown.split(/^## /m).find(part => part.startsWith('Stall watch\n'))
  assert.ok(section, `${EVENT_LOOP} has no Stall watch section`)
  const blocks = [...section.matchAll(/```bash\n([\s\S]*?)```/g)].map(match => match[1].trim())
  assert.equal(blocks.length, 1, 'the Stall watch section holds more than 1 bash block')
  return blocks[0]
}

// The watch with its placeholders filled and its minute-long poll shortened, so a test waits
// a fraction of a second per round.
function watch(directory, minutes) {
  const command = stallWatchCommand()
  assert.equal(command.split(INTERVAL).length, 2, `the watch no longer polls with ${INTERVAL}`)
  const filled = command
    .replace('<dir>', `'${directory}'`)
    .replace('<stall minutes>', String(minutes))
    .replace(INTERVAL, '/bin/sleep 0.2')
  assert.ok(!/<[a-z ]+>/.test(filled), `a placeholder is left unfilled: ${filled}`)
  const result = spawnSync('/bin/bash', ['-c', filled], { encoding: 'utf8', timeout: 20_000 })
  assert.equal(result.error, undefined, `the watch never exited: ${result.error}`)
  return result
}

// A session directory as the Workflow tool lays it out: each workflow's agent transcripts under
// `subagents/workflows/<id>/`, and `workflows/<id>.json` written once the workflow ends.
function session(base, { ended, agentMinutesAgo }) {
  const id = 'wf_d827fa99-506'
  const transcripts = join(base, 'session', 'subagents', 'workflows', id)
  mkdirSync(transcripts, { recursive: true })
  const agent = join(transcripts, 'agent-a24b4dd65c1a4795b.jsonl')
  writeFileSync(agent, '{}\n')
  const then = new Date(Date.now() - agentMinutesAgo * 60_000)
  utimesSync(agent, then, then)
  if (ended) {
    mkdirSync(join(base, 'session', 'workflows'), { recursive: true })
    writeFileSync(join(base, 'session', 'workflows', `${id}.json`), '{"status":"completed"}\n')
  }
  return transcripts
}

function withTemp(body) {
  const base = mkdtempSync(join(tmpdir(), 'stall-watch-'))
  try {
    body(base)
  } finally {
    rmSync(base, { recursive: true, force: true })
  }
}

const tests = {
  'a watch whose workflow has ended exits without printing stalled, though its agents stopped moving — catches the store watch that printed stalled 3 minutes after its workflow returned'() {
    withTemp(base => {
      // The fifth memos trial's store workflow: its last transcript write before the watch's
      // 2-minute window, and its workflow record already written.
      const directory = session(base, { ended: true, agentMinutesAgo: 3 })
      const result = watch(directory, 2)
      assert.equal(result.status, 0, result.stderr)
      assert.ok(!result.stdout.includes('stalled'), `an ended workflow's watch fired: ${result.stdout}`)
      assert.ok(result.stdout.includes(`ended: ${directory}`), `the watch didn't say why it stopped: ${result.stdout}`)
    })
  },

  'a running workflow whose agents stopped moving still fires stalled — catches a watch that never fires'() {
    withTemp(base => {
      const directory = session(base, { ended: false, agentMinutesAgo: 3 })
      const result = watch(directory, 2)
      assert.equal(result.status, 0, result.stderr)
      assert.equal(result.stdout.trim(), `stalled: ${directory}`)
    })
  },
}

let failed = 0
for (const [name, test] of Object.entries(tests)) {
  try {
    await test()
    console.log(`ok   ${name}`)
  } catch (error) {
    failed++
    console.log(`FAIL ${name}\n     ${error.message.split('\n').join('\n     ')}`)
  }
}
if (failed) {
  console.log(`${failed} failed`)
  process.exit(1)
}
