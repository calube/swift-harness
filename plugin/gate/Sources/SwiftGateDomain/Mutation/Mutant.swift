/// The behavioral mutation operators of spec §7.4.
public enum MutationOperator: String, Sendable, CaseIterable, Comparable {
  /// `if c` → `if !(c)` for `if`, `guard`, `while` and `repeat … while` conditions.
  case negateConditional = "negate-conditional"
  /// `<` ↔ `<=`, `>` ↔ `>=`.
  case relationalBoundary = "relational-boundary"
  /// A returned value replaced by its type's default (`false`, `0`, `""`, `nil`, `[]`, `[:]`).
  case returnDefault = "return-default"
  /// A call statement whose result is unused, removed.
  case removeCall = "remove-call"
  /// A TCA effect returned from a reducer replaced by `.none`, or a `send` removed.
  case removeEffect = "remove-effect"

  public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// One source edit: `original` at `utf8Offset` replaced by `replacement`.
public struct Mutant: Sendable, Hashable {
  /// Project-relative path.
  public let file: String
  public let line: Int
  public let column: Int
  public let mutationOperator: MutationOperator
  public let utf8Offset: Int
  public let original: String
  public let replacement: String
  /// The affected lines before (`-`) and after (`+`) the edit.
  public let diff: String

  /// `nil` when `original` is not the text at `utf8Offset` of `text`.
  public init?(
    file: String, text: String, utf8Offset: Int, original: String, replacement: String,
    operator mutationOperator: MutationOperator
  ) {
    let bytes = Array(text.utf8)
    let originalBytes = Array(original.utf8)
    let end = utf8Offset + originalBytes.count
    guard utf8Offset >= 0, end <= bytes.count, Array(bytes[utf8Offset..<end]) == originalBytes
    else { return nil }
    let newline = UInt8(ascii: "\n")
    let lineStart = bytes[..<utf8Offset].lastIndex(of: newline).map { $0 + 1 } ?? 0
    let lineEnd = bytes[end...].firstIndex(of: newline) ?? bytes.count
    self.file = file
    self.line = bytes[..<utf8Offset].count { $0 == newline } + 1
    self.column = utf8Offset - lineStart + 1
    self.mutationOperator = mutationOperator
    self.utf8Offset = utf8Offset
    self.original = original
    self.replacement = replacement
    let before = String(decoding: bytes[lineStart..<lineEnd], as: UTF8.self)
    let after = String(
      decoding: Array(bytes[lineStart..<utf8Offset]) + Array(replacement.utf8)
        + Array(bytes[end..<lineEnd]), as: UTF8.self)
    diff = (Self.prefixed(before, "-") + Self.prefixed(after, "+")).joined(separator: "\n")
  }

  /// `text` with the edit made, or `nil` if `text` no longer has `original` at the offset.
  public func apply(to text: String) -> String? {
    let bytes = Array(text.utf8)
    let originalBytes = Array(original.utf8)
    let end = utf8Offset + originalBytes.count
    guard end <= bytes.count, Array(bytes[utf8Offset..<end]) == originalBytes else { return nil }
    return String(
      decoding: Array(bytes[..<utf8Offset]) + Array(replacement.utf8) + Array(bytes[end...]),
      as: UTF8.self)
  }

  /// Orders mutants by position, then operator and replacement.
  public static func sourceOrder(_ lhs: Mutant, _ rhs: Mutant) -> Bool {
    (lhs.file, lhs.utf8Offset, lhs.mutationOperator.rawValue, lhs.replacement)
      < (rhs.file, rhs.utf8Offset, rhs.mutationOperator.rawValue, rhs.replacement)
  }

  private static func prefixed(_ text: String, _ marker: String) -> [String] {
    text.split(separator: "\n", omittingEmptySubsequences: false).map { marker + $0 }
  }
}

/// A mutant on a line annotated `// swiftgate:equivalent-mutant — <reason>`: not run.
public struct EquivalentMutant: Sendable, Equatable {
  public let mutant: Mutant
  public let reason: String

  public init(mutant: Mutant, reason: String) {
    self.mutant = mutant
    self.reason = reason
  }
}

/// An equivalent-mutant annotation without a reason.
public struct BareEquivalentMarker: Sendable, Equatable {
  public let file: String
  public let line: Int

  public init(file: String, line: Int) {
    self.file = file
    self.line = line
  }
}

/// What running the affected T1 tests against one mutant showed.
public enum MutantOutcome: Sendable, Equatable {
  case killed(failingTests: [String])
  /// The tests did not finish within the mutant timeout: an infinite loop counts as a kill.
  case timedOut(after: Duration)
  case survived(testsRun: Int)
  /// No T1 test target depends on the mutated module, or the ones that do ran no tests.
  case noTests
  /// The mutant does not compile; it says nothing about the tests.
  case unviable(String)
  /// The environment stopped the run (baseline broken, build tool failure).
  case noEvidence(String)
}

public struct MutantResult: Sendable, Equatable {
  public let mutant: Mutant
  public let outcome: MutantOutcome

  public init(mutant: Mutant, outcome: MutantOutcome) {
    self.mutant = mutant
    self.outcome = outcome
  }
}
