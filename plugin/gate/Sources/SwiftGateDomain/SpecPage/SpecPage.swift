import Foundation

/// A spec page (fast modes §5.2): the 1-page plan source a sprint or a design-free ship builds
/// from, in the format `skills/sprint/references/spec-page.md` sets out.
public struct SpecPage: Sendable, Equatable {
  public let title: String
  /// The spec file the page names on its `Spec:` line, as written.
  public let specPath: String
  public let goal: String
  public let modules: [Module]
  /// 1 entry per `## Surface` bullet, without its marker.
  public let surface: [String]
  public let slices: [Slice]
  /// 1 entry per `## Out of scope` bullet, without its marker.
  public let outOfScope: [String]

  public init(
    title: String, specPath: String, goal: String, modules: [Module], surface: [String],
    slices: [Slice], outOfScope: [String]
  ) {
    self.title = title
    self.specPath = specPath
    self.goal = goal
    self.modules = modules
    self.surface = surface
    self.slices = slices
    self.outOfScope = outOfScope
  }

  /// 1 row of the `## Modules` table.
  public struct Module: Sendable, Equatable {
    public let name: String
    public let kind: ModuleKind
    public let owns: String
    public let dependsOn: String

    public init(name: String, kind: ModuleKind, owns: String, dependsOn: String) {
      self.name = name
      self.kind = kind
      self.owns = owns
      self.dependsOn = dependsOn
    }
  }

  /// What a slice's `Spec:` says: an acceptance line quoted from the spec file, or `none`.
  public enum SpecReference: Sendable, Equatable {
    case quote(String)
    case none
  }

  /// 1 numbered item of `## Slices`, with its 1 acceptance test.
  public struct Slice: Sendable, Equatable {
    public let number: Int
    /// The 1-based page line the slice starts on.
    public let line: Int
    public let testName: String
    /// T1 unless the slice says `Tier: T2` or `Tier: T3`.
    public let tier: Tier
    public let spec: SpecReference

    public init(number: Int, line: Int, testName: String, tier: Tier, spec: SpecReference) {
      self.number = number
      self.line = line
      self.testName = testName
      self.tier = tier
      self.spec = spec
    }

    /// The slice's coverage id: `slice-<number>-<kebab-case test name>`.
    public var id: String { "slice-\(number)-\(SpecPage.kebabCase(testName))" }
  }

  /// Parses `text`, the page's whole contents. Every format problem is reported, not only the
  /// first, and a page with any problem has no parsed value.
  public static func parse(_ text: String) -> SpecPageParse {
    SpecPageParser(text).parse()
  }

  /// `name` in kebab case: camel-case humps and runs of anything but letters and digits become
  /// single hyphens, all lowercase.
  public static func kebabCase(_ name: String) -> String {
    let characters = Array(name)
    var kebab = ""
    var hyphen = false
    for (index, character) in characters.enumerated() {
      guard character.isLetter || character.isNumber else {
        hyphen = true
        continue
      }
      if character.isUppercase, index > 0 {
        let previous = characters[index - 1]
        let next = index + 1 < characters.count ? characters[index + 1] : nil
        // `URLParser` is `url-parser`: an uppercase run ends where a lowercase letter follows.
        if previous.isLowercase || previous.isNumber
          || (previous.isUppercase && next?.isLowercase == true)
        {
          hyphen = true
        }
      }
      if hyphen, !kebab.isEmpty { kebab.append("-") }
      hyphen = false
      kebab.append(contentsOf: character.lowercased())
    }
    return kebab
  }
}

/// The result of parsing a spec page.
public enum SpecPageParse: Sendable, Equatable {
  case parsed(SpecPage)
  case malformed([SpecPageProblem])
}

/// 1 way a page breaks the spec page format.
public struct SpecPageProblem: Sendable, Equatable {
  /// The 1-based page line, or `nil` for a problem with the page as a whole.
  public let line: Int?
  public let message: String

  public init(line: Int?, message: String) {
    self.line = line
    self.message = message
  }
}

/// Reads a page line by line in the order `skills/sprint/references/spec-page.md` sets out.
struct SpecPageParser {
  enum Section: String, CaseIterable {
    case goal = "Goal"
    case modules = "Modules"
    case surface = "Surface"
    case slices = "Slices"
    case outOfScope = "Out of scope"
  }

  struct Line {
    let number: Int
    let text: String
  }

  static let order = Section.allCases.map { "`## \($0.rawValue)`" }.joined(separator: ", ")

  let lines: [Line]
  private var problems: [SpecPageProblem] = []

  init(_ text: String) {
    // `\r\n` is 1 Character, so splitting on `"\n"` alone would leave a CRLF page 1 line.
    lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
      .enumerated().map { Line(number: $0.offset + 1, text: String($0.element)) }
  }

  func parse() -> SpecPageParse {
    var parser = self
    return parser.run()
  }

  private mutating func problem(_ line: Int?, _ message: String) {
    problems.append(SpecPageProblem(line: line, message: message))
  }

  private mutating func run() -> SpecPageParse {
    var index = 0
    while index < lines.count, lines[index].text.trimmed.isEmpty { index += 1 }
    var title: String?
    if index < lines.count, !lines[index].text.hasPrefix("## ") {
      let first = lines[index]
      if first.text.hasPrefix("# "), !first.text.dropFirst(2).trimmed.isEmpty {
        title = first.text.dropFirst(2).trimmed
      } else {
        problem(first.number, "the page's first line must be its title, `# <title>`")
      }
      index += 1
    } else {
      problem(nil, "the page has no title; its first line is `# <title>`")
    }

    var preamble: [Line] = []
    while index < lines.count, !lines[index].text.hasPrefix("## ") {
      preamble.append(lines[index])
      index += 1
    }
    let specPath = self.specPath(preamble)

    var bodies: [Section: (heading: Line, body: [Line])] = [:]
    var current: (section: Section, heading: Line, body: [Line])?
    var lastOrder = -1
    var lastSection: Section?
    func close(_ into: inout [Section: (heading: Line, body: [Line])]) {
      if let current { into[current.section] = (current.heading, current.body) }
    }
    while index < lines.count {
      let line = lines[index]
      index += 1
      guard line.text.hasPrefix("## ") else {
        if current != nil { current?.body.append(line) }
        continue
      }
      close(&bodies)
      current = nil
      let name = line.text.dropFirst(3).trimmed
      guard let section = Section(rawValue: name) else {
        problem(
          line.number, "unknown section `## \(name)`; a spec page has only \(Self.order)")
        continue
      }
      if bodies[section] != nil {
        problem(line.number, "`## \(name)` appears twice")
        continue
      }
      let order = Section.allCases.firstIndex(of: section) ?? 0
      let backwards = order < lastOrder  // swiftgate:equivalent-mutant — equal is a repeat
      if backwards, let lastSection {
        problem(
          line.number,
          "`## \(name)` comes after `## \(lastSection.rawValue)`; the sections run \(Self.order)")
      }
      let forwards = order > lastOrder  // swiftgate:equivalent-mutant — equal is a repeat
      if forwards {
        lastOrder = order
        lastSection = section
      }
      current = (section, line, [])
    }
    close(&bodies)

    for section in Section.allCases where bodies[section] == nil {
      problem(nil, "the page has no `## \(section.rawValue)` section")
    }

    let goal = bodies[.goal].map { self.goal($0.heading, $0.body) } ?? nil
    let modules = bodies[.modules].map { self.modules($0.heading, $0.body) } ?? nil
    let surface = bodies[.surface].map { bullets(.surface, $0.heading, $0.body) } ?? nil
    let slices = bodies[.slices].map { self.slices($0.heading, $0.body) } ?? nil
    let outOfScope = bodies[.outOfScope].map { bullets(.outOfScope, $0.heading, $0.body) } ?? nil

    guard problems.isEmpty, let title, let specPath, let goal, let modules, let surface,
      let slices, let outOfScope
    else {
      return .malformed(problems.sorted { ($0.line ?? 0) < ($1.line ?? 0) })
    }
    return .parsed(
      SpecPage(
        title: title, specPath: specPath, goal: goal, modules: modules, surface: surface,
        slices: slices, outOfScope: outOfScope))
  }

  private mutating func specPath(_ preamble: [Line]) -> String? {
    var path: String?
    for line in preamble where !line.text.trimmed.isEmpty {
      if line.text.hasPrefix("Spec: "), path == nil, !line.text.dropFirst(6).trimmed.isEmpty {
        path = line.text.dropFirst(6).trimmed
      } else {
        problem(
          line.number, "only 1 `Spec: <spec-file>` line goes between the title and `## Goal`")
      }
    }
    if path == nil { problem(nil, "the page has no `Spec: <spec-file>` line under its title") }
    return path
  }

  private mutating func goal(_ heading: Line, _ body: [Line]) -> String? {
    let text = body.map(\.text.trimmed).filter { !$0.isEmpty }.joined(separator: " ")
    if text.isEmpty {
      problem(heading.number, "`## Goal` is empty")
      return nil
    }
    return text
  }

  private static func cells(_ row: String) -> [String] {
    var row = row.trimmed
    if row.hasPrefix("|") { row.removeFirst() }
    if row.hasSuffix("|") { row.removeLast() }
    return row.split(separator: "|", omittingEmptySubsequences: false).map { String($0).trimmed }
  }

  private mutating func modules(_ heading: Line, _ body: [Line]) -> [SpecPage.Module]? {
    let rows = body.filter { !$0.text.trimmed.isEmpty }
    let header = ["Module", "Kind", "Owns", "Depends on"]
    guard rows.count >= 3, rows.allSatisfy({ $0.text.trimmed.hasPrefix("|") }),
      Self.cells(rows[0].text) == header,
      Self.cells(rows[1].text).allSatisfy({ !$0.isEmpty && $0.allSatisfy { "-:".contains($0) } })
    else {
      problem(
        heading.number,
        "`## Modules` is a table headed `| Module | Kind | Owns | Depends on |`, a `|---|` row "
          + "and 1 row per module, with nothing else")
      return nil
    }
    var modules: [SpecPage.Module] = []
    for row in rows.dropFirst(2) {
      let cells = Self.cells(row.text)
      guard cells.count == 4, !cells[0].isEmpty else {
        problem(row.number, "a module row has 4 cells: module, kind, owns, depends on")
        continue
      }
      let kindText = cells[1].replacingOccurrences(of: "`", with: "")
      guard let kind = ModuleKind(rawValue: kindText) else {
        let kinds = ModuleKind.allCases.map(\.rawValue).joined(separator: ", ")
        problem(
          row.number,
          "module `\(cells[0])` has kind `\(kindText)`, which standards.md doesn't list; use "
            + kinds)
        continue
      }
      modules.append(
        SpecPage.Module(name: cells[0], kind: kind, owns: cells[2], dependsOn: cells[3]))
    }
    return modules
  }

  private mutating func bullets(_ section: Section, _ heading: Line, _ body: [Line]) -> [String]? {
    var items: [String] = []
    var fine = true
    for line in body where !line.text.trimmed.isEmpty {
      if line.text.hasPrefix("- ") || line.text.hasPrefix("* ") {
        items.append(line.text.dropFirst(2).trimmed)
      } else if let first = line.text.first, first.isWhitespace, !items.isEmpty {
        items[items.count - 1] += " " + line.text.trimmed
      } else {
        problem(line.number, "`## \(section.rawValue)` holds only `- ` bullets")
        fine = false
      }
    }
    if items.isEmpty, fine {
      problem(heading.number, "`## \(section.rawValue)` lists nothing")
      return nil
    }
    return fine ? items : nil
  }

  private mutating func slices(_ heading: Line, _ body: [Line]) -> [SpecPage.Slice]? {
    var items: [(number: Int, line: Int, text: String)] = []
    var fine = true
    for line in body where !line.text.trimmed.isEmpty {
      if let item = Self.numberedItem(line.text) {
        items.append((item.number, line.number, item.text))
      } else if let first = line.text.first, first.isWhitespace, !items.isEmpty {
        items[items.count - 1].text += " " + line.text.trimmed
      } else {
        problem(line.number, "`## Slices` holds only numbered slices, `1. …`")
        fine = false
      }
    }
    if items.isEmpty, fine {
      problem(heading.number, "`## Slices` lists no slice")
      return nil
    }
    var slices: [SpecPage.Slice] = []
    var firstSlice: [String: Int] = [:]
    for (offset, item) in items.enumerated() {
      if item.number != offset + 1 {
        problem(
          item.line,
          "slice \(item.number) is slice \(offset + 1) of the list; number the slices 1, 2, 3 "
            + "in order")
        fine = false
      }
      guard let slice = slice(item.number, item.line, item.text) else {
        fine = false
        continue
      }
      if let earlier = firstSlice[slice.testName] {
        problem(
          item.line,
          "slice \(item.number) repeats test `\(slice.testName)` from slice \(earlier); each "
            + "slice has its own test")
        fine = false
      } else {
        firstSlice[slice.testName] = item.number
      }
      slices.append(slice)
    }
    return fine ? slices : nil
  }

  private static func numberedItem(_ text: String) -> (number: Int, text: String)? {
    let digits = text.prefix { $0.isASCII && $0.isNumber }
    guard !digits.isEmpty, let number = Int(digits) else { return nil }
    let rest = text.dropFirst(digits.count)
    guard rest.hasPrefix(". ") else { return nil }
    return (number, rest.dropFirst(2).trimmed)
  }

  private mutating func slice(_ number: Int, _ line: Int, _ text: String) -> SpecPage.Slice? {
    let name = "slice \(number)"
    let spec: SpecPage.SpecReference?
    let lead: Substring
    if text.hasSuffix("Spec: none") {
      spec = SpecPage.SpecReference.none
      lead = text.dropLast("Spec: none".count)
    } else if let marker = text.range(of: "Spec: \"") {
      lead = text[..<marker.lowerBound]
      let rest = text[marker.upperBound...]
      if rest.hasSuffix("\""), !rest.dropLast().trimmed.isEmpty {
        spec = .quote(String(rest.dropLast()))
      } else {
        problem(
          line,
          "\(name)'s `Spec:` quotes nothing, or the quote doesn't end the slice: write "
            + "`Spec: \"<the spec file's line>\"` or `Spec: none` last")
        spec = nil
      }
    } else {
      problem(
        line,
        "\(name) has no `Spec: \"<quote>\"` or `Spec: none` at its end; a paraphrase is "
          + "`none`")
      spec = nil
      lead = text[...]
    }

    let tests = Self.tokens(after: "Test: `", in: lead, until: "`")
    if tests.count != 1 {
      problem(
        line, "\(name) has \(tests.count) tests; a slice has exactly 1, written Test: `<name>`")
    }
    let testName = tests.first
    if let testName, SpecPage.kebabCase(testName).isEmpty {
      problem(line, "\(name)'s test name `\(testName)` has no letter or digit")
    }

    var tier = Tier.t1
    let tiers = Self.tokens(after: "Tier: ", in: lead, until: " ")
    if tiers.count > 1 {
      problem(line, "\(name) says `Tier:` \(tiers.count) times; say it once or not at all")
    } else if let written = tiers.first {
      let value =
        written.hasSuffix(".") || written.hasSuffix(",") ? String(written.dropLast()) : written
      if let parsed = Tier(rawValue: value), parsed == .t2 || parsed == .t3 {
        tier = parsed
      } else {
        problem(
          line,
          "\(name) says `Tier: \(written)`; a slice's tier is `T2` or `T3`, or left out "
            + "for T1")
      }
    }

    guard let spec, tests.count == 1, let testName, !SpecPage.kebabCase(testName).isEmpty
    else { return nil }
    return SpecPage.Slice(number: number, line: line, testName: testName, tier: tier, spec: spec)
  }

  /// Each run of text between `start` and the next `end` (or the text's end).
  private static func tokens(after start: String, in text: Substring, until end: Character)
    -> [String]
  {
    var tokens: [String] = []
    var rest = text
    while let marker = rest.range(of: start) {
      let tail = rest[marker.upperBound...]
      let token = tail.prefix { $0 != end }
      tokens.append(String(token))
      rest = tail.dropFirst(token.count)
    }
    return tokens
  }
}

extension StringProtocol {
  fileprivate var trimmed: String {
    String(
      self.drop { $0.isWhitespace }.reversed().drop { $0.isWhitespace }.reversed())
  }
}
