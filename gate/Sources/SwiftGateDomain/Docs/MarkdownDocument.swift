import Foundation

/// A pure, line-oriented parse of one Markdown file: YAML-ish frontmatter, a heading tree, and,
/// per section, its bullets, tables, fenced code blocks and links. There is no dependency on
/// `swift-markdown` — every construct a design doc or plan doc needs (spec §5.3) is line-level, so
/// a small hand-rolled reader keeps `SwiftGateDomain` free of a new external dependency.
public struct MarkdownDocument: Sendable, Equatable {
  /// One list item. `id` is the leading `<kind>-<word>-<word>…:` token spec §5.1 ids use
  /// (`req-…`, `test-…`); `nil` when the bullet has no such prefix. `tags` are every `[…]`
  /// bracketed token in the bullet, in order — spec §5.3 uses this for `[ev-…]` and `[UNVERIFIED]`.
  public struct Bullet: Sendable, Equatable {
    public let text: String
    public let id: String?
    /// `text` with the `"<id>: "` prefix removed, when `id` is present; otherwise equal to `text`.
    public let remainder: String
    public let tags: [String]

    public init(text: String, id: String?, remainder: String, tags: [String]) {
      self.text = text
      self.id = id
      self.remainder = remainder
      self.tags = tags
    }
  }

  /// A fenced code block. `mermaidDiagramType` is the first token of the fence body (`flowchart`,
  /// `sequenceDiagram`, …) when `language == "mermaid"`; `nil` otherwise or when the fence is empty.
  public struct Fence: Sendable, Equatable {
    public let language: String?
    public let body: [String]
    public let mermaidDiagramType: String?

    public init(language: String?, body: [String], mermaidDiagramType: String?) {
      self.language = language
      self.body = body
      self.mermaidDiagramType = mermaidDiagramType
    }
  }

  /// A GFM pipe table: the header row and every data row, cell text trimmed. The separator row
  /// (`|---|---|`) is consumed and not represented.
  public struct Table: Sendable, Equatable {
    public let header: [String]
    public let rows: [[String]]

    public init(header: [String], rows: [[String]]) {
      self.header = header
      self.rows = rows
    }
  }

  /// A Markdown inline link `[text](destination)`. `isRelative` is true unless `destination` names
  /// a URL scheme (`https:`, `mailto:`, …) or is an in-page anchor (`#…`) — spec §5.3's cross-doc
  /// references are repo-relative paths, which `docs-lint` resolves against the doc's directory.
  public struct Link: Sendable, Equatable {
    public let text: String
    public let destination: String
    public let isRelative: Bool

    public init(text: String, destination: String, isRelative: Bool) {
      self.text = text
      self.destination = destination
      self.isRelative = isRelative
    }
  }

  /// One heading and everything under it up to (not including) the next heading at the same or a
  /// shallower level. Headings strictly deeper nest as `subsections`, so `## Options` in the design
  /// template holds `### Option 1` / `### Option 2` as children.
  public struct Section: Sendable, Equatable {
    public let level: Int
    public let heading: String
    /// GitHub-style anchor slug: lower-cased, spaces become `-`, everything but letters, digits,
    /// `-` and `_` is dropped (no other normalisation — this repo only ever slugs its own docs).
    public let anchor: String
    public let bullets: [Bullet]
    public let tables: [Table]
    public let fences: [Fence]
    public let links: [Link]
    /// Word count of this section's own body only (not subsections), excluding fenced code/diagram
    /// lines and table lines — spec §5.3: "Tables, diagrams and code don't count."
    public let proseWordCount: Int
    public let subsections: [Section]

    public init(
      level: Int, heading: String, anchor: String, bullets: [Bullet], tables: [Table],
      fences: [Fence], links: [Link], proseWordCount: Int, subsections: [Section]
    ) {
      self.level = level
      self.heading = heading
      self.anchor = anchor
      self.bullets = bullets
      self.tables = tables
      self.fences = fences
      self.links = links
      self.proseWordCount = proseWordCount
      self.subsections = subsections
    }

    /// Depth-first search of this section and its subsections for `anchor`.
    public func section(anchor target: String) -> Section? {
      if anchor == target { return self }
      for child in subsections {
        if let found = child.section(anchor: target) { return found }
      }
      return nil
    }
  }

  public let frontmatter: [String: String]
  public let sections: [Section]

  public init(frontmatter: [String: String], sections: [Section]) {
    self.frontmatter = frontmatter
    self.sections = sections
  }

  /// Depth-first search across every top-level section for `anchor`.
  public func section(anchor: String) -> Section? {
    for top in sections {
      if let found = top.section(anchor: anchor) { return found }
    }
    return nil
  }

  public static func parse(_ text: String) -> MarkdownDocument {
    var lines = splitLines(text)
    if lines.last == "" { lines.removeLast() }

    var bodyStart = 0
    var frontmatter: [String: String] = [:]
    if let end = frontmatterEnd(lines) {
      for line in lines[1..<end] {
        if let field = parseFrontmatterLine(line) {
          frontmatter[field.key] = field.value
        }
      }
      bodyStart = end < lines.count ? end + 1 : end
    }

    let headings = collectHeadings(in: lines, from: bodyStart)
    let sections = buildSections(lines, headings, headings.indices)
    return MarkdownDocument(frontmatter: frontmatter, sections: sections)
  }

  // MARK: - Line splitting

  /// Splits on `"\n"` and `"\r\n"` as line terminators, discarding the terminator itself so no
  /// line content ever carries a trailing `\r`. Every other matcher in this file compares whole
  /// or prefixed line content (`"---"`, `"#"`, `` "```" ``, table pipes) against `lines`, so fixing
  /// the split here is enough for every construct — no construct-by-construct patching needed.
  ///
  /// Swift's `Character` is an extended grapheme cluster, and Unicode groups an adjacent `\r\n`
  /// into a *single* `Character` — so a `\r` immediately followed by `\n` never appears as two
  /// characters to iterate past. That single combined `Character` is what this checks for `"\r\n"`.
  /// A `\r` that Unicode did *not* fold into a `"\r\n"` cluster (nothing after it, or something
  /// other than `\n`) surfaces as its own standalone `Character` and falls through to ordinary
  /// content, so a lone `\r` mid-line is preserved rather than read as a line break.
  private static func splitLines(_ text: String) -> [String] {
    var lines: [String] = []
    var current = ""
    for character in text {
      if character == "\n" || character == "\r\n" {
        lines.append(current)
        current = ""
      } else {
        current.append(character)
      }
    }
    lines.append(current)
    return lines
  }

  // MARK: - Frontmatter

  /// Index of the closing `---`, or `lines.count` when it is never closed; `nil` without
  /// frontmatter.
  private static func frontmatterEnd(_ lines: [String]) -> Int? {
    guard lines.first == "---" else { return nil }
    var index = 1
    while index < lines.count, lines[index] != "---" { index += 1 }
    return index
  }

  private static func parseFrontmatterLine(_ line: String) -> (key: String, value: String)? {
    guard let colon = line.firstIndex(of: ":") else { return nil }
    let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces)
    guard !key.isEmpty else { return nil }
    var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
    if let commentRange = value.range(of: " #") {
      value = String(value[value.startIndex..<commentRange.lowerBound])
        .trimmingCharacters(in: .whitespaces)
    }
    return (key, value)
  }

  // MARK: - Heading scan (fence-aware)

  private struct HeadingMark {
    let level: Int
    let text: String
    /// Index of the first body line after the heading line itself.
    let bodyStart: Int
  }

  private static func collectHeadings(in lines: [String], from start: Int) -> [HeadingMark] {
    var headings: [HeadingMark] = []
    var fenceMarker: String?
    var index = start
    while index < lines.count {
      let line = lines[index]
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if let marker = fenceMarker {
        if trimmed.hasPrefix(marker) { fenceMarker = nil }
      } else if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
        fenceMarker = String(trimmed.prefix(3))
      } else if let (level, text) = headingComponents(of: line) {
        headings.append(HeadingMark(level: level, text: text, bodyStart: index + 1))
      }
      index += 1
    }
    return headings
  }

  private static func headingComponents(of line: String) -> (level: Int, text: String)? {
    guard line.hasPrefix("#") else { return nil }
    var index = line.startIndex
    var level = 0
    while index < line.endIndex, line[index] == "#" {
      level += 1
      index = line.index(after: index)
    }
    guard level <= 6, index < line.endIndex, line[index] == " " else { return nil }
    var text = String(line[line.index(after: index)...]).trimmingCharacters(in: .whitespaces)
    while text.hasSuffix("#") { text.removeLast() }
    return (level, text.trimmingCharacters(in: .whitespaces))
  }

  // MARK: - Section tree

  private static func buildSections(
    _ lines: [String], _ headings: [HeadingMark], _ range: Range<Int>
  ) -> [Section] {
    var result: [Section] = []
    var index = range.lowerBound
    while index < range.upperBound {
      let heading = headings[index]
      var childEnd = index + 1
      while childEnd < range.upperBound, headings[childEnd].level > heading.level {
        childEnd += 1
      }
      let ownBodyEnd = childEnd < headings.count ? headings[childEnd].bodyStart - 1 : lines.count
      let bodyLines = Array(lines[heading.bodyStart..<max(heading.bodyStart, ownBodyEnd)])
      let subsections = buildSections(lines, headings, (index + 1)..<childEnd)
      result.append(makeSection(heading, bodyLines: bodyLines, subsections: subsections))
      index = childEnd
    }
    return result
  }

  private static func makeSection(
    _ heading: HeadingMark, bodyLines: [String], subsections: [Section]
  ) -> Section {
    let content = SectionContent.parse(bodyLines)
    return Section(
      level: heading.level,
      heading: heading.text,
      anchor: slug(heading.text),
      bullets: content.bullets,
      tables: content.tables,
      fences: content.fences,
      links: content.links,
      proseWordCount: content.proseWordCount,
      subsections: subsections
    )
  }

  private static func slug(_ heading: String) -> String {
    var result = ""
    for character in heading.lowercased() {
      if character.isLetter || character.isNumber || character == "-" || character == "_" {
        result.append(character)
      } else if character == " " {
        result.append("-")
      }
    }
    return result
  }
}

// MARK: - Running prose

extension MarkdownDocument {
  /// One line of running prose, for sentence-level checks. `number` is the 1-based line in the
  /// original file. `text` has its heading, list or blockquote marker removed; inline code spans
  /// and bare URLs are replaced by ``maskedSpan``; link targets and HTML comments are removed.
  /// `startsBlock` is true for a heading, a list item, and the first line after a blank or skipped
  /// line, so a sentence never runs from one block into the next.
  public struct ProseLine: Sendable, Equatable {
    public let number: Int
    public let text: String
    public let startsBlock: Bool

    public init(number: Int, text: String, startsBlock: Bool) {
      self.number = number
      self.text = text
      self.startsBlock = startsBlock
    }
  }

  /// Stands in for masked code or a URL: it still counts as one word, but it has no letters for
  /// a word rule to match.
  public static let maskedSpan: Character = "\u{FFFC}"

  /// Every prose line, skipping frontmatter, fenced code (Mermaid included), tables, HTML comments
  /// and thematic breaks with the same fence and table detection ``parse(_:)`` uses.
  public static func proseLines(_ text: String) -> [ProseLine] {
    var lines = splitLines(text)
    if lines.last == "" { lines.removeLast() }
    var index = 0
    if let end = frontmatterEnd(lines) { index = end + 1 }

    var result: [ProseLine] = []
    var fenceMarker: String?
    var inComment = false
    var startsBlock = true
    while index < lines.count {
      let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
      if let marker = fenceMarker {
        if trimmed.hasPrefix(marker) { fenceMarker = nil }
        index += 1
        continue
      }
      if !inComment, trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
        fenceMarker = String(trimmed.prefix(3))
        startsBlock = true
        index += 1
        continue
      }
      if !inComment, SectionContent.isTableRow(trimmed), index + 1 < lines.count,
        SectionContent.isTableSeparator(lines[index + 1].trimmingCharacters(in: .whitespaces))
      {
        index += 2
        while index < lines.count,
          SectionContent.isTableRow(lines[index].trimmingCharacters(in: .whitespaces))
        {
          index += 1
        }
        startsBlock = true
        continue
      }

      let masked = maskInline(lines[index], inComment: &inComment)
      let content = stripBlockMarker(masked)
      if content.text.isEmpty {
        startsBlock = true
      } else {
        result.append(
          ProseLine(
            number: index + 1, text: content.text,
            startsBlock: startsBlock || content.startsBlock))
        startsBlock = content.isHeading
      }
      index += 1
    }
    return result
  }

  private static func stripBlockMarker(_ line: String) -> (
    text: String, startsBlock: Bool, isHeading: Bool
  ) {
    if let heading = headingComponents(of: line) { return (heading.text, true, true) }
    var text = line.trimmingCharacters(in: .whitespaces)
    if text.count >= 3, text.allSatisfy({ $0 == "-" || $0 == "*" || $0 == "_" }) {
      return ("", true, false)
    }
    while text.hasPrefix(">") {
      text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
    }
    for bullet in ["- ", "* ", "+ "] where text.hasPrefix(bullet) {
      return (String(text.dropFirst(2)).trimmingCharacters(in: .whitespaces), true, false)
    }
    if text == "-" || text == "*" || text == "+" { return ("", true, false) }
    let digits = text.prefix(while: \.isNumber)
    if !digits.isEmpty {
      let rest = text.dropFirst(digits.count)
      if rest.hasPrefix(". ") || rest.hasPrefix(") ") {
        return (String(rest.dropFirst(2)).trimmingCharacters(in: .whitespaces), true, false)
      }
    }
    return (text, false, false)
  }

  /// Masks inline code and bare URLs and drops link targets and HTML comments, carrying an open
  /// comment across lines through `inComment`.
  private static func maskInline(_ line: String, inComment: inout Bool) -> String {
    let characters = Array(line)
    var output = ""
    var index = 0
    func starts(with prefix: String, at position: Int) -> Bool {
      let needle = Array(prefix)
      guard position + needle.count <= characters.count else { return false }
      return Array(characters[position..<position + needle.count]) == needle
    }
    while index < characters.count {
      if inComment {
        if starts(with: "-->", at: index) {
          inComment = false
          output.append(" ")
          index += 3
        } else {
          index += 1
        }
        continue
      }
      let character = characters[index]
      if starts(with: "<!--", at: index) {
        inComment = true
        index += 4
        continue
      }
      if character == "`" {
        let run = characters[index...].prefix(while: { $0 == "`" }).count
        if let close = closingBacktickRun(characters, from: index + run, length: run) {
          output.append(maskedSpan)
          index = close + run
        } else {
          output.append(contentsOf: String(repeating: "`", count: run))
          index += run
        }
        continue
      }
      if character == "]", index + 1 < characters.count, characters[index + 1] == "(",
        let close = characters[(index + 1)...].firstIndex(of: ")")
      {
        output.append("]")
        index = close + 1
        continue
      }
      if starts(with: "http://", at: index) || starts(with: "https://", at: index) {
        output.append(maskedSpan)
        while index < characters.count, !characters[index].isWhitespace,
          characters[index] != ">", characters[index] != ")"
        {
          index += 1
        }
        continue
      }
      output.append(character)
      index += 1
    }
    return output.trimmingCharacters(in: .whitespaces)
  }

  private static func closingBacktickRun(_ characters: [Character], from start: Int, length: Int)
    -> Int?
  {
    var index = start
    while index < characters.count {
      guard characters[index] == "`" else {
        index += 1
        continue
      }
      let run = characters[index...].prefix(while: { $0 == "`" }).count
      if run == length { return index }
      index += run
    }
    return nil
  }
}

/// Parses one section's body lines into bullets, tables, fences, links and a prose word count, in
/// a single pass so fence/table detection and prose counting agree on which lines are which.
private enum SectionContent {
  struct Parsed {
    let bullets: [MarkdownDocument.Bullet]
    let tables: [MarkdownDocument.Table]
    let fences: [MarkdownDocument.Fence]
    let links: [MarkdownDocument.Link]
    let proseWordCount: Int
  }

  static func parse(_ lines: [String]) -> Parsed {
    var bullets: [MarkdownDocument.Bullet] = []
    var tables: [MarkdownDocument.Table] = []
    var fences: [MarkdownDocument.Fence] = []
    var proseWords = 0

    var index = 0
    while index < lines.count {
      let line = lines[index]
      let trimmed = line.trimmingCharacters(in: .whitespaces)

      if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
        let marker = String(trimmed.prefix(3))
        let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
        var body: [String] = []
        index += 1
        while index < lines.count,
          !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(marker)
        {
          body.append(lines[index])
          index += 1
        }
        index += 1  // consume the closing fence, if present
        let lang = language.isEmpty ? nil : language
        let diagramType =
          lang == "mermaid"
          ? body.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) : nil
        fences.append(
          MarkdownDocument.Fence(
            language: lang, body: body,
            mermaidDiagramType: diagramType.map(firstToken)))
        continue
      }

      if isTableRow(trimmed), index + 1 < lines.count,
        isTableSeparator(lines[index + 1].trimmingCharacters(in: .whitespaces))
      {
        let header = tableCells(trimmed)
        var rows: [[String]] = []
        var rowIndex = index + 2
        while rowIndex < lines.count,
          isTableRow(lines[rowIndex].trimmingCharacters(in: .whitespaces))
        {
          rows.append(tableCells(lines[rowIndex].trimmingCharacters(in: .whitespaces)))
          rowIndex += 1
        }
        tables.append(MarkdownDocument.Table(header: header, rows: rows))
        index = rowIndex
        continue
      }

      if trimmed.hasPrefix("- ") || trimmed == "-" {
        let raw = String(trimmed.dropFirst(trimmed.hasPrefix("- ") ? 2 : 1))
          .trimmingCharacters(in: .whitespaces)
        bullets.append(parseBullet(raw))
        proseWords += wordCount(raw)
        index += 1
        continue
      }

      if !trimmed.isEmpty {
        proseWords += wordCount(trimmed)
      }
      index += 1
    }

    let links = extractLinks(lines)
    return Parsed(
      bullets: bullets, tables: tables, fences: fences, links: links, proseWordCount: proseWords)
  }

  private static func firstToken(_ line: String) -> String {
    String(line.trimmingCharacters(in: .whitespaces).split(separator: " ").first ?? "")
  }

  private static func wordCount(_ text: String) -> Int {
    text.split(whereSeparator: \.isWhitespace).count
  }

  fileprivate static func isTableRow(_ line: String) -> Bool {
    line.contains("|")
  }

  fileprivate static func isTableSeparator(_ line: String) -> Bool {
    let cells = tableCells(line)
    guard !cells.isEmpty else { return false }
    return cells.allSatisfy { cell in
      let trimmedCell = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
      return !trimmedCell.isEmpty && trimmedCell.allSatisfy { $0 == "-" }
    }
  }

  private static func tableCells(_ line: String) -> [String] {
    var content = line
    if content.hasPrefix("|") { content.removeFirst() }
    if content.hasSuffix("|") { content.removeLast() }
    return content.split(separator: "|", omittingEmptySubsequences: false)
      .map { $0.trimmingCharacters(in: .whitespaces) }
  }

  private static func parseBullet(_ raw: String) -> MarkdownDocument.Bullet {
    var id: String?
    var remainder = raw
    if let colon = raw.range(of: ": ") ?? matchTrailingColon(raw) {
      let candidate = String(raw[raw.startIndex..<colon.lowerBound])
      if isIdCandidate(candidate) {
        id = candidate
        remainder = String(raw[colon.upperBound...])
      }
    }
    return MarkdownDocument.Bullet(text: raw, id: id, remainder: remainder, tags: extractTags(raw))
  }

  private static func matchTrailingColon(_ raw: String) -> Range<String.Index>? {
    guard raw.hasSuffix(":") else { return nil }
    return raw.index(before: raw.endIndex)..<raw.endIndex
  }

  private static func isIdCandidate(_ candidate: String) -> Bool {
    let parts = candidate.split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count >= 2 else { return false }
    return parts.allSatisfy { part in
      !part.isEmpty && part.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber) }
    }
  }

  private static func extractTags(_ text: String) -> [String] {
    var tags: [String] = []
    var searchStart = text.startIndex
    while let open = text[searchStart...].firstIndex(of: "["),
      let close = text[open...].firstIndex(of: "]")
    {
      tags.append(String(text[text.index(after: open)..<close]))
      searchStart = text.index(after: close)
    }
    return tags
  }

  private static func extractLinks(_ lines: [String]) -> [MarkdownDocument.Link] {
    var links: [MarkdownDocument.Link] = []
    for line in lines {
      var searchStart = line.startIndex
      while let open = line[searchStart...].firstIndex(of: "["),
        let closeText = line[open...].firstIndex(of: "]")
      {
        let afterText = line.index(after: closeText)
        guard afterText < line.endIndex, line[afterText] == "(",
          let closeDest = line[afterText...].firstIndex(of: ")")
        else {
          searchStart = line.index(after: open)
          continue
        }
        let text = String(line[line.index(after: open)..<closeText])
        let destination = String(line[line.index(after: afterText)..<closeDest])
        links.append(
          MarkdownDocument.Link(
            text: text, destination: destination, isRelative: isRelative(destination)))
        searchStart = line.index(after: closeDest)
      }
    }
    return links
  }

  private static func isRelative(_ destination: String) -> Bool {
    if destination.hasPrefix("#") { return false }
    let schemes = ["http://", "https://", "mailto:"]
    return !schemes.contains { destination.hasPrefix($0) }
  }
}
