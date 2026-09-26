import Foundation

/// A design doc's identity (spec §5.4): the git blob id of the doc with its frontmatter `status:`
/// line removed, so status transitions and the merge strategy leave it unchanged. The stripped
/// content is never stored in git, so a revision is found by hashing history, never by lookup.
public enum DesignSha {
  /// The doc with every frontmatter `status` line removed, terminator included; every other byte
  /// is kept. Frontmatter counts only when the first line is `---` and a later `---` closes it:
  /// an unclosed block is body, and body lines (a `status:` inside a fenced example, say) are
  /// always part of the identity.
  public static func strippingStatus(_ text: String) -> String {
    let lines = DesignLines.split(text)
    guard let closing = DesignLines.frontmatterEnd(lines) else { return text }
    var kept = ""
    for (index, line) in lines.enumerated() {
      if index > 0, index < closing, isStatusLine(line.content) { continue }
      kept += line.raw
    }
    return kept
  }

  public static func of(_ text: String) -> String {
    GitBlobID.of(strippingStatus(text))
  }

  /// Only a top-level key: an indented `status:` is nested YAML content, and stripping it would
  /// let two docs that differ in that content share a sha.
  private static func isStatusLine(_ line: String) -> Bool {
    guard line.hasPrefix("status"), let colon = line.firstIndex(of: ":") else { return false }
    return line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces) == "status"
  }
}

/// How one design revision differs from another (spec §8.4). A change touching a `req-` line,
/// Decision, Module kinds or the Test plan is `amend` and needs re-approval; any other change is
/// `clarify`; identical stripped content is `unchanged`.
public struct DesignDiff: Sendable, Equatable {
  public enum Class: String, Sendable, Equatable, Codable, CaseIterable {
    case unchanged
    case clarify
    case amend
  }

  /// What made a change `amend`.
  public enum Trigger: String, Sendable, Equatable, Codable, CaseIterable {
    /// A line carrying a `req-` id was added, removed or edited, anywhere in the doc.
    case requirementLine = "requirement-line"
    case decision
    case moduleKinds = "module-kinds"
    case testPlan = "test-plan"

    /// Heading anchors (``MarkdownDocument`` slugs) of the sections this trigger protects.
    fileprivate var anchor: String? {
      switch self {
      case .requirementLine: nil
      case .decision: "decision"
      case .moduleKinds: "module-kinds"
      case .testPlan: "test-plan-by-tier"
      }
    }
  }

  public let oldSha: String
  public let newSha: String
  public let changeClass: Class
  /// In ``Trigger`` declaration order; empty unless `changeClass` is `amend`.
  public let triggers: [Trigger]
  /// Sorted, unique `req-`/`test-` ids on the lines that made the change `amend`.
  public let changedIds: [String]

  public init(
    oldSha: String, newSha: String, changeClass: Class, triggers: [Trigger], changedIds: [String]
  ) {
    self.oldSha = oldSha
    self.newSha = newSha
    self.changeClass = changeClass
    self.triggers = triggers
    self.changedIds = changedIds
  }

  public static func compare(old: String, new: String) -> DesignDiff {
    let oldStripped = DesignSha.strippingStatus(old)
    let newStripped = DesignSha.strippingStatus(new)
    let oldSha = GitBlobID.of(oldStripped)
    let newSha = GitBlobID.of(newStripped)
    guard oldSha != newSha else {
      return DesignDiff(
        oldSha: oldSha, newSha: newSha, changeClass: .unchanged, triggers: [], changedIds: [])
    }
    let before = DesignLines.split(oldStripped).map(\.content)
    let after = DesignLines.split(newStripped).map(\.content)

    var triggers: [Trigger] = []
    var ids: Set<String> = []
    for trigger in Trigger.allCases {
      let changed: [String]
      if let anchor = trigger.anchor {
        let oldSection = DesignLines.sectionBodies(before, anchor: anchor)
        let newSection = DesignLines.sectionBodies(after, anchor: anchor)
        guard oldSection != newSection else { continue }
        changed = symmetricDifference(oldSection, newSection)
      } else {
        changed = symmetricDifference(
          before.filter { !DesignIds.requirementIds(in: $0).isEmpty },
          after.filter { !DesignIds.requirementIds(in: $0).isEmpty })
        guard !changed.isEmpty else { continue }
      }
      triggers.append(trigger)
      for line in changed { ids.formUnion(DesignIds.all(in: line)) }
    }
    return DesignDiff(
      oldSha: oldSha, newSha: newSha, changeClass: triggers.isEmpty ? .clarify : .amend,
      triggers: triggers, changedIds: ids.sorted())
  }

  /// Lines present more times on one side than the other, so a reorder alone changes nothing.
  private static func symmetricDifference(_ first: [String], _ second: [String]) -> [String] {
    var counts: [String: Int] = [:]
    for line in first { counts[line, default: 0] += 1 }
    for line in second { counts[line, default: 0] -= 1 }
    return counts.filter { $0.value != 0 }.keys.sorted()
  }
}

/// Re-verifies, link by link, that an approval carried across clarify edits (spec §8.4, the
/// `clarifyChain` of `plan.json` §5.6) never crossed an amend.
public enum ClarifyChain {
  public struct Link: Sendable, Equatable {
    public let fromSha: String
    public let toSha: String

    public init(fromSha: String, toSha: String) {
      self.fromSha = fromSha
      self.toSha = toSha
    }
  }

  public enum Problem: Sendable, Equatable {
    /// The link doesn't start where the approval or the previous link ended.
    case discontinuous(expectedFromSha: String)
    /// No committed revision of the doc hashes to the link's `fromSha`.
    case unknownFromSha
    /// No committed revision of the doc hashes to the link's `toSha`.
    case unknownToSha
    case noChange
    case amend(DesignDiff)
  }

  public struct BrokenLink: Sendable, Equatable {
    /// Zero-based position in the chain.
    public let index: Int
    public let link: Link
    public let problem: Problem

    public init(index: Int, link: Link, problem: Problem) {
      self.index = index
      self.link = link
      self.problem = problem
    }

    public var message: String {
      let name = "link \(index) (\(link.fromSha) → \(link.toSha))"
      switch problem {
      case .discontinuous(let expected):
        return "\(name) starts at \(link.fromSha), but the chain so far ends at \(expected)"
      case .unknownFromSha:
        return "\(name): no committed revision of the design hashes to \(link.fromSha)"
      case .unknownToSha:
        return "\(name): no committed revision of the design hashes to \(link.toSha)"
      case .noChange:
        return "\(name) changes nothing"
      case .amend(let diff):
        let triggers = diff.triggers.map(\.rawValue).joined(separator: ", ")
        let ids = diff.changedIds.isEmpty ? "" : "; ids: " + diff.changedIds.joined(separator: ", ")
        return "\(name) is an amend, not a clarify (\(triggers)\(ids)); it needs re-approval"
      }
    }
  }

  public enum Verification: Sendable, Equatable {
    /// `endSha` is the design the approval now covers.
    case valid(endSha: String)
    case broken(BrokenLink)
  }

  /// `revisions` maps each committed revision's designSha to that revision's full text.
  public static func verify(approvedSha: String, links: [Link], revisions: [String: String])
    -> Verification
  {
    var current = approvedSha
    for (index, link) in links.enumerated() {
      func broken(_ problem: Problem) -> Verification {
        .broken(BrokenLink(index: index, link: link, problem: problem))
      }
      guard link.fromSha == current else { return broken(.discontinuous(expectedFromSha: current)) }
      guard let old = revisions[link.fromSha] else { return broken(.unknownFromSha) }
      guard let new = revisions[link.toSha] else { return broken(.unknownToSha) }
      let diff = DesignDiff.compare(old: old, new: new)
      switch diff.changeClass {
      case .unchanged: return broken(.noChange)
      case .amend: return broken(.amend(diff))
      case .clarify: current = link.toSha
      }
    }
    return .valid(endSha: current)
  }
}

/// Line handling shared by the sha and the diff. Splits on `\n` only and reads a trailing `\r`
/// as part of the terminator, so a CRLF doc parses the same as its LF twin while its bytes are
/// kept exactly.
private enum DesignLines {
  struct Line {
    /// The line with its terminator, byte for byte.
    let raw: String
    /// The line without `\n` or a trailing `\r`.
    let content: String
  }

  static func split(_ text: String) -> [Line] {
    var lines: [Line] = []
    var rest = Substring(text)
    while !rest.isEmpty {
      // `\r\n` is one Character in Swift, so search the scalars, not the characters.
      let scalars = rest.unicodeScalars
      if let newline = scalars.firstIndex(of: "\n") {
        let end = scalars.index(after: newline)
        let raw = String(rest[..<end])
        lines.append(Line(raw: raw, content: contentOf(raw)))
        rest = rest[end...]
      } else {
        lines.append(Line(raw: String(rest), content: contentOf(String(rest))))
        rest = ""
      }
    }
    return lines
  }

  private static func contentOf(_ raw: String) -> String {
    var scalars = Substring(raw).unicodeScalars
    if scalars.last == "\n" { scalars.removeLast() }
    if scalars.last == "\r" { scalars.removeLast() }
    return String(scalars)
  }

  /// Index of the line that closes the frontmatter, or `nil` when there is none.
  static func frontmatterEnd(_ lines: [Line]) -> Int? {
    guard lines.first?.content == "---" else { return nil }
    return lines.indices.dropFirst().first { lines[$0].content == "---" }
  }

  /// The body lines of every heading whose anchor is `anchor`, each running to the next heading
  /// at the same or a higher level; headings inside fences don't count. Several matching
  /// headings concatenate, so adding a second one is a change too.
  static func sectionBodies(_ lines: [String], anchor: String) -> [String] {
    let start = frontmatterEnd(lines.map { Line(raw: $0, content: $0) }).map { $0 + 1 } ?? 0
    var headings: [(index: Int, level: Int, anchor: String)] = []
    var fenceMarker: String?
    for index in lines.indices.dropFirst(start) {
      let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
      if let marker = fenceMarker {
        if trimmed.hasPrefix(marker) { fenceMarker = nil }
      } else if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
        fenceMarker = String(trimmed.prefix(3))
      } else if let heading = heading(lines[index]) {
        headings.append((index, heading.level, slug(heading.text)))
      }
    }
    var body: [String] = []
    for (position, heading) in headings.enumerated() where heading.anchor == anchor {
      let end =
        headings[(position + 1)...].first { $0.level <= heading.level }?.index ?? lines.count
      body += lines[(heading.index + 1)..<end]
    }
    return body
  }

  private static func heading(_ line: String) -> (level: Int, text: String)? {
    let hashes = line.prefix { $0 == "#" }.count
    guard (1...6).contains(hashes) else { return nil }
    let rest = line.dropFirst(hashes)
    guard rest.first == " " else { return nil }
    var text = rest.trimmingCharacters(in: .whitespaces)
    while text.hasSuffix("#") { text.removeLast() }
    return (hashes, text.trimmingCharacters(in: .whitespaces))
  }

  /// The GitHub-style anchor ``MarkdownDocument`` gives a heading.
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

/// `req-`/`test-` ids (spec §5.1) mentioned on a line: lowercase words joined by `-`, not
/// preceded by a letter, digit, `_` or `-`.
private enum DesignIds {
  static func requirementIds(in line: String) -> [String] { ids(in: line, prefixes: ["req-"]) }

  static func all(in line: String) -> [String] { ids(in: line, prefixes: ["req-", "test-"]) }

  private static func ids(in line: String, prefixes: [String]) -> [String] {
    let characters = Array(line)
    var found: [String] = []
    var index = 0
    while index < characters.count {
      let boundary = index == 0 || !isIdCharacter(characters[index - 1])
      if boundary,
        let prefix = prefixes.first(where: { matches($0, characters, at: index) })
      {
        var end = index + prefix.count
        while end < characters.count, isIdCharacter(characters[end]), characters[end] != "_" {
          end += 1
        }
        var id = String(characters[index..<end])
        while id.hasSuffix("-") { id.removeLast() }
        if id.count > prefix.count { found.append(id) }
        index = end
      } else {
        index += 1
      }
    }
    return found
  }

  private static func matches(_ prefix: String, _ characters: [Character], at index: Int) -> Bool {
    let prefixCharacters = Array(prefix)
    guard index + prefixCharacters.count <= characters.count else { return false }
    return Array(characters[index..<(index + prefixCharacters.count)]) == prefixCharacters
  }

  private static func isIdCharacter(_ character: Character) -> Bool {
    (character.isASCII && (character.isLowercase || character.isNumber)) || character == "-"
      || character == "_"
  }
}
