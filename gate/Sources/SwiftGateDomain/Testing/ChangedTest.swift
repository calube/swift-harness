/// A test function the change adds or edits: the unit `prove`, `stress` and per-test reach act on
/// (spec §7.2 rules 2 and 6, §7.4).
public struct ChangedTest: Sendable, Hashable {
  public enum Framework: Sendable, Hashable {
    case swiftTesting
    case xcTest
  }

  public let framework: Framework
  /// The test target (module) the function is compiled into.
  public let target: String
  /// Enclosing type names, outermost first. Empty for a free Swift Testing function.
  public let suites: [String]
  /// Swift Testing: the function's name with argument labels (`doubles()`, `param(value:)`).
  /// XCTest: the method name (`testDoubles`).
  public let function: String
  /// Repository-relative source file.
  public let file: String
  /// Line of the declaration (its first attribute).
  public let line: Int
  /// Last line of the declaration.
  public let lastLine: Int
  /// The `@Test("…")` display name, if any.
  public let displayName: String?

  public init(
    framework: Framework, target: String, suites: [String], function: String, file: String,
    line: Int, lastLine: Int? = nil, displayName: String? = nil
  ) {
    self.framework = framework
    self.target = target
    self.suites = suites
    self.function = function
    self.file = file
    self.line = line
    self.lastLine = max(line, lastLine ?? line)
    self.displayName = displayName
  }

  /// The id `swift test list` prints: `Target.Suite/Inner/name()`, `Target.name()` for a free
  /// function, `Target.Class/testName` for XCTest.
  public var id: String {
    suites.isEmpty
      ? "\(target).\(function)"
      : "\(target).\(suites.joined(separator: "/"))/\(function)"
  }

  /// A `swift test --filter` expression selecting this test and no other. A Swift Testing id ends
  /// in `)`, so anchoring the start is enough; an XCTest name must also be anchored at the end so
  /// `testA` does not select `testAB`.
  public var filter: String {
    let escaped = id.map { Self.regexMetacharacters.contains($0) ? "\\\($0)" : "\($0)" }
      .joined()
    return framework == .xcTest ? "^\(escaped)$" : "^\(escaped)"
  }

  private static let regexMetacharacters = Set(#"\^$.|?*+()[]{}"#)

  /// Whether an xUnit `<testcase>` reports this test. Both frameworks write the class name as
  /// `Target.Suite.Inner`; Swift Testing writes a free function's class name as the bare target.
  public func matches(_ testCase: XUnitTestCase) -> Bool {
    testCase.className == ([target] + suites).joined(separator: ".") && testCase.name == function
  }

  /// One `--filter` expression selecting every test in `tests`.
  public static func filter(selecting tests: [ChangedTest]) -> String {
    tests.count == 1 ? tests[0].filter : "(" + tests.map(\.filter).joined(separator: "|") + ")"
  }
}
