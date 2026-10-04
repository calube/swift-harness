import Foundation

/// Reads other build files (`mix.exs`, `CMakeLists.txt`, …): an area whose commands come only from CI.
///
/// Every step starts missing, so ``CICommandMining`` fills whichever ones CI, `Makefile`,
/// `justfile` or `bin/*` already run. A build file whose directory sits under another of its own
/// kind joins that area, since CMake, Meson and Zig pull subdirectories in from the top; every
/// `mix.exs` is its own project.
public struct CommandReader: EcosystemReader {
  public init() {}

  static let topmostOnly: Set<String> = ["CMakeLists.txt", "meson.build", "build.zig"]
  static let eachOne: Set<String> = ["mix.exs", "MODULE.bazel", "WORKSPACE.bazel", "WORKSPACE"]
  static let reason = "no command in CI, Makefile, justfile or bin/*"

  public func areas(in tree: TrackedTreeSnapshot) -> [ProposedArea] {
    let files = tree.paths.filter { path in
      let name = CICommandMining.basename(path)
      return (Self.topmostOnly.contains(name) || Self.eachOne.contains(name))
        && !BuildFilePaths.isSkipped(path)
    }
    let byName = Dictionary(grouping: files, by: CICommandMining.basename)
    var seenRoots: Set<String> = []
    return files.compactMap { path in
      let name = CICommandMining.basename(path)
      let root = CICommandMining.dirname(path)
      if Self.topmostOnly.contains(name) {
        let directories = Set((byName[name] ?? []).map(CICommandMining.dirname))
        let enclosing = BuildFilePaths.ancestors(of: root).dropFirst()
        if enclosing.contains(where: directories.contains) { return nil }
      }
      // Bazel's `WORKSPACE` and `MODULE.bazel` often sit together; 1 root is 1 area.
      guard seenRoots.insert("\(root)\0\(Self.eachOne.contains(name))").inserted else {
        return nil
      }
      let text = BuildFilePaths.text(tree, path)
      return ProposedArea(
        name: Self.projectName(name, text) ?? BuildFilePaths.defaultName(root), root: root,
        language: .other, kind: .command, source: path, commands: [:],
        missing: [.test: Self.reason, .lint: Self.reason, .build: Self.reason], testGlobs: [],
        xcode: nil, generatedProjectTracked: nil)
    }
  }

  /// `app: :name` in a `mix.exs`, or `project(name` in a `CMakeLists.txt`.
  static func projectName(_ file: String, _ text: String?) -> String? {
    guard let text else { return nil }
    switch file {
    case "mix.exs":
      guard let range = text.range(of: "app: :") else { return nil }
      let name = text[range.upperBound...].prefix { $0.isLetter || $0.isNumber || $0 == "_" }
      return name.isEmpty ? nil : String(name)
    case "CMakeLists.txt":
      for line in text.split(separator: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("project(") else { continue }
        let name = trimmed.dropFirst("project(".count)
          .trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
          .prefix { !" )\"'".contains($0) }
        return name.isEmpty ? nil : String(name)
      }
      return nil
    default:
      return nil
    }
  }
}

/// Path rules the JVM, Go, Cargo and command readers share.
enum BuildFilePaths {
  /// Directories whose build files are copied, generated or test inputs rather than the
  /// repository's own modules, such as a scaffolding template full of `{{ name }}`.
  static let skippedDirectories: Set<String> = [
    "templates", "testdata", "fixtures", "__fixtures__", "vendor", "node_modules",
  ]

  static func isSkipped(_ path: String) -> Bool {
    path.split(separator: "/").dropLast().contains { skippedDirectories.contains(String($0)) }
  }

  /// `directory` and each directory above it, ending at `.`.
  static func ancestors(of directory: String) -> [String] {
    var result = [directory]
    var current = directory
    while current != "." {
      current = CICommandMining.dirname(current)
      result.append(current)
    }
    return result
  }

  /// `path` relative to `base`, both repository-relative; `.` when they are the same.
  static func relative(_ path: String, to base: String) -> String {
    if path == base { return "." }
    return base == "." ? path : String(path.dropFirst(base.count + 1))
  }

  /// The path that reaches `target` from `directory`, both repository-relative, where `target`
  /// sits in `directory` or a directory above it.
  static func relativeFrom(_ directory: String, to target: String) -> String {
    let below = relative(directory, to: CICommandMining.dirname(target))
    let up = below == "." ? 0 : below.split(separator: "/").count
    return String(repeating: "../", count: up) + CICommandMining.basename(target)
  }

  /// `name` in `directory`, as a repository-relative path.
  static func join(_ directory: String, _ name: String) -> String {
    directory == "." ? name : "\(directory)/\(name)"
  }

  static func text(_ tree: TrackedTreeSnapshot, _ path: String) -> String? {
    tree.read(path).map { String(decoding: $0, as: UTF8.self) }
  }

  /// An area named after its directory when its build file names nothing.
  static func defaultName(_ root: String) -> String {
    root == "." ? "root" : CICommandMining.basename(root)
  }

  /// The quoted strings in `text`, in order.
  static func quotedStrings(_ text: Substring) -> [String] {
    var strings: [String] = []
    var current: String?
    var quote: Character = "\""
    for character in text {
      if var open = current {
        if character == quote {
          strings.append(open)
          current = nil
        } else {
          open.append(character)
          current = open
        }
      } else if character == "\"" || character == "'" {
        quote = character
        current = ""
      }
    }
    return strings
  }
}
