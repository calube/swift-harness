import Foundation

/// Reads Package.swift files: an area per package, `swift test` with `--filter`.
///
/// Area commands run in the area's root, so they name no package path. A package an Xcode area
/// already builds (beside its project or workspace, or referenced as a local package) is left to
/// that area, so 1 package never becomes 2 areas.
public struct SwiftPMReader: EcosystemReader {
  public init() {}

  public func areas(in tree: TrackedTreeSnapshot) -> [ProposedArea] {
    let absorbed = XcodeReader.packageDirectories(claimedIn: tree)
    return tree.paths.compactMap { path -> ProposedArea? in
      let parts = path.split(separator: "/").map(String.init)
      // `Package@swift-6.0.swift` variants describe the same package; `Tuist/Package.swift`
      // declares a Tuist project's dependencies, not a package of its own.
      guard parts.last == "Package.swift", parts.dropLast().last != "Tuist" else { return nil }
      guard !absorbed.contains(SwiftDiscoverPaths.dirname(path)) else { return nil }
      return Self.area(manifest: path, in: tree)
    }
  }

  /// The area the package whose manifest is `path` makes. `runElsewhere` names its test targets an
  /// Xcode scheme already runs, which this area's `test` leaves out.
  public static func area(
    manifest path: String, in tree: TrackedTreeSnapshot, runElsewhere: Set<String> = []
  ) -> ProposedArea? {
    let root = SwiftDiscoverPaths.dirname(path)
    guard let data = tree.read(path) else { return nil }
    let manifest = String(decoding: data, as: UTF8.self)
    let name =
      root == "."
      ? (SwiftDiscoverText.quoted(after: "name:", following: "Package(", in: manifest) ?? "root")
      : SwiftDiscoverPaths.basename(root)
    var commands: [AreaStep: Sourced<String>] = [
      .build: Sourced(value: "swift build", source: path, confidence: .found)
    ]
    var missing: [AreaStep: String] = [:]
    if manifest.contains(".testTarget(") {
      commands[.test] = Sourced(value: "swift test", source: path, confidence: .found)
      commands[.testFiles] = Sourced(
        value: "swift test --filter {tests}", source: path, confidence: .found)
    } else {
      missing[.test] = "no test target in \(path)"
    }
    if let lint = SwiftDiscoverLint.command(root: root, tree: tree) {
      commands[.lint] = lint
    } else {
      missing[.lint] = SwiftDiscoverLint.missingReason
    }
    return ProposedArea(
      name: SwiftDiscoverText.areaName(name), root: root, language: .swift, kind: .swiftpm,
      source: path, commands: commands, missing: missing,
      testGlobs: [SwiftDiscoverPaths.join(root, "Tests/**/*.swift")], xcode: nil,
      generatedProjectTracked: nil)
  }
}

/// The Swift linter a repository configures, found from an area's root up to the repository root.
enum SwiftDiscoverLint {
  static let missingReason = "no .swiftlint.yml, .swift-format or .swiftformat config"

  static func command(root: String, tree: TrackedTreeSnapshot) -> Sourced<String>? {
    let tracked = Set(tree.paths)
    var directory: String? = root
    while let current = directory {
      for (file, template) in [
        (".swiftlint.yml", "swiftlint lint --config %@ {files}"),
        (".swiftlint.yaml", "swiftlint lint --config %@ {files}"),
        (".swift-format", "swift format lint --strict --configuration %@ {files}"),
        (".swiftformat", "swiftformat --lint --config %@ {files}"),
      ] {
        let path = SwiftDiscoverPaths.join(current, file)
        guard tracked.contains(path) else { continue }
        let config = SwiftDiscoverText.shellWord(SwiftDiscoverPaths.relative(path, from: root))
        return Sourced(
          value: template.replacingOccurrences(of: "%@", with: config), source: path,
          confidence: .found)
      }
      directory = current == "." ? nil : SwiftDiscoverPaths.dirname(current)
    }
    return nil
  }
}

/// Repository-relative path arithmetic, where `.` is the repository root.
enum SwiftDiscoverPaths {
  static func components(_ path: String) -> [String] {
    path.split(separator: "/").map(String.init).filter { $0 != "." && !$0.isEmpty }
  }

  static func dirname(_ path: String) -> String {
    let parts = components(path).dropLast()
    return parts.isEmpty ? "." : parts.joined(separator: "/")
  }

  static func basename(_ path: String) -> String { components(path).last ?? "." }

  /// `relative` resolved against `directory`, folding `..`; `nil` when it climbs above the root.
  static func resolve(_ relative: String, in directory: String) -> String? {
    var parts = components(directory)
    for part in components(relative) {
      if part == ".." {
        guard !parts.isEmpty else { return nil }
        parts.removeLast()
      } else {
        parts.append(part)
      }
    }
    return parts.isEmpty ? "." : parts.joined(separator: "/")
  }

  static func join(_ directory: String, _ relative: String) -> String {
    resolve(relative, in: directory) ?? relative
  }

  static func relative(_ path: String, from directory: String) -> String {
    let target = components(path)
    let base = components(directory)
    let shared = zip(target, base).prefix { $0 == $1 }.count
    let parts = Array(repeating: "..", count: base.count - shared) + target.dropFirst(shared)
    return parts.isEmpty ? "." : parts.joined(separator: "/")
  }

  static func isUnder(_ path: String, _ directory: String) -> Bool {
    directory == "." || path == directory || path.hasPrefix(directory + "/")
  }
}

enum SwiftDiscoverText {
  /// The first string literal after `key` that follows `anchor`.
  static func quoted(after key: String, following anchor: String? = nil, in text: String)
    -> String?
  {
    let start = anchor.map { text.range(of: $0)?.upperBound } ?? text.startIndex
    guard let start, let keyEnd = text.range(of: key, range: start..<text.endIndex)?.upperBound
    else { return nil }
    let rest = text[keyEnd...].drop { $0 == " " || $0 == "\t" || $0 == "\n" }
    guard rest.first == "\"" else { return nil }
    let body = rest.dropFirst()
    guard let close = body.firstIndex(of: "\"") else { return nil }
    return String(body[..<close])
  }

  /// `config.toml` names an area on the command line as `<area>.<step>`, so whitespace becomes `-`.
  static func areaName(_ raw: String) -> String {
    raw.split(whereSeparator: \.isWhitespace).joined(separator: "-")
  }

  /// `text` as 1 `/bin/sh` word, quoted only when it holds a character the shell would split on.
  static func shellWord(_ text: String) -> String {
    let plain = text.allSatisfy { $0.isLetter || $0.isNumber || "._-/=:,+@".contains($0) }
    return plain && !text.isEmpty ? text : AreaCommandExpansion.shellQuoted(text)
  }
}
