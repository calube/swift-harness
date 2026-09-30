// The blind labelling sheet for the judge's test-quality set (`plugin/gate/Fixtures/judge/`).
//
//   node tests/judge_labelling_sheet.mjs apply    reads the filled-in labelling-sheet.md, writes labels.json
//   node tests/judge_labelling_sheet.mjs render   rewrites labelling-sheet.md with every case, answers blank
//
// `apply` records each answered case with labeller "person" and only the answers given; a blank
// answer leaves that question unlabelled. A case with no answers keeps its entry, or stays out of
// labels.json when it has none. Any answer outside a question's options, a key that matches no
// case, or a case missing from the sheet writes nothing.
import { createHash } from 'node:crypto'
import { existsSync, readdirSync, readFileSync, statSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'

export const applyCommand = 'node tests/judge_labelling_sheet.mjs apply'

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

export function parseSheet(text) {
  const cases = []
  const errors = []
  let current
  let fenceMarker
  for (const line of text.split('\n')) {
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
      current = { number: Number(heading[1]), key: heading[2], tier: undefined, answers: {} }
      cases.push(current)
      continue
    }
    if (!current) continue
    const lives = line.match(/^The subject currently lives in (T[123])\.\s*$/)
    if (lives) {
      current.tier = lives[1]
      continue
    }
    const answer = line.match(/^Answer ([a-z-]+):[ \t]*(.*?)\s*$/)
    if (!answer) continue
    const [, question, value] = answer
    if (!options[question]) errors.push(`case ${current.number}: unknown question ${question}`)
    else if (question in current.answers) errors.push(`case ${current.number}: ${question} answered twice`)
    else current.answers[question] = value
  }
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

// Returns the labels unchanged whenever `errors` is non-empty.
export function applySheet({ labels, sheet, caseIds }) {
  const parsed = parseSheet(sheet)
  const errors = [...parsed.errors]
  const byKey = new Map(caseIds.map((id) => [sheetKey(id), id]))
  const existing = new Map(labels.cases.map((item) => [item.id, item]))
  const answered = new Map()
  const onSheet = new Set()
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
    if (Object.keys(expected).length) {
      answered.set(id, {
        declaredTier: item.tier, expected, id, label: derivedLabel(expected, item.tier), labeller: 'person',
      })
    }
  }
  const unlisted = caseIds.filter((id) => !onSheet.has(id))
  if (unlisted.length) errors.push(`${unlisted.length} cases aren't on the sheet: ${unlisted.join(', ')}`)
  if (errors.length) return { labels, errors, person: 0 }
  const cases = labels.cases.map((item) => answered.get(item.id) ?? item)
  const added = [...answered.values()].filter((item) => !existing.has(item.id))
  const merged = { ...labels, cases: [...cases, ...added] }
  return { labels: merged, errors, person: merged.cases.filter((item) => item.labeller === 'person').length }
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

function main(argv) {
  const root = fileURLToPath(new URL('..', import.meta.url))
  const judge = join(root, 'plugin/gate/Fixtures/judge')
  const labelsPath = join(judge, 'labels.json')
  const sheetPath = join(judge, 'labelling-sheet.md')
  const caseRoot = join(judge, 'cases')
  const caseIds = readdirSync(caseRoot).filter((name) => statSync(join(caseRoot, name)).isDirectory()).sort()
  const labels = JSON.parse(readFileSync(labelsPath, 'utf8'))
  if (argv[0] === 'apply') {
    const result = applySheet({ labels, sheet: readFileSync(sheetPath, 'utf8'), caseIds })
    if (result.errors.length) {
      console.error(`labels.json not written:\n  ${result.errors.join('\n  ')}`)
      return 1
    }
    writeFileSync(labelsPath, formatLabels(result.labels))
    const unlabelled = caseIds.length - result.labels.cases.length
    console.log(`${result.person} person-labelled cases of ${result.labels.cases.length} in labels.json; `
      + `${unlabelled} case directories have no label yet`)
    return 0
  }
  if (argv[0] === 'render') {
    const declared = new Map(labels.cases.map((item) => [item.id, item.declaredTier]))
    if (existsSync(sheetPath)) {
      const byKey = new Map(caseIds.map((id) => [sheetKey(id), id]))
      for (const item of parseSheet(readFileSync(sheetPath, 'utf8')).cases) {
        const id = byKey.get(item.key)
        if (id && item.tier && !declared.has(id)) declared.set(id, item.tier)
      }
    }
    const missing = caseIds.filter((id) => !declared.has(id))
    if (missing.length) {
      console.error(`no current tier for ${missing.join(', ')}: add them to the sheet by hand first`)
      return 1
    }
    const cases = caseIds.map((id) => ({
      id, declaredTier: declared.get(id),
      test: readFileSync(join(caseRoot, id, 'Test.swift.txt'), 'utf8'),
      diff: readFileSync(join(caseRoot, id, 'Change.diff'), 'utf8'),
    }))
    writeFileSync(sheetPath, renderSheet({ labels, cases }))
    console.log(`wrote ${cases.length} cases to labelling-sheet.md`)
    return 0
  }
  console.error('usage: node tests/judge_labelling_sheet.mjs apply | render')
  return 2
}

if (process.argv[1] === fileURLToPath(import.meta.url)) process.exit(main(process.argv.slice(2)))
