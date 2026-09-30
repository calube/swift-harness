// The blind labelling sheets for the judge's labelled sets: the test-quality set
// (`plugin/gate/Fixtures/judge/`) and the comment set (`plugin/gate/Fixtures/judge-comments/`).
//
//   node tests/judge_labelling_sheet.mjs apply [set]    reads each filled-in labelling-sheet.md, writes its labels.json
//   node tests/judge_labelling_sheet.mjs apply [set] --labeller agent --from-json <file>
//                                                       applies answers from a file to the sheets in memory
//   node tests/judge_labelling_sheet.mjs render [set]   rewrites each labelling-sheet.md with every case, answers blank
//
// `set` is `test-quality` or `comments`; without it, the command covers both, and `apply` writes
// neither file when either sheet has an error.
//
// `--from-json` reads `{"test-quality": [entry], "comments": [entry]}`, each entry
// `{key, case?, answers: {question: value | null}}` as `fillSheet` takes it, and needs
// `--labeller`, so another labeller's answers are never recorded as a person's by default. It
// never changes a committed label: it prints each answer that disagrees with one and keeps the
// label. The sheets on disk stay as they are.
//
// `apply` records each answered case with its labeller (`person` unless `--labeller agent`) and
// only the answers given; a blank answer leaves that question unlabelled. A case with no answers keeps its entry, or stays out of
// labels.json when it has none. Any answer outside a question's options, a key that matches no
// case, or a case missing from the sheet writes nothing.
import { createHash } from 'node:crypto'
import { existsSync, readdirSync, readFileSync, statSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'

export const applyCommand = 'node tests/judge_labelling_sheet.mjs apply'
export const applyCommentsCommand = `${applyCommand} comments`

const subject = 'a Swift test function from an iOS app built with The Composable Architecture, and the '
  + 'production code change it covers'

// The judge's questions (`JudgeQuestionSet.tests`), word for word; the test holds them to its source.
export const questions = [
  { id: 'fails-if-broken', text: 'Would this test fail if the behavior it names were broken?', options: ['yes', 'no'] },
  {
    id: 'tier',
    text: 'Which tier does this test belong in? T1: host unit test of logic (reducers, pure '
      + 'functions, clients with fakes). T2: simulator test of rendering or platform '
      + 'integration (snapshots, views). T3: end-to-end UI flow (XCUITest).',
    options: ['T1', 'T2', 'T3'],
  },
  {
    id: 'name-specificity',
    text: 'How specific is the regression the test\'s name says it catches? vague: names no '
      + 'symptom or restates the behavior; partial: names an area but not the symptom; '
      + 'specific: names a user- or caller-visible symptom.',
    options: ['vague', 'partial', 'specific'],
  },
  {
    id: 'asserts-implementation',
    text: 'Does the test assert implementation details (private call order, internal state, '
      + 'exact log text, which collaborator was called) rather than observable behavior?',
    options: ['yes', 'no'],
  },
]
const options = Object.fromEntries(questions.map((question) => [question.id, question.options]))
const tiers = ['T1', 'T2', 'T3']

// Salted so the sheet's order and keys are unrelated to the tune/report split, which hashes the bare id.
export function sheetKey(id) {
  return createHash('sha256').update(`labelling-sheet:${id}`).digest('hex').slice(0, 8)
}

function fence(text, language) {
  let ticks = '```'
  while (text.includes(ticks)) ticks += '`'
  return `${ticks}${language}\n${text.trimEnd()}\n${ticks}`
}

// `cases`: [{id, declaredTier, test, diff}]. The ids never appear on the sheet.
export function renderSheet({ cases }) {
  const lines = [
    '# Test-quality labelling sheet',
    '',
    'When every answer is in, turn the sheet into `labels.json` from the repository root with:',
    '',
    '```sh',
    applyCommand,
    '```',
    '',
    'You are labelling blind: each case shows only a test, the production change it covers, and',
    'the tier the test lives in today, exactly as the judge sees them. Case numbers and keys say',
    'nothing about the answer, and the order is arbitrary.',
    '',
    'How to fill it in:',
    '',
    `- The subject of every case is ${subject}.`,
    '- For each case, write one option after each `Answer <question>:` line, exactly as listed',
    '  (`yes`, `no`, `T1`, `T2`, `T3`, `vague`, `partial`, `specific`).',
    '- Leave an answer empty to skip that question for that case. A case with every answer',
    '  empty is skipped entirely.',
    '- Answer from the text shown only. Don\'t open the case directories: their names and the',
    '  existing labels would unblind you.',
    '- Don\'t edit anything outside the answer lines; the `key` on each case heading is how the',
    '  answers find their case.',
    '',
    'The command records every answered case with `labeller: "person"` and refuses the whole sheet',
    'if any answer isn\'t one of its question\'s options.',
    '',
  ]
  const ordered = [...cases].sort((a, b) => sheetKey(a.id).localeCompare(sheetKey(b.id)))
  ordered.forEach((item, index) => {
    lines.push(
      `## Case ${index + 1} · key ${sheetKey(item.id)}`, '',
      `The subject currently lives in ${item.declaredTier}.`, '',
      'Test:', '', fence(item.test, 'swift'), '',
      'Change:', '', fence(item.diff, 'diff'), '',
      'Questions:', '',
      ...questions.map((q) => `- ${q.id}: ${q.text} Options: ${q.options.join(', ')}.`), '',
      ...questions.map((q) => `Answer ${q.id}:`), '',
    )
  })
  return lines.join('\n').trimEnd() + '\n'
}

// Walks the sheet's case sections, skipping fenced text, and hands every other line of a case to
// `onLine(current, line, index)`; `start(number, key)` makes the object that holds a case's parse.
function scanSheet(text, start, onLine) {
  const cases = []
  let current
  let fenceMarker
  for (const [index, line] of text.split('\n').entries()) {
    const trimmed = line.trim()
    if (fenceMarker) {
      if (trimmed === fenceMarker) fenceMarker = undefined
      continue
    }
    const opening = trimmed.match(/^(`{3,})/)
    if (opening) {
      fenceMarker = opening[1]
      continue
    }
    const heading = line.match(/^## Case (\d+) · key ([0-9a-f]{8})\s*$/)
    if (heading) {
      current = start(Number(heading[1]), heading[2])
      cases.push(current)
      continue
    }
    if (current) onLine(current, line, index)
  }
  return cases
}

// Records `Answer <question>: <value>` into `current.answers`, or an error for an unknown or
// repeated question.
function readAnswer(current, line, known, errors) {
  const answer = line.match(/^Answer ([a-z-]+):[ \t]*(.*?)\s*$/)
  if (!answer) return
  const [, question, value] = answer
  if (!known[question]) errors.push(`case ${current.number}: unknown question ${question}`)
  else if (question in current.answers) errors.push(`case ${current.number}: ${question} answered twice`)
  else current.answers[question] = value
}

export function parseSheet(text) {
  const errors = []
  const cases = scanSheet(
    text,
    (number, key) => ({ number, key, tier: undefined, answers: {} }),
    (current, line) => {
      const lives = line.match(/^The subject currently lives in (T[123])\.\s*$/)
      if (lives) current.tier = lives[1]
      else readAnswer(current, line, options, errors)
    },
  )
  return { cases, errors }
}

// Any flag the person's answers raise makes the case useless, matching the existing labels.
function derivedLabel(expected, declaredTier) {
  const fires = expected['fails-if-broken'] === 'no'
    || expected['asserts-implementation'] === 'yes'
    || expected['name-specificity'] === 'vague'
    || ('tier' in expected && expected.tier !== declaredTier)
  return fires ? 'useless' : 'good'
}

// With `keepExisting`, a question the case already has a label for keeps it, and each answer
// that disagrees adds a line to `kept`. Returns the expected answers to record, or undefined when
// the existing entry stays as it is. Adding answers to an entry by another labeller is an error,
// since one entry has one labeller.
function keepExistingAnswers({ existing, expected, labeller, where, kept, errors }) {
  const added = {}
  for (const [question, value] of Object.entries(expected)) {
    const old = existing.expected[question]
    if (old === undefined) added[question] = value
    else if (old !== value) kept.push(`kept existing ${existing.id}/${question}: ${old}, input ${value}`)
  }
  if (!Object.keys(added).length) return undefined
  const oldLabeller = existing.labeller ?? 'agent'
  if (oldLabeller !== labeller) {
    errors.push(`${where}: ${existing.id} holds ${oldLabeller} labels, so ${labeller} answers can't join them`)
    return undefined
  }
  return { ...existing.expected, ...added }
}

// Returns the labels unchanged whenever `errors` is non-empty.
export function applySheet({ labels, sheet, caseIds, labeller = 'person', keepExisting = false }) {
  const parsed = parseSheet(sheet)
  const errors = [...parsed.errors]
  const byKey = new Map(caseIds.map((id) => [sheetKey(id), id]))
  const existing = new Map(labels.cases.map((item) => [item.id, item]))
  const answered = new Map()
  const onSheet = new Set()
  const kept = []
  for (const item of parsed.cases) {
    const where = `case ${item.number} (key ${item.key})`
    const id = byKey.get(item.key)
    if (!id) {
      errors.push(`${where}: no case directory has this key`)
      continue
    }
    onSheet.add(id)
    if (!tiers.includes(item.tier)) {
      errors.push(`${where}: the "currently lives in" line is missing or changed`)
      continue
    }
    if (existing.has(id) && existing.get(id).declaredTier !== item.tier) {
      errors.push(`${where}: the sheet's tier ${item.tier} disagrees with labels.json`)
      continue
    }
    const missing = questions.map((q) => q.id).filter((q) => !(q in item.answers))
    if (missing.length) {
      errors.push(`${where}: the answer lines for ${missing.join(', ')} are gone`)
      continue
    }
    const expected = {}
    for (const [question, value] of Object.entries(item.answers)) {
      if (value === '') continue
      if (!options[question].includes(value)) {
        errors.push(`${where}: ${question} is '${value}', not one of ${options[question].join(', ')}`)
        continue
      }
      expected[question] = value
    }
    const recorded = keepExisting && existing.has(id)
      ? keepExistingAnswers({ existing: existing.get(id), expected, labeller, where, kept, errors })
      : expected
    if (recorded && Object.keys(recorded).length) {
      answered.set(id, {
        declaredTier: item.tier, expected: recorded, id, label: derivedLabel(recorded, item.tier), labeller,
      })
    }
  }
  const unlisted = caseIds.filter((id) => !onSheet.has(id))
  if (unlisted.length) errors.push(`${unlisted.length} cases aren't on the sheet: ${unlisted.join(', ')}`)
  if (errors.length) return { labels, errors, kept, person: 0 }
  const cases = labels.cases.map((item) => answered.get(item.id) ?? item)
  const added = [...answered.values()].filter((item) => !existing.has(item.id))
  const merged = { ...labels, cases: [...cases, ...added] }
  return { labels: merged, errors, kept, person: merged.cases.filter((item) => item.labeller === 'person').length }
}

// The comment judge's questions (`JudgeQuestionSet.comments`), word for word; the test holds them
// to its source.
export const commentQuestions = [
  {
    id: 'loses-fact',
    text: 'If this comment were deleted, would a reader lose a fact they cannot recover from the '
      + 'code (a non-obvious why, a footgun warning, a contract, a suppression reason)?',
    options: ['yes', 'no'],
  },
  {
    id: 'right-size',
    text: 'Is the comment the right size for the fact it carries (no restated code, no history '
      + 'narration, no padding)?',
    options: ['yes', 'no'],
  },
]
const commentOptions = Object.fromEntries(commentQuestions.map((question) => [question.id, question.options]))
const commentSubject = 'a comment added to Swift source, with the code around it'

// `cases`: [{id, commit, path, comment, context}]: the comment exactly as the commit added it and
// the 6 lines after it, the state the commit hook's judge sends. The ids never appear on the sheet;
// the commit and path appear only on each case's `Source:` line, the one record of where it came from.
export function renderCommentSheet({ cases }) {
  const lines = [
    '# Comment labelling sheet',
    '',
    'When every answer is in, turn the sheet into `labels.json` from the repository root with:',
    '',
    '```sh',
    applyCommentsCommand,
    '```',
    '',
    'You are labelling blind: each case shows only a comment a commit added to this repository\'s',
    'Swift, and the 6 lines of code after it, exactly as the commit hook\'s judge sees them. Case',
    'numbers and keys say nothing about the answer, and the order is arbitrary.',
    '',
    'How to fill it in:',
    '',
    `- The subject of every case is ${commentSubject}.`,
    '- For each case, write `yes` or `no` after each `Answer <question>:` line.',
    '- Leave an answer empty to skip that question for that case. A case with every answer',
    '  empty is skipped entirely.',
    '- Answer from the text shown only. The `Source:` line names the commit and file each comment',
    '  came from so the set can be checked against history; you don\'t need to open them.',
    '- Don\'t open the case directories, and don\'t edit anything outside the answer lines: the',
    '  `key` on each case heading is how the answers find their case, and the `Source:` line must',
    '  stay as it is.',
    '',
    'The command records every answered case with `labeller: "person"` and refuses the whole sheet',
    'if any answer isn\'t `yes` or `no`.',
    '',
  ]
  const ordered = [...cases].sort((a, b) => sheetKey(a.id).localeCompare(sheetKey(b.id)))
  ordered.forEach((item, index) => {
    lines.push(
      `## Case ${index + 1} · key ${sheetKey(item.id)}`, '',
      'Comment:', '', fence(item.comment, 'swift'), '',
      'The code after it:', '', fence(item.context, 'swift'), '',
      'Questions:', '',
      ...commentQuestions.map((q) => `- ${q.id}: ${q.text} Options: ${q.options.join(', ')}.`), '',
      ...commentQuestions.map((q) => `Answer ${q.id}:`), '',
      `Source: ${item.commit} ${item.path}`, '',
    )
  })
  return lines.join('\n').trimEnd() + '\n'
}

export function parseCommentSheet(text) {
  const errors = []
  const cases = scanSheet(
    text,
    (number, key) => ({ number, key, source: undefined, answers: {} }),
    (current, line) => {
      const source = line.match(/^Source: ([0-9a-f]{40}) (\S+)\s*$/)
      if (source) current.source = { commit: source[1], path: source[2] }
      else readAnswer(current, line, commentOptions, errors)
    },
  )
  return { cases, errors }
}

// Returns the labels unchanged whenever `errors` is non-empty.
export function applyCommentSheet({ labels, sheet, caseIds, labeller = 'person', keepExisting = false }) {
  const parsed = parseCommentSheet(sheet)
  const errors = [...parsed.errors]
  const byKey = new Map(caseIds.map((id) => [sheetKey(id), id]))
  const existing = new Map(labels.cases.map((item) => [item.id, item]))
  const answered = new Map()
  const onSheet = new Set()
  const kept = []
  for (const item of parsed.cases) {
    const where = `case ${item.number} (key ${item.key})`
    const id = byKey.get(item.key)
    if (!id) {
      errors.push(`${where}: no case directory has this key`)
      continue
    }
    onSheet.add(id)
    if (!item.source) {
      errors.push(`${where}: the source line is missing or changed`)
      continue
    }
    const missing = commentQuestions.map((q) => q.id).filter((q) => !(q in item.answers))
    if (missing.length) {
      errors.push(`${where}: the answer lines for ${missing.join(', ')} are gone`)
      continue
    }
    const expected = {}
    for (const [question, value] of Object.entries(item.answers)) {
      if (value === '') continue
      if (!commentOptions[question].includes(value)) {
        errors.push(`${where}: ${question} is '${value}', not one of ${commentOptions[question].join(', ')}`)
        continue
      }
      expected[question] = value
    }
    const recorded = keepExisting && existing.has(id)
      ? keepExistingAnswers({ existing: existing.get(id), expected, labeller, where, kept, errors })
      : expected
    if (recorded && Object.keys(recorded).length) answered.set(id, { expected: recorded, id, labeller })
  }
  const unlisted = caseIds.filter((id) => !onSheet.has(id))
  if (unlisted.length) errors.push(`${unlisted.length} cases aren't on the sheet: ${unlisted.join(', ')}`)
  if (errors.length) return { labels, errors, kept, person: 0 }
  const cases = labels.cases.map((item) => answered.get(item.id) ?? item)
  // In id order, so the file doesn't depend on the sheet's order.
  const added = [...answered.values()].filter((item) => !existing.has(item.id)).sort((a, b) => a.id.localeCompare(b.id))
  const merged = { ...labels, cases: [...cases, ...added] }
  return { labels: merged, errors, kept, person: merged.cases.filter((item) => item.labeller === 'person').length }
}

// Writes each entry's answers onto the answer lines of the sheet case with its `key`: entries are
// `{key, case?, answers: {question: value | null}}`, and a null answer stays blank, so the
// question is skipped. Refuses a key or case number the sheet lacks, a question the case doesn't
// ask, a key given twice, and an answer line that already holds a value.
export function fillSheet(sheet, entries) {
  const errors = []
  const lines = sheet.split('\n')
  const found = new Map()
  scanSheet(
    sheet,
    (number, key) => {
      const current = { number, key, answerLines: {} }
      found.set(key, current)
      return current
    },
    (current, line, index) => {
      const answer = line.match(/^Answer ([a-z-]+):[ \t]*(.*?)\s*$/)
      if (answer) current.answerLines[answer[1]] = { index, value: answer[2] }
    },
  )
  const seen = new Set()
  for (const entry of entries) {
    const current = found.get(entry.key)
    if (!current) {
      errors.push(`key ${entry.key}: no case on the sheet has this key`)
      continue
    }
    if (seen.has(entry.key)) {
      errors.push(`key ${entry.key}: given twice`)
      continue
    }
    seen.add(entry.key)
    if (entry.case !== undefined && entry.case !== current.number) {
      errors.push(`key ${entry.key}: case number ${entry.case}, but the sheet has it as case ${current.number}`)
      continue
    }
    for (const [question, value] of Object.entries(entry.answers ?? {})) {
      const target = current.answerLines[question]
      if (!target) errors.push(`key ${entry.key}: the case asks no question ${question}`)
      else if (value !== null && typeof value !== 'string') errors.push(`key ${entry.key}: ${question} isn't text or null`)
      else if (target.value !== '') errors.push(`key ${entry.key}: ${question} is already answered on the sheet`)
      else if (value !== null) lines[target.index] = `Answer ${question}: ${value}`
    }
  }
  return { sheet: errors.length ? sheet : lines.join('\n'), errors }
}

function sortedKeys(value) {
  if (Array.isArray(value)) return value.map(sortedKeys)
  if (value && typeof value === 'object') {
    return Object.fromEntries(Object.keys(value).sort().map((key) => [key, sortedKeys(value[key])]))
  }
  return value
}

// The committed file's layout: 2-space indent, keys sorted, trailing newline.
export function formatLabels(labels) {
  return JSON.stringify(sortedKeys(labels), null, 2) + '\n'
}

function caseDirectories(caseRoot) {
  return readdirSync(caseRoot).filter((name) => statSync(join(caseRoot, name)).isDirectory()).sort()
}

// Each set's directory, and how its sheet applies and renders. Neither writes a file, so a bare
// `apply` can refuse both files when either sheet has an error.
function sets(root) {
  return {
    'test-quality': {
      directory: join(root, 'plugin/gate/Fixtures/judge'),
      apply: applySheet,
      render({ labels, sheetPath, caseRoot, caseIds }) {
        const declared = new Map(labels.cases.map((item) => [item.id, item.declaredTier]))
        if (existsSync(sheetPath)) {
          const byKey = new Map(caseIds.map((id) => [sheetKey(id), id]))
          for (const item of parseSheet(readFileSync(sheetPath, 'utf8')).cases) {
            const id = byKey.get(item.key)
            if (id && item.tier && !declared.has(id)) declared.set(id, item.tier)
          }
        }
        const missing = caseIds.filter((id) => !declared.has(id))
        if (missing.length) return { error: `no current tier for ${missing.join(', ')}: add them to the sheet by hand first` }
        const cases = caseIds.map((id) => ({
          id, declaredTier: declared.get(id),
          test: readFileSync(join(caseRoot, id, 'Test.swift.txt'), 'utf8'),
          diff: readFileSync(join(caseRoot, id, 'Change.diff'), 'utf8'),
        }))
        return { sheet: renderSheet({ labels, cases }) }
      },
    },
    comments: {
      directory: join(root, 'plugin/gate/Fixtures/judge-comments'),
      apply: applyCommentSheet,
      render({ sheetPath, caseRoot, caseIds }) {
        // The commit and path live only on the sheet, so a re-render carries them over.
        const sources = new Map()
        if (existsSync(sheetPath)) {
          const byKey = new Map(caseIds.map((id) => [sheetKey(id), id]))
          for (const item of parseCommentSheet(readFileSync(sheetPath, 'utf8')).cases) {
            const id = byKey.get(item.key)
            if (id && item.source) sources.set(id, item.source)
          }
        }
        const missing = caseIds.filter((id) => !sources.has(id))
        if (missing.length) return { error: `no source for ${missing.join(', ')}: add them to the sheet by hand first` }
        const cases = caseIds.map((id) => ({
          id, ...sources.get(id),
          comment: readFileSync(join(caseRoot, id, 'Test.swift.txt'), 'utf8'),
          context: readFileSync(join(caseRoot, id, 'Change.diff'), 'utf8'),
        }))
        return { sheet: renderCommentSheet({ cases }) }
      },
    },
  }
}

const labellers = ['person', 'agent']
const usage = 'usage: node tests/judge_labelling_sheet.mjs apply [test-quality | comments] '
  + '[--labeller person | agent] [--from-json <file>] | render [test-quality | comments]'

// Splits `argv` into the command, the optional set and the flags; `undefined` when it doesn't parse.
function parseArguments(argv, setNames) {
  const [command, ...rest] = argv
  const flags = {}
  const positional = []
  while (rest.length) {
    const word = rest.shift()
    if (word === '--labeller' || word === '--from-json') {
      if (!rest.length || word.slice(2) in flags) return undefined
      flags[word.slice(2)] = rest.shift()
    } else positional.push(word)
  }
  if (!['apply', 'render'].includes(command) || positional.length > 1) return undefined
  const [only] = positional
  if (only !== undefined && !setNames.includes(only)) return undefined
  if (command === 'render' && Object.keys(flags).length) return undefined
  if (flags.labeller !== undefined && !labellers.includes(flags.labeller)) return undefined
  if (flags['from-json'] !== undefined && flags.labeller === undefined) return undefined
  return { command, only, labeller: flags.labeller ?? 'person', fromJson: flags['from-json'] }
}

function main(argv) {
  const all = sets(fileURLToPath(new URL('..', import.meta.url)))
  const parsed = parseArguments(argv, Object.keys(all))
  if (!parsed) {
    console.error(usage)
    return 2
  }
  const { command, only, labeller, fromJson } = parsed
  const files = Object.entries(all).filter(([name]) => only === undefined || name === only).map(([name, set]) => {
    const caseRoot = join(set.directory, 'cases')
    return {
      name, set, caseRoot,
      labelsPath: join(set.directory, 'labels.json'),
      sheetPath: join(set.directory, 'labelling-sheet.md'),
      caseIds: caseDirectories(caseRoot),
    }
  })
  if (command === 'apply') {
    const answers = fromJson === undefined ? undefined : JSON.parse(readFileSync(fromJson, 'utf8'))
    const unknownSets = Object.keys(answers ?? {}).filter((name) => !all[name])
    if (unknownSets.length) {
      console.error(`${fromJson}: no set named ${unknownSets.join(', ')}`)
      return 1
    }
    const results = files.map((file) => {
      let sheet = readFileSync(file.sheetPath, 'utf8')
      if (answers) {
        const filled = fillSheet(sheet, answers[file.name] ?? [])
        if (filled.errors.length) return { file, result: { errors: filled.errors } }
        sheet = filled.sheet
      }
      const labels = JSON.parse(readFileSync(file.labelsPath, 'utf8'))
      return {
        file, result: file.set.apply({ labels, sheet, caseIds: file.caseIds, labeller, keepExisting: answers !== undefined }),
      }
    })
    const failed = results.filter(({ result }) => result.errors.length)
    if (failed.length) {
      for (const { file, result } of failed) {
        console.error(`${file.name}: labels.json not written:\n  ${result.errors.join('\n  ')}`)
      }
      if (results.length > failed.length) console.error('no labels.json written, since a sheet has an error')
      return 1
    }
    for (const { file, result } of results) {
      for (const line of result.kept) console.log(`${file.name}: ${line}`)
      writeFileSync(file.labelsPath, formatLabels(result.labels))
      const unlabelled = file.caseIds.length - result.labels.cases.length
      const byLabeller = labellers.map((name) => {
        const count = result.labels.cases.filter((item) => (item.labeller ?? 'agent') === name).length
        return `${count} ${name}-labelled`
      })
      console.log(`${file.name}: ${byLabeller.join(', ')} cases of ${result.labels.cases.length} in `
        + `labels.json; ${unlabelled} case directories have no label yet`)
    }
    return 0
  }
  for (const file of files) {
    const labels = JSON.parse(readFileSync(file.labelsPath, 'utf8'))
    const rendered = file.set.render({ labels, sheetPath: file.sheetPath, caseRoot: file.caseRoot, caseIds: file.caseIds })
    if (rendered.error) {
      console.error(`${file.name}: ${rendered.error}`)
      return 1
    }
    writeFileSync(file.sheetPath, rendered.sheet)
    console.log(`${file.name}: wrote ${file.caseIds.length} cases to labelling-sheet.md`)
  }
  return 0
}

if (process.argv[1] === fileURLToPath(import.meta.url)) process.exit(main(process.argv.slice(2)))
