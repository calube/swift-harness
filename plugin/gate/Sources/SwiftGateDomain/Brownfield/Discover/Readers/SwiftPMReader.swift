import Foundation

/// Reads Package.swift files: an area per package, `swift test` with `--filter`, or `xcodebuild`
/// on a simulator for a package that declares iOS and not macOS, which `swift test` can't build
/// on the Mac.
///
/// Area commands run in the area's root, so they name no package path. A package an Xcode area
/// already builds (beside its project or workspace, or referenced as a local package) is left to
/// that area when the area's test scheme runs all its test targets; otherwise it is an area of
/// its own, whose `test` leaves out the targets the scheme runs.
public struct SwiftPMReader: EcosystemReader {
  public init() {}

  public func areas(in tree: TrackedTreeSnapshot) -> [ProposedArea] {
    let apart = XcodeReader.packagesTestedApart(in: tree)
    let absorbed = XcodeReader.packageDirectories(claimedIn: tree).subtracting(apart.keys)
    return tree.paths.compactMap { path -> ProposedArea? in
      let parts = path.split(separator: "/").map(String.init)
      // `Package@swift-6.0.swift` variants describe the same package; `Tuist/Package.swift`
      // declares a Tuist project's dependencies, not a package of its own.
      guard parts.last == "Package.swift", parts.dropLast().last != "Tuist" else { return nil }
      let root = SwiftDiscoverPaths.dirname(path)
      guard !absorbed.contains(root) else { return nil }
      return Self.area(manifest: path, in: tree, runElsewhere: apart[root] ?? [])
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
    let skipped = runElsewhere.sorted()
    var commands: [AreaStep: Sourced<String>] = [:]
    var missing: [AreaStep: String] = [:]
    let tests = manifest.contains(".testTarget(")
    if SwiftPMManifest.isIOSOnly(manifest) {
      // The scheme Xcode makes for a package: its 1 product's, else `<package>-Package`.
      let products = SwiftPMManifest.products(in: manifest)
      let packageName =
        SwiftDiscoverText.quoted(after: "name:", following: "Package(", in: manifest) ?? name
      let scheme = SwiftDiscoverText.shellWord(
        products.count == 1 ? products[0] : "\(packageName)-Package")
      commands[.build] = Sourced(
        value: "xcodebuild build -scheme \(scheme) -destination "
          + XcodeReader.destination(scheme: "iOS", generic: true) + XcodeReader.headlessFlags,
        source: path, confidence: .guessed)
      if tests {
        commands[.test] = Sourced(
          value: "xcodebuild test -scheme \(scheme) -destination "
            + XcodeReader.destination(scheme: "iOS", generic: false) + XcodeReader.headlessFlags
            + skipped.map { " -skip-testing:\(SwiftDiscoverText.shellWord($0))" }.joined(),
          source: path, confidence: .guessed)
      }
    } else {
      commands[.build] = Sourced(value: "swift build", source: path, confidence: .found)
      if tests {
        commands[.test] = Sourced(
          value: "swift test"
            + skipped.map { " --skip \(SwiftDiscoverText.shellWord("^\($0)\\."))" }.joined(),
          source: path, confidence: .found)
        commands[.testFiles] = Sourced(
          value: "swift test --filter {tests}", source: path, confidence: .found)
      }
    }
    if !tests { missing[.test] = "no test target in \(path)" }
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

/// What discover reads from a `Package.swift`'s text, without evaluating it.
enum SwiftPMManifest {
  /// The `name:` of every `.testTarget(`.
  static func testTargets(in manifest: String) -> [String] {
    names(after: ".testTarget(", in: manifest)
  }

  /// The `name:` of every `.library(` and `.executable(` product.
  static func products(in manifest: String) -> [String] {
    names(after: ".library(", in: manifest) + names(after: ".executable(", in: manifest)
  }

  /// Whether `platforms:` names iOS and not macOS: such a package often imports UIKit, which
  /// `swift build` on the Mac can't find.
  static func isIOSOnly(_ manifest: String) -> Bool {
    guard let key = manifest.range(of: "platforms:"),
      let open = manifest[key.upperBound...].firstIndex(of: "[")
    else { return false }
    var depth = 0
    var end = manifest.endIndex
    for index in manifest[open...].indices {
      switch manifest[index] {
      case "[": depth += 1
      case "]":
        depth -= 1
        if depth == 0 { end = index }
      default: break
      }
      if end != manifest.endIndex { break }
    }
    let platforms = manifest[open..<end]
    return platforms.contains(".iOS(") && !platforms.contains(".macOS(")
  }

  private static func names(after anchor: String, in manifest: String) -> [String] {
    var names: [String] = []
    var rest = manifest[...]
    while let range = rest.range(of: anchor) {
      rest = rest[range.upperBound...]
      let body = rest.drop { $0.isWhitespace }
      guard body.hasPrefix("name:"),
        let name = SwiftDiscoverText.quoted(after: "name:", in: String(body))
      else { continue }
      names.append(name)
    }
    return names
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
