import Foundation

/// `docs-lint`'s reference-integrity, relative-link and router-reachability families (spec §6.2):
///
/// | Family | Check |
/// |---|---|
/// | Reference integrity | every `req-`/`test-`/`ev-` id mentioned resolves; a bare `ADR NNNN` mention is flagged unless linked; every requirement is cited outside its defining doc |
/// | Relative links | every relative link — any extension, or none — resolves against the repo's tracked files |
/// | Router reachability | every `docs/` doc is reachable from `docs/index.md` |
///
/// Unlike ``DesignLintSections`` and its siblings, this rule reads the *whole* docs corpus at
/// once — reference integrity and reachability are cross-file by nature — so the input is every
/// file's path and raw text (§5.10's "no IO in the domain": the FS read lives in the CLI's
/// `DocsTreeReader` adapter, not here). Two decisions worth stating for later readers:
///
/// - **Anchors are never checked.** Spec §6.2 says only "every relative link resolves" — nothing
///   about the `#fragment` a link may carry. This rule confirms the linked *file* or *directory*
///   exists and leaves the fragment unverified, on both `path#anchor` and bare `#anchor` links.
/// - **Every relative link is checked, not just `.md`.** Docs cite repo files (source, images,
///   directories) by relative path just as often as they cite other docs, so a link resolves
///   against `repoPaths` — every tracked file, repo-relative, that `docs-lint-command` supplies
///   from `git ls-files` — not just the docs corpus. A link whose destination ends in `/`, or
///   whose last path segment has no `.`, is a *directory* link: it resolves when some tracked
///   file has that directory as a path prefix. Anything else is a *file* link: it resolves only
///   when its exact path is tracked. `.md` links additionally feed router reachability below,
///   which needs the narrower docs corpus (`files`), not every tracked file.
///
/// `MarkdownDocument`'s own `Section.links` includes links written inside fenced code (nothing
/// filters them there), so this rule does its own fence- and inline-code-aware scan rather than
/// trust that list — a link or `req-`/`test-`/`ev-`/`ADR` mention inside a fence or inline code
/// must never be treated as a real reference.
public enum DocsLintReferences {
  /// The docs corpus: ``DocsLintPolicy/ScannedDocument`` (`path`, `rawText`, `markdown`) — the one
  /// corpus type `docs-lint` reads the whole docs tree into, built once by `docs-lint-command`'s
  /// `DocsTreeReader` adapter and shared with ``DocsLintPolicy``.
  public typealias DocFile = DocsLintPolicy.ScannedDocument

  /// spec §6.2: "every doc reachable from `docs/index.md`".
  public static let routerRoot = "docs/index.md"

  public static func check(
    files: [DocFile], claims: [Claim] = [], repoPaths: Set<String>
  ) throws(ReportContractViolation) -> [Finding] {
    let scans = files.map(DocScan.init)
    let pathSet = Set(files.map(\.path))
    let resolutions = resolvedLinks(scans: scans, repoPaths: repoPaths)

    var findings: [Finding] = []
    try findings.append(contentsOf: danglingIDFindings(scans: scans, claims: claims))
    try findings.append(contentsOf: adrFindings(scans: scans))
    try findings.append(contentsOf: requirementUncitedFindings(scans: scans))
    try findings.append(contentsOf: relativeLinkFindings(resolutions: resolutions))
    try findings.append(
      contentsOf: reachabilityFindings(resolutions: resolutions, pathSet: pathSet))
    return findings
  }

  // MARK: - Reference integrity: dangling ids

  /// A `req-`/`test-` id is dangling when no file in the corpus *defines* it (a `- <id>: ` bullet,
  /// regardless of D18 word-count validity — ``DesignLintSections`` owns that check). An `ev-` id
  /// is never defined by a doc bullet; it's dangling unless it names a claim in `claims`, the
  /// input spec §5.2 evidence tags cite (never read from disk here — claims are an input).
  private static func danglingIDFindings(
    scans: [DocScan], claims: [Claim]
  ) throws(ReportContractViolation) -> [Finding] {
    let definedReqTest = scans.reduce(into: Set<String>()) { $0.formUnion($1.definedIDs) }
    let claimIDs = Set(claims.map(\.id))

    var findings: [Finding] = []
    for scan in scans {
      // Every mention matches `(?:req|test|ev)-…` (``DocScan``'s mention pattern), so exactly one
      // of these two branches applies — there is no third id shape to fall through to.
      for id in scan.mentionedIDs.sorted() {
        let dangling =
          id.hasPrefix("ev-") ? !claimIDs.contains(id) : !definedReqTest.contains(id)
        guard dangling else { continue }
        findings.append(
          try Finding(
            ruleID: "docs-lint.dangling-id", severity: .major, file: scan.path,
            line: scan.firstMentionLine[id],
            message:
              "\"\(id)\" has no matching definition or claim (spec §6.2 reference integrity).",
            failureScenario: nil))
      }
    }
    return findings
  }

  // MARK: - Reference integrity: bare ADR mentions

  /// spec §6.2: "ADR references carry number and title" — enforced here as "a bare `ADR NNNN`
  /// mention is flagged; one that's part of a link isn't" (the link itself is checked by the
  /// relative-link family when it's relative).
  private static func adrFindings(scans: [DocScan]) throws(ReportContractViolation) -> [Finding] {
    let adrMention = #/ADR\s+\d{4}\b/#
    var findings: [Finding] = []
    for scan in scans {
      for (index, (line, lineLinks)) in zip(scan.scanLines, scan.linksPerLine).enumerated() {
        for match in line.matches(of: adrMention) {
          let isLinked = lineLinks.contains { $0.textRange.overlaps(match.range) }
          guard !isLinked else { continue }
          findings.append(
            try Finding(
              ruleID: "docs-lint.bare-adr-reference", severity: .major, file: scan.path,
              line: index + 1,
              message:
                "\"\(line[match.range])\" references an ADR by number without linking to it "
                + "(spec §6.2 reference integrity).",
              failureScenario: nil))
        }
      }
    }
    return findings
  }

  // MARK: - Reference integrity: requirement cited nowhere else

  /// "Nowhere else" means outside the doc that defines the id — a requirement mentioned only
  /// inside its own defining doc (including a second mention there) is still flagged; one
  /// mentioned in *any* other corpus file, design or not, is not.
  private static func requirementUncitedFindings(
    scans: [DocScan]
  ) throws(ReportContractViolation) -> [Finding] {
    var findings: [Finding] = []
    for scan in scans {
      for id in scan.definedIDs.sorted() where id.hasPrefix("req-") {
        let citedElsewhere = scans.contains { other in
          other.path != scan.path && other.mentionedIDs.contains(id)
        }
        guard !citedElsewhere else { continue }
        findings.append(
          try Finding(
            ruleID: "docs-lint.requirement-uncited", severity: .major, file: scan.path,
            line: scan.definedIDLine[id],
            message:
              "\"\(id)\" is defined here but never cited outside its defining doc "
              + "(spec §6.2 reference integrity).",
            failureScenario: nil))
      }
    }
    return findings
  }

  // MARK: - Relative links

  private static func relativeLinkFindings(
    resolutions: [LinkOccurrence]
  ) throws(ReportContractViolation) -> [Finding] {
    var findings: [Finding] = []
    for occurrence in resolutions {
      switch occurrence.resolution {
      case .resolved:
        continue
      case .climbsAboveRoot:
        findings.append(
          try Finding(
            ruleID: "docs-lint.broken-relative-link", severity: .major, file: occurrence.from,
            line: occurrence.line,
            message:
              "link \"\(occurrence.destination)\" climbs above the repo root; a relative link "
              + "never resolves outside the repo (spec §6.2 relative links).",
            failureScenario: nil))
      case .broken(let resolved):
        findings.append(
          try Finding(
            ruleID: "docs-lint.broken-relative-link", severity: .major, file: occurrence.from,
            line: occurrence.line,
            message:
              "link \"\(occurrence.destination)\" resolves to \"\(resolved)\", which isn't a "
              + "tracked file or directory (spec §6.2 relative links).",
            failureScenario: nil))
      }
    }
    return findings
  }

  // MARK: - Router reachability

  /// A plain BFS from ``routerRoot`` over the resolved-link graph. A visited set makes a cycle
  /// between two docs terminate instead of looping, and it marks both cycle members reachable
  /// the moment either is first reached from the root — neither is penalised for the cycle. A doc
  /// with no incoming path from the root — including a pair that only link to each other — is
  /// never added to `visited` and is flagged.
  private static func reachabilityFindings(
    resolutions: [LinkOccurrence], pathSet: Set<String>
  ) throws(ReportContractViolation) -> [Finding] {
    guard pathSet.contains(routerRoot) else { return [] }

    // Reachability uses the docs corpus (`pathSet`), not `repoPaths`: a `.md` link can be a
    // perfectly real tracked file and still fall outside the narrower set `docs-lint-command`
    // scanned, in which case it contributes no edge but also no broken-link finding.
    var adjacency: [String: Set<String>] = [:]
    for occurrence in resolutions {
      guard let resolved = resolvedPath(occurrence.resolution), resolved.hasSuffix(".md"),
        pathSet.contains(resolved)
      else { continue }
      adjacency[occurrence.from, default: []].insert(resolved)
    }

    var visited: Set<String> = [routerRoot]
    var queue = [routerRoot]
    while let next = queue.popLast() {
      for neighbor in adjacency[next, default: []] where !visited.contains(neighbor) {
        visited.insert(neighbor)
        queue.append(neighbor)
      }
    }

    var findings: [Finding] = []
    for path in pathSet.sorted() where path.hasPrefix("docs/") && !visited.contains(path) {
      findings.append(
        try Finding(
          ruleID: "docs-lint.unreachable-doc", severity: .major, file: path, line: nil,
          message:
            "\"\(path)\" is never reached by a relative link chain from \(routerRoot) "
            + "(spec §6.2 router reachability).",
          failureScenario: nil))
    }
    return findings
  }

  // MARK: - Link resolution shared by both link families

  private enum LinkResolution: Equatable {
    case resolved(String)
    /// Normalized to a repo-relative path, but that path — or, for a directory link, no path
    /// under it — is untracked.
    case broken(String)
    case climbsAboveRoot
  }

  private struct LinkOccurrence {
    let from: String
    let destination: String
    let resolution: LinkResolution
    let line: Int
  }

  private static func resolvedLinks(scans: [DocScan], repoPaths: Set<String>) -> [LinkOccurrence] {
    var occurrences: [LinkOccurrence] = []
    for scan in scans {
      for lineLinks in scan.linksPerLine {
        for link in lineLinks where isRelativeDocLink(link.destination) {
          let classified = classify(
            resolve(from: scan.path, destination: link.destination), repoPaths: repoPaths)
          occurrences.append(
            LinkOccurrence(
              from: scan.path, destination: link.destination, resolution: classified,
              line: link.line)
          )
        }
      }
    }
    return occurrences
  }

  /// The resolved repo-relative path behind a link, whether it turned out to be tracked or not —
  /// reachability reads this directly rather than through `repoPaths` membership (see the type
  /// doc's third decision).
  private static func resolvedPath(_ resolution: LinkResolution) -> String? {
    switch resolution {
    case .resolved(let path), .broken(let path): return path
    case .climbsAboveRoot: return nil
    }
  }

  private static func classify(_ raw: RawResolution, repoPaths: Set<String>) -> LinkResolution {
    switch raw {
    case .climbsAboveRoot: return .climbsAboveRoot
    case .resolved(let path, let isDirectory):
      let tracked = isDirectory ? directoryIsTracked(path, in: repoPaths) : repoPaths.contains(path)
      return tracked ? .resolved(path) : .broken(path)
    }
  }

  /// A directory link resolves when some tracked file lives under it — git never tracks a bare
  /// directory. The repo root (`path == ""`, from a link like `../`) is trivially tracked as long
  /// as the repo has any tracked file at all.
  private static func directoryIsTracked(_ path: String, in repoPaths: Set<String>) -> Bool {
    if path.isEmpty { return !repoPaths.isEmpty }
    let prefix = path + "/"
    return repoPaths.contains { $0.hasPrefix(prefix) }
  }

  private enum RawResolution: Equatable {
    case resolved(path: String, isDirectory: Bool)
    case climbsAboveRoot
  }

  /// `#anchor`-only links and links naming a URL scheme (`https:`, `http:`, `mailto:`) are never
  /// resolution candidates — mirrors ``MarkdownDocument/Link/isRelative``.
  private static func isRelativeDocLink(_ destination: String) -> Bool {
    if destination.hasPrefix("#") { return false }
    let schemes = ["http://", "https://", "mailto:"]
    return !schemes.contains { destination.hasPrefix($0) }
  }

  /// Resolves `destination` against `docPath`'s directory: strips a trailing `#fragment` (never
  /// verified — see the type doc), decodes percent-escapes (`%20` → space), then walks `..`
  /// segments against the directory stack. A `..` past the stack's start is `.climbsAboveRoot` —
  /// this never falls back to resolving against the real filesystem. `isDirectory` is true when
  /// the destination ends `/`, or its last segment has no `.` (so `../adrs/` and `../gate/Sour`
  /// are both directory-shaped; `directoryIsTracked` still separates a real directory from a
  /// string that merely prefixes a file name).
  private static func resolve(from docPath: String, destination: String) -> RawResolution {
    let withoutFragment = destination.split(
      separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
    // A destination percent-encoding can't decode is used as written rather than dropped, so it
    // still resolves (almost certainly to something untracked) instead of silently passing.
    let decoded = String(withoutFragment).removingPercentEncoding ?? String(withoutFragment)
    let endsWithSlash = decoded.hasSuffix("/")

    var stack: [String]
    let remainder: Substring
    if decoded.hasPrefix("/") {
      stack = []
      remainder = decoded.dropFirst()
    } else {
      stack = docPath.split(separator: "/").dropLast().map(String.init)
      remainder = Substring(decoded)
    }

    for component in remainder.split(separator: "/", omittingEmptySubsequences: true) {
      if component == "." { continue }
      if component == ".." {
        guard !stack.isEmpty else { return .climbsAboveRoot }
        stack.removeLast()
      } else {
        stack.append(String(component))
      }
    }

    let isDirectory = endsWithSlash || !(stack.last?.contains(".") ?? false)
    return .resolved(path: stack.joined(separator: "/"), isDirectory: isDirectory)
  }

  // MARK: - Per-file scan

  /// One link `[text](destination)` found on a single scan line, with `textRange` (the bracketed
  /// text's range within that same line) kept so the bare-ADR check can test whether a mention
  /// falls inside a link's visible text, and `line` (1-based, in the original file) for the
  /// relative-link findings.
  private struct LineLink {
    let text: String
    let textRange: Range<String.Index>
    let destination: String
    let line: Int
  }

  /// A file's fence- and inline-code-stripped scan surface, computed once and shared by every
  /// family: `docs-lint.dangling-id`, `.bare-adr-reference` and `.requirement-uncited` need
  /// `scanLines`/`mentionedIDs`/`definedIDs`; the link families need `linksPerLine`.
  private struct DocScan {
    let path: String
    /// Non-fenced lines with inline-code spans blanked to spaces (length-preserving, so
    /// `String.Index` positions found in a masked line stay valid for that same line). A link or
    /// id/ADR mention living only inside a fence or inline code never reaches any family.
    /// Fenced lines are blanked, not dropped, so index `i` always names line `i + 1` of the real
    /// file — every family that reports a line number depends on that alignment.
    let scanLines: [String]
    let linksPerLine: [[LineLink]]
    /// Every `req-`/`test-` id this file defines via a `- <id>: ` bullet.
    let definedIDs: Set<String>
    /// Every `req-`/`test-`/`ev-`-shaped token mentioned anywhere in this file (definitions
    /// included).
    let mentionedIDs: Set<String>
    /// 1-based line of each mentioned id's first occurrence.
    let firstMentionLine: [String: Int]
    /// 1-based line of each defined id's `- <id>: ` bullet.
    let definedIDLine: [String: Int]

    init(file: DocFile) {
      self.path = file.path
      let lines = DocScan.nonFencedLines(file.rawText).map(DocScan.maskInlineCode)
      self.scanLines = lines
      self.linksPerLine = lines.enumerated().map { index, line in
        DocScan.links(in: line, line: index + 1)
      }

      let definitionPattern = #/^-\s+(?<id>(?:req|test)-[a-z0-9]+(?:-[a-z0-9]+)*):\s/#
      let mentionPattern = #/\b(?:req|test|ev)-[a-z0-9]+(?:-[a-z0-9]+)*\b/#
      var defined: Set<String> = []
      var mentioned: Set<String> = []
      var firstMention: [String: Int] = [:]
      var definedLine: [String: Int] = [:]
      for (index, line) in lines.enumerated() {
        if let match = try? definitionPattern.firstMatch(in: line) {
          let id = String(match.id)
          defined.insert(id)
          if definedLine[id] == nil { definedLine[id] = index + 1 }
        }
        for match in line.matches(of: mentionPattern) {
          let id = String(line[match.range])
          mentioned.insert(id)
          if firstMention[id] == nil { firstMention[id] = index + 1 }
        }
      }
      self.definedIDs = defined
      self.mentionedIDs = mentioned
      self.firstMentionLine = firstMention
      self.definedIDLine = definedLine
    }

    /// Blanks fenced code blocks (opening/closing fence lines and everything between) to empty
    /// strings — mirrors ``MarkdownDocument``'s own fence-marker tracking, kept standalone here
    /// since a fence never has to survive past this scan. Blanking rather than dropping keeps
    /// every later index aligned with the real file's line numbers.
    private static func nonFencedLines(_ text: String) -> [String] {
      var result: [String] = []
      var fenceMarker: String?
      for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
        var line = String(rawLine)
        if line.hasSuffix("\r") { line.removeLast() }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if let marker = fenceMarker {
          if trimmed.hasPrefix(marker) { fenceMarker = nil }
          result.append("")
          continue
        }
        if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
          fenceMarker = String(trimmed.prefix(3))
          result.append("")
          continue
        }
        result.append(line)
      }
      return result
    }

    /// Blanks every backtick-delimited inline-code span to spaces, one line at a time (Markdown
    /// inline code never spans a line in this reader's model, matching its fence-only multi-line
    /// construct). An unterminated backtick treats the rest of the line as code — the safer
    /// default, since a stray backtick is far likelier to be a typo than an intentional marker.
    private static func maskInlineCode(_ line: String) -> String {
      guard line.contains("`") else { return line }
      var result = ""
      var inCode = false
      for character in line {
        if character == "`" {
          inCode.toggle()
          result.append(" ")
        } else {
          result.append(inCode ? " " : character)
        }
      }
      return result
    }

    private static func links(in line: String, line lineNumber: Int) -> [LineLink] {
      var results: [LineLink] = []
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
        let textRange = line.index(after: open)..<closeText
        let destination = String(line[line.index(after: afterText)..<closeDest])
        results.append(
          LineLink(
            text: String(line[textRange]), textRange: textRange, destination: destination,
            line: lineNumber))
        searchStart = line.index(after: closeDest)
      }
      return results
    }
  }
}
