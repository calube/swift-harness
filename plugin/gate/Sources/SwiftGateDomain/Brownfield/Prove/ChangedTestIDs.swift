import Foundation

/// 1 unit brownfield prove attributes an outcome to: a test file, a test function or a test class,
/// whichever the area's runner selects by.
public struct AreaTestID: Sendable, Hashable {
  /// What findings name.
  public let name: String
  /// The atom ``ChangedTestIDs/testsArgument(kind:ids:)`` joins into `{tests}`.
  public let selector: String
  /// Repository-relative.
  public let file: String
  public let line: Int

  public init(name: String, selector: String, file: String, line: Int) {
    self.name = name
    self.selector = selector
    self.file = file
    self.line = line
  }
}

/// A changed test file as the change leaves it.
public struct ChangedTestFile: Sendable, Equatable {
  /// Repository-relative.
  public let path: String
  public let content: String
  public let added: AddedLines

  public init(path: String, content: String, added: AddedLines) {
    self.path = path
    self.content = content
    self.added = added
  }
}

/// Maps changed test files to what an area's `{tests}` and `{files}` placeholders take.
public enum ChangedTestIDs {
  /// Whether `path` (repository-relative) is 1 of `area`'s tests: under its root and matching 1 of
  /// its `test_globs`, where `**` spans any number of directories.
  public static func isTestFile(_ path: String, of area: BrownfieldArea) -> Bool {
    guard area.root == "." || path.hasPrefix(area.root + "/") else { return false }
    let segments = path.split(separator: "/").map(String.init)[...]
    return area.testGlobs.contains { glob in
      matches(glob.split(separator: "/").map(String.init)[...], segments)
    }
  }

  /// The ids `{tests}` takes for `kind`, or `nil` when the kind selects no tests by id here:
  /// `swiftpm` goes through ``swift(_:)``, and `xcode` and `command` run their whole `test`.
  ///
  /// `node` and `python` select by file, relative to `areaRoot`; `go` and `cargo` by the test
  /// functions whose declaration spans an added line; `jvm` by the class each file declares.
  public static func ids(kind: AreaKind, areaRoot: String, files: [ChangedTestFile])
    -> [AreaTestID]?
  {
    switch kind {
    case .node, .python: Self.files(areaRoot: areaRoot, files: files)
    case .go: files.flatMap(goTests)
    case .cargo: files.flatMap(cargoTests)
    case .jvm: files.compactMap(jvmClass)
    case .swiftpm, .xcode, .command: nil
    }
  }

  /// SwiftPM ids, from the owned profile's Swift test discovery.
  public static func swift(_ tests: [ChangedTest]) -> [AreaTestID] {
    tests.map { AreaTestID(name: $0.id, selector: $0.filter, file: $0.file, line: $0.line) }
  }

  /// 1 id per changed file, relative to `areaRoot`: what a `test_files` command that takes only
  /// `{files}` selects by, whatever its kind.
  public static func files(areaRoot: String, files: [ChangedTestFile]) -> [AreaTestID] {
    files.map { file in
      let relative = relativePath(file.path, to: areaRoot)
      return AreaTestID(
        name: relative, selector: relative, file: file.path,
        line: file.added.ranges.first?.lowerBound ?? 1)
    }
  }

  /// The shell text that replaces `{tests}` for `ids`.
  public static func testsArgument(kind: AreaKind, ids: [AreaTestID]) -> String {
    let selectors = ids.map(\.selector)
    switch kind {
    case .go:
      return shellQuoted("^(" + selectors.joined(separator: "|") + ")$")
    case .jvm:
      return shellQuoted(selectors.joined(separator: ","))
    case .swiftpm:
      return shellQuoted(
        selectors.count == 1 ? selectors[0] : "(" + selectors.joined(separator: "|") + ")")
    case .node, .python, .cargo, .xcode, .command:
      return selectors.map(shellQuoted).joined(separator: " ")
    }
  }

  /// The shell text that replaces `{files}`: each of `ids`' files once, relative to `areaRoot`.
  public static func filesArgument(areaRoot: String, ids: [AreaTestID]) -> String {
    var seen: Set<String> = []
    return ids.map { relativePath($0.file, to: areaRoot) }.filter { seen.insert($0).inserted }
      .map(shellQuoted).joined(separator: " ")
  }

  /// `text` as 1 POSIX shell word.
  public static func shellQuoted(_ text: String) -> String {
    "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
  }

  /// `template` with each placeholder replaced. A `nil` value leaves its placeholder in place.
  public static func expand(_ template: String, tests: String?, files: String?, junit: String?)
    -> String
  {
    var expanded = template
    for (placeholder, value) in [("{tests}", tests), ("{files}", files), ("{junit}", junit)] {
      if let value { expanded = expanded.replacingOccurrences(of: placeholder, with: value) }
    }
    return expanded
  }

  // MARK: - Per-kind readers

  /// `func TestX(t *testing.T)` declarations; gofmt closes each at a `}` in column 1.
  private static func goTests(_ file: ChangedTestFile) -> [AreaTestID] {
    let lines = numberedLines(file.content)
    var ids: [AreaTestID] = []
    for (index, line) in lines.enumerated() {
      guard line.hasPrefix("func Test"), line.contains("*testing.T)"),
        let name = identifier(after: "func ", in: line), name != "TestMain"
      else { continue }
      let end = lines[index...].firstIndex { $0 == "}" } ?? lines.count - 1
      if spans(file.added, index + 1...end + 1) {
        ids.append(AreaTestID(name: name, selector: name, file: file.path, line: index + 1))
      }
    }
    return ids
  }

  /// A `#[…test…]` attribute, then the `fn` it marks, through the brace that closes the body.
  private static func cargoTests(_ file: ChangedTestFile) -> [AreaTestID] {
    let lines = numberedLines(file.content)
    var ids: [AreaTestID] = []
    var index = 0
    while index < lines.count {
      let attribute = lines[index].trimmingCharacters(in: .whitespaces)
      guard attribute.hasPrefix("#["), attribute.contains("test") else {
        index += 1
        continue
      }
      guard
        let declaration = lines[index...].firstIndex(where: {
          !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#[")
        }),
        let name = rustFunctionName(lines[declaration])
      else {
        index += 1
        continue
      }
      var depth = 0
      var opened = false
      var end = declaration
      for (offset, line) in lines[declaration...].enumerated() {
        for character in line {
          if character == "{" {
            depth += 1
            opened = true
          } else if character == "}" {
            depth -= 1
          }
        }
        end = declaration + offset
        if opened && depth <= 0 { break }
      }
      if spans(file.added, index + 1...end + 1) {
        ids.append(AreaTestID(name: name, selector: name, file: file.path, line: index + 1))
      }
      index = end + 1
    }
    return ids
  }

  /// The file's class, qualified by its `package` line, or else by its directory under a
  /// `java`, `kotlin`, `scala` or `groovy` source set.
  private static func jvmClass(_ file: ChangedTestFile) -> AreaTestID? {
    guard !file.added.ranges.isEmpty else { return nil }
    let components = file.path.split(separator: "/").map(String.init)
    guard let fileName = components.last, let dot = fileName.lastIndex(of: ".") else {
      return nil
    }
    let className = String(fileName[..<dot])
    var package: [String] = []
    if let line = numberedLines(file.content).first(where: { $0.hasPrefix("package ") }) {
      let name = line.dropFirst("package ".count).trimmingCharacters(
        in: CharacterSet(charactersIn: "; \t"))
      package = name.split(separator: ".").map(String.init)
    } else if let sourceSet = components.dropLast().lastIndex(where: {
      ["java", "kotlin", "scala", "groovy"].contains($0)
    }) {
      package = Array(components[(sourceSet + 1)..<(components.count - 1)])
    }
    let qualified = (package + [className]).joined(separator: ".")
    return AreaTestID(
      name: qualified, selector: qualified, file: file.path,
      line: file.added.ranges[0].lowerBound)
  }

  // MARK: - Helpers

  private static func numberedLines(_ content: String) -> [String] {
    content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
  }

  private static func spans(_ added: AddedLines, _ lines: ClosedRange<Int>) -> Bool {
    added.ranges.contains { $0.overlaps(lines) }
  }

  private static func identifier(after prefix: String, in line: String) -> String? {
    guard let start = line.range(of: prefix)?.upperBound else { return nil }
    let name = line[start...].prefix { $0.isLetter || $0.isNumber || $0 == "_" }
    return name.isEmpty ? nil : String(name)
  }

  /// `fn name(`, after any of `pub`, `async`, `unsafe` or `const`.
  private static func rustFunctionName(_ line: String) -> String? {
    let words = line.trimmingCharacters(in: .whitespaces).split(separator: " ")
    guard let fn = words.firstIndex(of: "fn"), fn + 1 < words.count,
      words[..<fn].allSatisfy({ $0.hasPrefix("pub") || ["async", "unsafe", "const"].contains($0) })
    else { return nil }
    let name = words[fn + 1].prefix { $0.isLetter || $0.isNumber || $0 == "_" }
    return name.isEmpty ? nil : String(name)
  }

  private static func relativePath(_ path: String, to root: String) -> String {
    root == "." ? path : String(path.dropFirst(root.count + 1))
  }

  private static func matches(_ pattern: ArraySlice<String>, _ path: ArraySlice<String>) -> Bool {
    guard let head = pattern.first else { return path.isEmpty }
    if head == "**" {
      let rest = pattern.dropFirst()
      return (path.startIndex...path.endIndex).contains { matches(rest, path[$0...]) }
    }
    guard let segment = path.first, fnmatch(head, segment, 0) == 0 else { return false }
    return matches(pattern.dropFirst(), path.dropFirst())
  }
}
