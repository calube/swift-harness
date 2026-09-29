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
  /// Only a `throw` of an error value: a payload-free case, an initializer call or an empty-payload
  /// case, each as the other stub forms allow them.
  case throwsError
  /// An enum case the repository declares, constructed with each associated value an empty
  /// default or a parameter passed through (`.exited(0)`, `.loaded(items)`).
  case emptyPayloadCase
  /// A parameter or a property of `self` returned unchanged (`value`, `self.limit`).
  case returnsUnchanged
  /// An existing `Package.swift` whose only change is new elements in its `dependencies`,
  /// `products` and `targets` lists: a package, product, target or product declaration, or a
  /// target name.
  case extendsManifest
  /// A `DependencyValues` accessor wired to its key's slot and nothing more: a getter that is
  /// exactly `self[Key.self]` and a setter that is exactly `self[Key.self] = newValue`, for a key
  /// type the commit or its parent declares.
  case wiresDependency
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
  /// An existing `Package.swift` changed by more than added dependencies, products and targets;
  /// `excerpt` is the first change found.
  case changesManifest(excerpt: String)
  /// A `DependencyValues` accessor wired to `key`'s slot, where neither the commit nor its parent
  /// declares a type named `key`.
  case undeclaredDependencyKey(key: String)
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

  /// Whether `path` is a Swift test source: a `*Tests.swift` or `*Test.swift` file, or any Swift
  /// file under a directory named `Tests` or ending in `Tests`.
  public static func isTestFile(_ path: String) -> Bool {
    guard path.hasSuffix(".swift") else { return false }
    var components = path.split(separator: "/")
    let name = components.removeLast()
    return name.hasSuffix("Tests.swift") || name.hasSuffix("Test.swift")
      || components.contains { $0.hasSuffix("Tests") }
  }

  /// Judges every changed Swift file: an added test file whole, every other file through `scan`.
  /// A deleted file holds no body to judge.
  public static func judge(
    _ surface: SurfaceCommit, scan: (SurfaceFileChange) -> [SurfaceJudgement]
  ) -> [SurfaceJudgement] {
    surface.changes.flatMap { change -> [SurfaceJudgement] in
      guard change.commitText != nil else { return [] }
      if change.parentText == nil, isTestFile(change.path) {
        let name = change.path.split(separator: "/").last.map(String.init) ?? change.path
        return [
          SurfaceJudgement(
            file: change.path, line: nil, declaration: name, outcome: .behaviour(.addsTest))
        ]
      }
      return scan(change)
    }
  }

  /// One major finding per behaviour, and a summary note.
  public static func findings(_ surface: SurfaceCommit, judgements: [SurfaceJudgement])
    throws(ReportContractViolation) -> [Finding]
  {
    var findings: [Finding] = []
    var stubs = 0
    for judgement in judgements {
      switch judgement.outcome {
      case .stub: stubs += 1
      case .behaviour(let behaviour):
        findings.append(
          try Finding(
            ruleID: behaviourRuleID, severity: .major, file: judgement.file, line: judgement.line,
            message: "`\(judgement.declaration)` \(describe(behaviour))",
            failureScenario: nil))
      }
    }
    let other = surface.otherPaths.count
    findings.append(
      try Finding(
        ruleID: summaryRuleID, severity: .nit, file: ".", line: nil,
        message:
          "\(judgements.count) added or changed bodies judged across \(surface.changes.count) "
          + "changed Swift files: \(stubs) allowed stubs, \(judgements.count - stubs) behaviour; "
          + "\(other) non-Swift \(other == 1 ? "path" : "paths") not judged",
        failureScenario: nil))
    return findings
  }

  static func describe(_ behaviour: SurfaceBehaviour) -> String {
    switch behaviour {
    case .notAStub(let excerpt):
      "isn't an allowed stub (`\(excerpt)`): a surface body is empty; returns 1 empty default, "
        + "payload-free case, enum case built from empty defaults and parameters, or parameter or "
        + "property of `self` unchanged; only throws such an error value; or forwards to code the "
        + "parent declares"
    case .traps(let callee):
      "calls `\(callee)`: a trapping stub fails every test for a reason other than the missing "
        + "behaviour"
    case .sampleData(let literal):
      "holds sample data (`\(literal)`): previews and preview fixtures in a surface hold no "
        + "non-empty literal"
    case .reducerWork(let excerpt):
      "does reducer work (`\(excerpt)`): a surface reducer returns `.none` for every action and "
        + "never mutates state"
    case .viewContent(let excerpt):
      "renders content (`\(excerpt)`): a surface view's body is `EmptyView()` or a container of it"
    case .forwardsToNewCode(let callee):
      "forwards to `\(callee)`, which the parent doesn't declare: a forwarding stub calls code "
        + "already on the parent"
    case .changesStoredValue:
      "changes an existing stored value: a surface leaves existing behaviour unchanged"
    case .changesManifest(let excerpt):
      "changes the package manifest (`\(excerpt)`): a surface only adds dependencies, products "
        + "and targets to an existing manifest's lists, and removes or changes nothing"
    case .undeclaredDependencyKey(let key):
      "keys on `\(key)`, which neither the commit nor its parent declares: a wired accessor reads "
        + "and writes the slot of a key type the surface or the code before it declares"
    case .addsTest:
      "adds a test: a surface commit adds no tests; they follow it"
    }
  }
}
