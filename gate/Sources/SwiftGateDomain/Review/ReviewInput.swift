/// Which changed files put the SwiftUI reviewer on the panel (spec §9.2: only when the diff touches
/// a module importing SwiftUI).
public enum SwiftUIReach {
  /// The source directory of the SwiftPM target a file belongs to (`Pkg/Sources/Target/`), or `nil`
  /// for a file outside any `Sources/<Target>/` tree (app target, scripts).
  public static func moduleDirectory(of path: String) -> String? {
    let components = path.split(separator: "/", omittingEmptySubsequences: false)
    guard let sources = components.lastIndex(of: "Sources"), sources + 2 < components.count
    else { return nil }
    return components[...(sources + 1)].joined(separator: "/") + "/"
  }

  /// The touched units that import SwiftUI: a module directory when the file sits in one, else the
  /// file itself. `importsSwiftUI` answers for either kind of unit.
  public static func touchedUnits(
    changedSwiftFiles: [String], importsSwiftUI: (String) -> Bool
  ) -> [String] {
    let units = Set(changedSwiftFiles.map { moduleDirectory(of: $0) ?? $0 })
    return units.filter(importsSwiftUI).sorted()
  }

  /// Whether Swift source text imports SwiftUI (any access-level or attribute prefix).
  public static func importsSwiftUI(_ text: String) -> Bool {
    text.split(whereSeparator: \.isNewline).contains { line in
      let words = line.split(whereSeparator: \.isWhitespace)
      guard let index = words.firstIndex(of: "import"), index + 1 < words.count else {
        return false
      }
      return words[..<index].allSatisfy { $0.hasPrefix("@") || accessModifiers.contains($0) }
        && words[index + 1] == "SwiftUI"
    }
  }

  private static let accessModifiers: Set<Substring> = [
    "public", "package", "internal", "fileprivate", "private",
  ]
}

/// `review-input/manifest.json`: what the review workflow reads first (spec §9.2 step 1).
public struct ReviewInputManifest: Sendable, Equatable, Codable {
  public static let schemaVersion = 1

  public struct Artifacts: Sendable, Equatable, Codable {
    public let check: String
    public let arch: String
    public let testlint: String
    public let comments: String
    public let diff: String
    /// `nil` while the build has no `mutate` command.
    public let mutate: String?

    public init(
      check: String, arch: String, testlint: String, comments: String, diff: String,
      mutate: String?
    ) {
      self.check = check
      self.arch = arch
      self.testlint = testlint
      self.comments = comments
      self.diff = diff
      self.mutate = mutate
    }
  }

  public let schemaVersion: Int
  public let runID: String
  public let base: String
  public let mergeBase: String
  public let gateVerdict: Verdict
  public let changedFiles: [String]
  public let swiftUIUnits: [String]
  /// The reviewers to run; `swiftui` only when ``swiftUIUnits`` is non-empty.
  public let focuses: [ReviewFocus]
  public let artifacts: Artifacts
  public let notes: [String]

  public init(
    runID: String, base: String, mergeBase: String, gateVerdict: Verdict, changedFiles: [String],
    swiftUIUnits: [String], artifacts: Artifacts, notes: [String]
  ) {
    self.schemaVersion = Self.schemaVersion
    self.runID = runID
    self.base = base
    self.mergeBase = mergeBase
    self.gateVerdict = gateVerdict
    self.changedFiles = changedFiles
    self.swiftUIUnits = swiftUIUnits
    self.focuses = ReviewFocus.allCases.filter { $0 != .swiftui || !swiftUIUnits.isEmpty }
    self.artifacts = artifacts
    self.notes = notes
  }
}
