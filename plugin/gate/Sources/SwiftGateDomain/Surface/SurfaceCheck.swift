/// A commit and what it changed against its first parent, as `surface-check` reads it (fast modes
/// §3.2). Only Swift files carry text; every other changed path is listed in `otherPaths`.
public struct SurfaceCommit: Sendable, Equatable {
  /// Full sha of the commit under check.
  public let commit: String
  /// Full sha of its first parent.
  public let parent: String
  public let changes: [SurfaceFileChange]
  /// Changed paths that aren't Swift sources, which hold no bodies to judge.
  public let otherPaths: [String]

  public init(commit: String, parent: String, changes: [SurfaceFileChange], otherPaths: [String]) {
    self.commit = commit
    self.parent = parent
    self.changes = changes
    self.otherPaths = otherPaths
  }
}

/// One Swift file the commit added, changed or deleted.
public struct SurfaceFileChange: Sendable, Equatable {
  /// Toplevel-relative.
  public let path: String
  /// `nil` when the commit adds the file.
  public let parentText: String?
  /// `nil` when the commit deletes the file.
  public let commitText: String?

  public init(path: String, parentText: String?, commitText: String?) {
    self.path = path
    self.parentText = parentText
    self.commitText = commitText
  }
}

/// The allowed stub a judged body matched (fast modes §3.2, with §7's empty defaults).
public enum SurfaceStubForm: String, Sendable, Equatable, CaseIterable {
  /// No statements, or a bare `return`.
  case empty
  /// `nil`, `[]`, `[:]`, `0`, `false`, `""` or `.init()`.
  case emptyDefault
  /// An enum case with no payload, such as `.none`.
  case payloadFreeCase
  /// 1 call to a function or type the parent already declares, passing only names and empty
  /// defaults.
  case forward
  /// A reducer that returns `.none` for every action.
  case reducerNone
  /// `EmptyView()`, or a container of `EmptyView()`.
  case emptyView
  /// A `#Preview` or preview fixture with no non-empty literal.
  case previewWithoutData
  /// An initializer that only assigns its own parameters, or empty defaults, to `self`'s stored
  /// properties.
  case assignsParameters
  /// 1 initializer call whose arguments are each an empty default or a parameter passed through.
  case emptyValue
  /// An existing array literal that only gains bare type references or `Type.self` elements, as a
  /// command or registration list does.
  case registersType
}

/// Why a judged body is behaviour, not a stub.
public enum SurfaceBehaviour: Sendable, Equatable {
  /// A body matching no allowed stub; `excerpt` is its first statement.
  case notAStub(excerpt: String)
  /// A call to `fatalError` or `preconditionFailure`.
  case traps(callee: String)
  /// A non-empty literal in a preview or preview fixture.
  case sampleData(literal: String)
  /// A reducer body that does more than return `.none`.
  case reducerWork(excerpt: String)
  /// A SwiftUI `body` other than `EmptyView()` or a container of it.
  case viewContent(excerpt: String)
  /// A forwarding call whose callee the parent doesn't declare.
  case forwardsToNewCode(callee: String)
  /// An existing stored property whose value the commit changes.
  case changesStoredValue
  /// An added test file, or an added test in a changed one.
  case addsTest
}

/// One added or changed body and how `surface-check` judged it.
public struct SurfaceJudgement: Sendable, Equatable {
  public enum Outcome: Sendable, Equatable {
    case stub(SurfaceStubForm)
    case behaviour(SurfaceBehaviour)
  }

  public let file: String
  /// 1-based; `nil` for a finding about a whole file.
  public let line: Int?
  /// The declaration, qualified by its enclosing types (`Feature.load(id:)`, `Feature.title.set`).
  public let declaration: String
  public let outcome: Outcome

  public init(file: String, line: Int?, declaration: String, outcome: Outcome) {
    self.file = file
    self.line = line
    self.declaration = declaration
    self.outcome = outcome
  }
}

/// `swiftgate surface-check`: every body a surface commit adds or changes must be an allowed stub
/// (fast modes §3.2).
public enum SurfaceCheck {
  public static let behaviourRuleID = "surface-check.behaviour"
  public static let summaryRuleID = "surface-check.summary"

  /// Whether `path` is a Swift test source.
  public static func isTestFile(_ path: String) -> Bool {
    false
  }

  /// Judges every changed Swift file: an added test file whole, every other file through `scan`.
  public static func judge(
    _ surface: SurfaceCommit, scan: (SurfaceFileChange) -> [SurfaceJudgement]
  ) -> [SurfaceJudgement] {
    []
  }

  /// One major finding per behaviour, and a summary note.
  public static func findings(_ surface: SurfaceCommit, judgements: [SurfaceJudgement])
    throws(ReportContractViolation) -> [Finding]
  {
    []
  }
}
