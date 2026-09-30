// Thin runner around `claude -p` for cases that build or test Swift, which the `claude plugin
// eval` Bash sandbox blocks (see evals/results/2026-09-25-runner-spike). Its cases live under
// evals/sessions/ with the prompt in task.md, since `claude plugin eval` loads every prompt.md
// under evals/ and would reject the `command` grader. The rest of the layout matches: frontmatter
// settings, graders/*.md, and an optional scaffold.sh. It also reads a plain prompt.md case.
//
// Run: node evals/runner/session.mjs <case-dir> ... [--runs 3] [--arms with,without]
//        [--model <id>] [--judge-model <id>] [--max-cost-usd 10] [--session-cost-usd 3]
//        [--out <dir>] [--raw <dir>]
//
// Each trial gets a scratch HOME and a fresh workspace, and runs with no user settings
// (`--setting-sources project,local`). The `with` arm loads this checkout as the plugin; the
// `without` arm loads nothing. Hooks record their payloads and outcomes through
// SWIFTGATE_HOOK_RECORD_DIR. Transcripts, hook records and the final diff stay under --raw, out
// of git; the Swift build products are deleted after grading.
//
// Graders, by `type`:
//   regex      pattern, flags, match (contains | not_contains | count:N), target
//              (trace | last_message | hooks | diff | files)
//   tool_used  tool, input_match, min, max
//   tool_order before, after: a tool name or {tool, input_match}
//   file_exists path (a glob over files the run created), exists
//   command    run: a shell command in the final workspace; passes on exit 0, and when
//              stdout_match is set, only if stdout matches it. Hidden tests go here.
//   llm        criteria in the body; focus (trace | last_message), diff; the judge model votes
//              3 times, 2 PASS votes pass
// A case's `keep` frontmatter, a regex over workspace-relative paths, copies matching files to
// <raw>/<case>/<arm>-<trial>/kept/ before the workspace is deleted.
// Any grader may set `arm: with-only`: the without arm reports it and leaves it out of the score.
import { execFileSync, spawn, spawnSync } from 'node:child_process'
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { basename, dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { splitFrontmatter } from './frontmatter.mjs'

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..')

export function loadCase(dir) {
  const file = existsSync(join(dir, 'task.md')) ? 'task.md' : 'prompt.md'
  const { data, body } = splitFrontmatter(readFileSync(join(dir, file), 'utf8'))
  const yaml = existsSync(join(dir, 'case.yaml')) ? readFileSync(join(dir, 'case.yaml'), 'utf8') : ''
  const name = data.name ?? /^name:\s*(.+)$/m.exec(yaml)?.[1].trim() ?? basename(dir)
  const graderDir = join(dir, 'graders')
  const graders = existsSync(graderDir)
    ? readdirSync(graderDir).filter((f) => f.endsWith('.md')).sort().map((file) => {
        const g = splitFrontmatter(readFileSync(join(graderDir, file), 'utf8'))
        return { name: file.replace(/\.md$/, ''), weight: 1, ...g.data, criteria: g.body }
      })
    : []
  // A bad focus fails at load, before the trial pays for a session the judge can't grade.
  for (const g of graders) if (g.type === 'llm') judgeFocus(g)
  return {
    dir, name, prompt: body, graders,
    maxTurns: data.max_turns ?? 10,
    timeoutSeconds: data.timeout_seconds ?? 300,
    allowedTools: data.allowed_tools ?? [],
    runs: data.runs ?? 3,
    keep: data.keep ? new RegExp(data.keep) : null,
    scaffold: existsSync(join(dir, 'scaffold.sh')) ? join(dir, 'scaffold.sh') : null,
  }
}

// --- Trace reading -------------------------------------------------------------------------

export function parseTrace(text) {
  return text.split('\n').filter(Boolean).flatMap((line) => {
    try { return [JSON.parse(line)] } catch { return [] }
  })
}

export function toolCalls(messages) {
  return messages.flatMap((m) =>
    m.type === 'assistant'
      ? (m.message?.content ?? []).filter((c) => c.type === 'tool_use').map((c) => ({ name: c.name, input: c.input }))
      : [],
  )
}

export function lastMessage(messages) {
  const result = messages.findLast((m) => m.type === 'result')
  if (typeof result?.result === 'string') return result.result
  const text = messages.findLast((m) => m.type === 'assistant' && m.message?.content?.some((c) => c.type === 'text'))
  return text ? text.message.content.filter((c) => c.type === 'text').map((c) => c.text).join('\n') : ''
}

const matchesCall = (spec, call) => {
  const { tool, input_match: inputMatch } = typeof spec === 'string' ? { tool: spec } : spec
  return call.name === tool && (!inputMatch || new RegExp(inputMatch).test(JSON.stringify(call.input)))
}

function globToRegExp(glob) {
  let out = ''
  for (let i = 0; i < glob.length; i++) {
    const c = glob[i]
    if (c === '*' && glob[i + 1] === '*') {
      out += glob[i + 2] === '/' ? '(?:.*/)?' : '.*'
      i += glob[i + 2] === '/' ? 2 : 1
    } else if (c === '*') out += '[^/]*'
    else if (c === '?') out += '[^/]'
    else out += c.replace(/[.+^${}()|[\]\\]/g, '\\$&')
  }
  return new RegExp(`^${out}$`)
}

// --- Graders -------------------------------------------------------------------------------

// `run` holds what the graders read: messages, trace text, hooks text, diff text, created files,
// and the workspace for command graders.
export function gradeCode(grader, run) {
  switch (grader.type) {
    case 'regex': {
      const target = grader.target ?? 'last_message'
      const text = { trace: run.traceText, last_message: lastMessage(run.messages), hooks: run.hooksText, diff: run.diffText, files: run.createdFiles.join('\n') }[target]
      if (text === undefined) return { passed: false, explanation: `unknown regex target ${target}` }
      const flags = (grader.flags ?? '').replace('g', '') + 'g'
      const count = [...text.matchAll(new RegExp(grader.pattern, flags))].length
      const match = grader.match ?? 'contains'
      if (match === 'contains') return { passed: count > 0, explanation: `${count} matches` }
      if (match === 'not_contains') return { passed: count === 0, explanation: `${count} matches` }
      const n = /^count:(\d+)$/.exec(match)
      if (n) return { passed: count === Number(n[1]), explanation: `${count} matches, expected ${n[1]}` }
      return { passed: false, explanation: `unknown match ${match}` }
    }
    case 'tool_used': {
      const count = toolCalls(run.messages).filter((c) => matchesCall({ tool: grader.tool, input_match: grader.input_match }, c)).length
      const min = grader.min ?? 1
      const max = grader.max ?? Infinity
      return { passed: count >= min && count <= max, explanation: `${grader.tool} called ${count}x (expected ${min}..${max === Infinity ? '∞' : max})` }
    }
    case 'tool_order': {
      const calls = toolCalls(run.messages)
      const before = calls.findIndex((c) => matchesCall(grader.before, c))
      const after = calls.findIndex((c) => matchesCall(grader.after, c))
      if (before < 0) return { passed: false, explanation: 'no call matched `before`' }
      if (after < 0) return { passed: false, explanation: 'no call matched `after`' }
      return { passed: before < after, explanation: `before@${before} after@${after}` }
    }
    case 'file_exists': {
      const re = globToRegExp(grader.path)
      const hit = run.createdFiles.some((f) => re.test(f))
      const want = grader.exists ?? true
      return { passed: hit === want, explanation: hit ? `a created file matches ${grader.path}` : `no created file matches ${grader.path}` }
    }
    case 'command': {
      const result = spawnSync('bash', ['-c', grader.run], { cwd: run.workspace, env: run.env, encoding: 'utf8', maxBuffer: 64 << 20, timeout: (grader.timeout_seconds ?? 900) * 1000 })
      const stdoutOk = !grader.stdout_match || new RegExp(grader.stdout_match).test(result.stdout)
      const tail = (result.stdout + result.stderr).trim().split('\n').slice(-5).join(' | ')
      return { passed: result.status === 0 && stdoutOk, explanation: `exit ${result.status}${stdoutOk ? '' : ', stdout did not match'}: ${tail.slice(0, 400)}` }
    }
    default:
      return null
  }
}

// A readable digest of a transcript for the judge: tool calls and results, assistant text and
// hook feedback, truncated per item, keeping the head and tail when it runs long.
export function digest(messages, limit = 60000) {
  const items = []
  for (const m of messages) {
    if (m.type === 'assistant') {
      for (const c of m.message?.content ?? []) {
        if (c.type === 'text') items.push(`ASSISTANT: ${c.text.slice(0, 1500)}`)
        if (c.type === 'tool_use') items.push(`TOOL ${c.name}: ${JSON.stringify(c.input).slice(0, 600)}`)
      }
    } else if (m.type === 'user') {
      const content = m.message?.content
      for (const c of Array.isArray(content) ? content : [{ type: 'text', text: String(content ?? '') }]) {
        if (c.type === 'tool_result') {
          const text = typeof c.content === 'string' ? c.content : (c.content ?? []).map((x) => x.text ?? '').join(' ')
          items.push(`RESULT: ${text.slice(0, 1200)}`)
        } else if (c.type === 'text' && c.text) items.push(`USER/HOOK: ${c.text.slice(0, 1500)}`)
      }
    }
  }
  const all = items.join('\n')
  return all.length <= limit ? all : `${all.slice(0, limit / 2)}\n[… ${all.length - limit} characters cut …]\n${all.slice(-limit / 2)}`
}

// The judge sees what the rubric's `focus` grades. `trace` (the default) gets the digest, the
// final message and the diff; the digest cuts each message at 1,500 characters, so the final
// message, which many rubrics judge, also goes in whole. `last_message` gets the final message
// alone, so earlier turns can't sway a verdict on its shape, plus the diff when the rubric sets
// `diff: true`.
const FOCUSES = ['trace', 'last_message']
export function judgeFocus(grader) {
  const focus = grader.focus ?? 'trace'
  if (!FOCUSES.includes(focus)) throw new Error(`llm grader ${grader.name ?? ''} has focus ${JSON.stringify(focus)}; expected ${FOCUSES.join(' or ')}`)
  return focus
}

export function judgePrompt(grader, run) {
  const focus = judgeFocus(grader)
  const head = `You grade one run of a coding agent against a rubric. Reply with PASS or FAIL on the first line, then 1 or 2 sentences of reason.\n\nRubric:\n${grader.criteria}`
  const final = `Final message, in full:\n${lastMessage(run.messages).slice(0, 20000)}`
  const diff = `Final diff:\n${run.diffText.slice(0, 20000)}`
  const parts = focus === 'trace'
    ? [head, `Run transcript digest:\n${digest(run.messages)}`, final, diff]
    : [head, final, ...(grader.diff === true ? [diff] : [])]
  return parts.join('\n\n')
}

async function gradeLLM(grader, run, opts) {
  const prompt = judgePrompt(grader, run)
  const votes = []
  let cost = 0
  for (let i = 0; i < 3; i++) {
    const out = await runClaude(['-p', prompt, '--output-format', 'json', '--model', opts.judgeModel, '--max-turns', '1', '--tools', '', '--setting-sources', 'project,local', '--no-session-persistence'], { cwd: run.judgeHome, env: { ...run.env, HOME: run.judgeHome }, timeoutMs: 180000 })
    let parsed = {}
    try { parsed = JSON.parse(out.stdout) } catch {}
    cost += parsed.total_cost_usd ?? 0
    const text = String(parsed.result ?? '').trim()
    votes.push({ vote: /^PASS\b/i.test(text) ? 'PASS' : 'FAIL', reason: text.split('\n').slice(1).join(' ').slice(0, 300) || text.slice(0, 300) })
  }
  const passes = votes.filter((v) => v.vote === 'PASS').length
  return { passed: passes >= 2, explanation: `judge votes: ${votes.map((v) => v.vote).join(' ')}; ${votes.find((v) => v.vote === (passes >= 2 ? 'PASS' : 'FAIL'))?.reason ?? ''}`, cost }
}

// A `with-only` grader checks for something only the plugin provides, such as a swiftgate
// verdict, so the `without` arm reports it but doesn't score it.
export const isScored = (grader, arm) => !(grader.arm === 'with-only' && arm === 'without')

export function scoreRun(graders) {
  const scored = graders.filter((g) => g.scored !== false)
  const weight = scored.reduce((s, g) => s + g.weight, 0)
  return {
    score: weight === 0 ? 0 : scored.reduce((s, g) => s + (g.passed ? g.weight : 0), 0) / weight,
    passed: scored.length > 0 && scored.every((g) => g.passed),
  }
}

// --- Running a trial -----------------------------------------------------------------------

function runClaude(args, { cwd, env, timeoutMs }) {
  return new Promise((resolvePromise) => {
    const child = spawn('claude', args, { cwd, env, stdio: ['ignore', 'pipe', 'pipe'] })
    let stdout = ''
    let stderr = ''
    child.stdout.on('data', (d) => { stdout += d })
    child.stderr.on('data', (d) => { stderr += d })
    const timer = setTimeout(() => child.kill('SIGTERM'), timeoutMs)
    child.on('close', (code, signal) => {
      clearTimeout(timer)
      resolvePromise({ stdout, stderr, code, timedOut: signal === 'SIGTERM' })
    })
  })
}

function baseEnv(home) {
  const env = { PATH: process.env.PATH, HOME: home, USER: process.env.USER, LANG: process.env.LANG ?? 'en_US.UTF-8', TERM: 'dumb' }
  for (const key of ['DEVELOPER_DIR', 'ANTHROPIC_API_KEY', 'CLAUDE_CODE_USE_BEDROCK', 'CLAUDE_CODE_USE_VERTEX']) if (process.env[key]) env[key] = process.env[key]
  return env
}

function createdFiles(workspace) {
  const out = spawnSync('git', ['status', '--porcelain', '--untracked-files=all'], { cwd: workspace, encoding: 'utf8' }).stdout
  return out.split('\n').filter((l) => l.startsWith('?? ') || l.startsWith('A ')).map((l) => l.slice(3))
}

async function runTrial(c, arm, trial, opts) {
  const dir = join(opts.raw, c.name, `${arm}-${trial}`)
  mkdirSync(dir, { recursive: true })
  const scratch = mkdtempSync(join(tmpdir(), 'eval-trial-'))
  const home = join(scratch, 'home')
  const workspace = join(home, 'cwd')
  const hooks = join(dir, 'hooks')
  const judgeHome = join(scratch, 'judge-home')
  for (const d of [home, workspace, hooks, judgeHome]) mkdirSync(d, { recursive: true })
  // The shim caches its build under CLAUDE_PLUGIN_DATA when Claude Code sets it, which the
  // scaffold can't know; pin the cache to the one the scaffold seeds, or every hook stays off.
  const env = { ...baseEnv(home), SWIFTGATE_HOOK_RECORD_DIR: hooks, SWIFTGATE_CACHE_DIR: join(home, '.cache/swift-harness') }
  const started = Date.now()
  try {
    if (c.scaffold) execFileSync('bash', [c.scaffold], { cwd: workspace, env, stdio: ['ignore', 'pipe', 'pipe'] })
    const args = ['-p', c.prompt, '--output-format', 'stream-json', '--verbose', '--setting-sources', 'project,local', '--no-session-persistence', '--max-turns', String(c.maxTurns), '--max-budget-usd', String(opts.sessionCost)]
    if (c.allowedTools.length > 0) args.push('--allowedTools', c.allowedTools.join(','))
    if (arm === 'with') args.push('--plugin-dir', join(root, 'plugin'))
    if (opts.model) args.push('--model', opts.model)
    const session = await runClaude(args, { cwd: workspace, env, timeoutMs: c.timeoutSeconds * 1000 })
    writeFileSync(join(dir, 'trace.jsonl'), session.stdout)
    writeFileSync(join(dir, 'stderr.txt'), session.stderr)
    const messages = parseTrace(session.stdout)
    const result = messages.findLast((m) => m.type === 'result') ?? {}
    spawnSync('git', ['add', '-A', '--intent-to-add', '.'], { cwd: workspace })
    const diffText = spawnSync('git', ['diff', '--', '.', ':!.eval', ':!.harness', ':!.build'], { cwd: workspace, encoding: 'utf8', maxBuffer: 64 << 20 }).stdout
    writeFileSync(join(dir, 'diff.patch'), diffText)
    if (c.keep) keepFiles(workspace, c.keep, join(dir, 'kept'))
    const hooksText = readdirSync(hooks).sort().map((f) => `${f}\n${readFileSync(join(hooks, f), 'utf8')}`).join('\n')
    const run = {
      messages, traceText: session.stdout, hooksText, diffText, workspace, env, judgeHome,
      createdFiles: createdFiles(workspace).filter((f) => !f.startsWith('.eval/') && !f.startsWith('.harness/') && !f.includes('/.build/')),
    }
    const graders = []
    let judgeCost = 0
    for (const g of c.graders) {
      let verdict = gradeCode(g, run)
      if (!verdict && g.type === 'llm') {
        verdict = await gradeLLM(g, run, opts)
        judgeCost += verdict.cost
      }
      graders.push({ name: g.name, type: g.type, weight: g.weight, scored: isScored(g, arm), ...(verdict ?? { passed: false, explanation: `unknown grader type ${g.type}` }) })
    }
    const { score, passed } = scoreRun(graders)
    const inactive = arm === 'with' && hooksInactive(session.stdout)
    return {
      arm, trial, score, passed: passed && !inactive,
      error: inactive ? 'hooks inactive: SessionStart says swiftgate is still building, so the trial measured nothing' : session.timedOut ? `timed out after ${c.timeoutSeconds}s` : result.is_error ? result.subtype ?? 'error' : null,
      turns: result.num_turns ?? null, costUsd: result.total_cost_usd ?? 0, judgeCostUsd: judgeCost,
      durationSeconds: Math.round((Date.now() - started) / 1000), hookRecords: readdirSync(hooks).filter((f) => f.endsWith('.outcome.json')).length,
      raw: dir, graders,
    }
  } finally {
    rmSync(scratch, { recursive: true, force: true })
  }
}

// Copies the workspace files whose relative path matches `keep` to `dest`, keeping their paths,
// so a case can score artifacts after the trial's workspace is deleted.
export function keepFiles(workspace, pattern, dest) {
  const walk = (rel) => {
    for (const entry of readdirSync(join(workspace, rel), { withFileTypes: true })) {
      const path = rel ? `${rel}/${entry.name}` : entry.name
      if (entry.isDirectory()) {
        if (entry.name !== '.git' && entry.name !== '.build') walk(path)
      } else if (pattern.test(path)) {
        mkdirSync(dirname(join(dest, path)), { recursive: true })
        writeFileSync(join(dest, path), readFileSync(join(workspace, path)))
      }
    }
  }
  walk('')
}

// A with-plugin trial whose gate was still building ran with every hook off. Its grades describe
// a broken sandbox, not the harness, so it counts as an error.
export function hooksInactive(traceText) {
  return traceText.includes('swiftgate enforcement is warming up')
}

// --- Main ----------------------------------------------------------------------------------

function parseArgs(argv) {
  const opts = { cases: [], runs: null, arms: ['with', 'without'], model: null, judgeModel: 'haiku', maxCost: 10, sessionCost: 3, out: null, raw: null }
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]
    if (a === '--runs') opts.runs = Number(argv[++i])
    else if (a === '--arms') opts.arms = argv[++i].split(',')
    else if (a === '--model') opts.model = argv[++i]
    else if (a === '--judge-model') opts.judgeModel = argv[++i]
    else if (a === '--max-cost-usd') opts.maxCost = Number(argv[++i])
    else if (a === '--session-cost-usd') opts.sessionCost = Number(argv[++i])
    else if (a === '--out') opts.out = argv[++i]
    else if (a === '--raw') opts.raw = argv[++i]
    else opts.cases.push(resolve(a))
  }
  return opts
}

export function summarize(results) {
  return results.map(({ name, arms }) => ({
    name,
    arms: Object.fromEntries(Object.entries(arms).map(([arm, runs]) => [arm, {
      runs: runs.length,
      passed: runs.filter((r) => r.passed).length,
      passAll: runs.length > 0 && runs.every((r) => r.passed),
      meanScore: runs.length ? runs.reduce((s, r) => s + r.score, 0) / runs.length : 0,
      costUsd: runs.reduce((s, r) => s + r.costUsd + r.judgeCostUsd, 0),
    }])),
  }))
}

async function main() {
  const opts = parseArgs(process.argv.slice(2))
  if (opts.cases.length === 0) {
    console.error('usage: node evals/runner/session.mjs <case-dir> ... [--runs n] [--arms with,without] [--max-cost-usd n] [--out dir]')
    process.exit(2)
  }
  const stamp = new Date().toISOString().replace(/[:.]/g, '-')
  opts.raw ??= join(tmpdir(), 'swift-harness-evals', stamp)
  const pins = {
    claudeVersion: execFileSync('claude', ['--version'], { encoding: 'utf8' }).trim(),
    harnessCommit: execFileSync('git', ['rev-parse', '--short', 'HEAD'], { cwd: root, encoding: 'utf8' }).trim(),
    xcode: spawnSync('xcodebuild', ['-version'], { encoding: 'utf8' }).stdout.split('\n')[0],
    model: opts.model ?? 'session default', judgeModel: opts.judgeModel,
  }
  let spent = 0
  let partial = null
  const results = []
  for (const dir of opts.cases) {
    const c = loadCase(dir)
    const entry = { name: c.name, arms: {} }
    results.push(entry)
    for (let trial = 1; trial <= (opts.runs ?? c.runs); trial++) {
      for (const arm of opts.arms) {
        if (spent + opts.sessionCost > opts.maxCost) { partial = `cost ceiling: ${spent.toFixed(2)} spent of ${opts.maxCost}`; break }
        const r = await runTrial(c, arm, trial, opts)
        spent += r.costUsd + r.judgeCostUsd
        ;(entry.arms[arm] ??= []).push(r)
        console.log(`${c.name} ${arm}#${trial}: ${r.passed ? 'PASS' : 'FAIL'} score ${r.score.toFixed(2)} $${(r.costUsd + r.judgeCostUsd).toFixed(2)} ${r.durationSeconds}s${r.error ? ` (${r.error})` : ''}`)
        for (const g of r.graders) console.log(`    ${g.passed ? '✓' : '✗'} ${g.name}: ${String(g.explanation).slice(0, 200)}`)
      }
      if (partial) break
    }
    if (partial) break
  }
  const summary = { pins, partial, costUsd: spent, raw: opts.raw, cases: summarize(results), results }
  const out = opts.out ?? join(opts.raw, 'result')
  mkdirSync(out, { recursive: true })
  writeFileSync(join(out, 'session.json'), JSON.stringify(summary, null, 2) + '\n')
  console.log(`\n${partial ?? 'complete'}; $${spent.toFixed(2)}; result: ${join(out, 'session.json')}; raw: ${opts.raw}`)
}

if (process.argv[1] === fileURLToPath(import.meta.url)) await main()
