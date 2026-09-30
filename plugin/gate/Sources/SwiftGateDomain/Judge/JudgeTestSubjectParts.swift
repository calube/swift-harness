/// The parts of a test's name that a Jev question reads by path (design §13.2): the whole name, the
/// behaviour it claims, and the regression it says it catches.
public struct JudgeTestName: Sendable, Equatable, Codable {
  /// The first `@Test("…")` display string, unescaped, else the test function's name.
  public let full: String
  /// The text before ` — catches ` (em dash, en dash or hyphen), else `full`.
  public let behavior: String
  /// `catches ` and the text after it; `nil` when the name has no catches part.
  public let catches: String?

  public init(full: String, behavior: String, catches: String?) {
    self.full = full
    self.behavior = behavior
    self.catches = catches
  }

  public static func parse(source: String) -> JudgeTestName {
    JudgeTestName(full: "", behavior: "", catches: nil)
  }
}

/// The assertion statements of a test's source, for the `assertions` state field (design §13.2).
public enum JudgeAssertions {
  public static func extract(source: String) -> [String] {
    []
  }
}
