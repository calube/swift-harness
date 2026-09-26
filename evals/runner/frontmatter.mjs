// The YAML subset eval cases use in markdown frontmatter: `key: value` lines whose values are
// plain or quoted scalars, numbers, booleans, flow lists `[a, b]` and flow maps `{k: v}`.
// `>` folded blocks are joined into 1 line; `|` literal blocks keep their lines and relative
// indentation. Anything else is an error, not a guess.

export function splitFrontmatter(text) {
  const match = /^---\n([\s\S]*?)\n---\n?([\s\S]*)$/.exec(text)
  if (!match) return { data: {}, body: text.trim() }
  return { data: parseBlock(match[1]), body: match[2].trim() }
}

export function parseBlock(source) {
  const data = {}
  const lines = source.split('\n')
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i]
    if (line.trim() === '' || line.trim().startsWith('#')) continue
    const m = /^([A-Za-z_][\w-]*):\s*(.*)$/.exec(line)
    if (!m) throw new Error(`frontmatter: can't read line "${line}"`)
    let value = m[2]
    if (value === '>' || value === '|') {
      // A block runs while lines are indented or blank; blank lines inside it are kept.
      const block = []
      while (i + 1 < lines.length && (/^\s+\S/.test(lines[i + 1]) || lines[i + 1].trim() === '')) block.push(lines[++i])
      while (block.length > 0 && block.at(-1).trim() === '') block.pop()
      const indent = Math.min(...block.filter((l) => l.trim() !== '').map((l) => /^ */.exec(l)[0].length))
      data[m[1]] = value === '>'
        ? block.map((l) => l.trim()).filter(Boolean).join(' ')
        : block.map((l) => l.slice(indent)).join('\n') + '\n'
      continue
    }
    data[m[1]] = parseValue(value)
  }
  return data
}

export function parseValue(text) {
  const reader = { text: text.trim(), at: 0 }
  const value = readValue(reader, '')
  skipSpace(reader)
  if (reader.at !== reader.text.length) throw new Error(`frontmatter: trailing text in "${text}"`)
  return value
}

function skipSpace(r) {
  while (r.at < r.text.length && r.text[r.at] === ' ') r.at++
}

function readValue(r, stops) {
  skipSpace(r)
  const c = r.text[r.at]
  if (c === '[') return readList(r)
  if (c === '{') return readMap(r)
  if (c === '"') return readDouble(r)
  if (c === "'") return readSingle(r)
  let end = r.at
  while (end < r.text.length && !stops.includes(r.text[end])) end++
  const raw = r.text.slice(r.at, end).trim()
  r.at = end
  if (raw === 'true') return true
  if (raw === 'false') return false
  if (raw === 'null' || raw === '~') return null
  if (/^-?\d+(\.\d+)?$/.test(raw)) return Number(raw)
  return raw
}

function readList(r) {
  r.at++
  const items = []
  for (;;) {
    skipSpace(r)
    if (r.text[r.at] === ']') { r.at++; return items }
    items.push(readValue(r, ',]'))
    skipSpace(r)
    if (r.text[r.at] === ',') r.at++
    else if (r.text[r.at] !== ']') throw new Error(`frontmatter: bad list in "${r.text}"`)
  }
}

function readMap(r) {
  r.at++
  const map = {}
  for (;;) {
    skipSpace(r)
    if (r.text[r.at] === '}') { r.at++; return map }
    const colon = r.text.indexOf(':', r.at)
    if (colon < 0) throw new Error(`frontmatter: bad map in "${r.text}"`)
    const key = r.text.slice(r.at, colon).trim()
    r.at = colon + 1
    map[key] = readValue(r, ',}')
    skipSpace(r)
    if (r.text[r.at] === ',') r.at++
    else if (r.text[r.at] !== '}') throw new Error(`frontmatter: bad map in "${r.text}"`)
  }
}

const ESCAPES = { n: '\n', t: '\t', '"': '"', '\\': '\\', '/': '/' }

function readDouble(r) {
  let out = ''
  for (r.at++; r.at < r.text.length; r.at++) {
    const c = r.text[r.at]
    if (c === '"') { r.at++; return out }
    if (c === '\\') {
      const next = r.text[++r.at]
      if (!(next in ESCAPES)) throw new Error(`frontmatter: unknown escape \\${next} in "${r.text}"`)
      out += ESCAPES[next]
    } else out += c
  }
  throw new Error(`frontmatter: unterminated string in "${r.text}"`)
}

function readSingle(r) {
  let out = ''
  for (r.at++; r.at < r.text.length; r.at++) {
    const c = r.text[r.at]
    if (c === "'") {
      if (r.text[r.at + 1] === "'") { out += "'"; r.at++; continue }
      r.at++
      return out
    }
    out += c
  }
  throw new Error(`frontmatter: unterminated string in "${r.text}"`)
}
