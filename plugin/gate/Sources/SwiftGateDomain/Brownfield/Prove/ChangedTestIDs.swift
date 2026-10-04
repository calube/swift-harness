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
    false
  }

  /// The ids `{tests}` takes for `kind`, or `nil` when the kind selects no tests by id here:
  /// `swiftpm` goes through ``swift(_:)``, and `xcode` and `command` run their whole `test`.
  ///
  /// `node` and `python` select by file, relative to `areaRoot`; `go` and `cargo` by the test
  /// functions whose declaration spans an added line; `jvm` by the class each file declares.
  public static func ids(kind: AreaKind, areaRoot: String, files: [ChangedTestFile])
    -> [AreaTestID]?
  {
    nil
  }

  /// SwiftPM ids, from the owned profile's Swift test discovery.
  public static func swift(_ tests: [ChangedTest]) -> [AreaTestID] {
    []
  }

  /// 1 id per changed file, relative to `areaRoot`: what a `test_files` command that takes only
  /// `{files}` selects by, whatever its kind.
  public static func files(areaRoot: String, files: [ChangedTestFile]) -> [AreaTestID] {
    []
  }

  /// The shell text that replaces `{tests}` for `ids`.
  public static func testsArgument(kind: AreaKind, ids: [AreaTestID]) -> String {
    ""
  }

  /// The shell text that replaces `{files}`: each of `ids`' files once, relative to `areaRoot`.
  public static func filesArgument(areaRoot: String, ids: [AreaTestID]) -> String {
    ""
  }

  /// `text` as 1 POSIX shell word.
  public static func shellQuoted(_ text: String) -> String {
    text
  }

  /// `template` with each placeholder replaced. A `nil` value leaves its placeholder in place.
  public static func expand(_ template: String, tests: String?, files: String?, junit: String?)
    -> String
  {
    template
  }
}
