import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

@Suite("surface-check over dependency accessors")
struct SurfaceDependencyAccessorTests {
  private static let accessors = "Sources/App/Dependencies.swift"

  private static func run(_ name: String) async throws -> (
    judgements: [SurfaceJudgement], report: RunReport
  ) {
    let reader = CapturedSurfaceReader(name: name)
    let (_, judgements) = try await SurfaceCheckRun.judgements(commit: name, reader: reader)
    let outcome = await SurfaceCheckRun.outcome(commit: name, reader: reader)
    let report = try StaticCheckReport.make(
      runID: "surface", durationMilliseconds: 0, outcome: outcome)
    return (judgements, report)
  }

  private static func judged(_ judgements: [SurfaceJudgement]) -> [SurfaceJudged] {
    judgements.map { SurfaceJudged(declaration: $0.declaration, outcome: $0.outcome) }
  }

  private static let client = "DependencyValues.shoppingListClient"
  private static let item = SurfaceJudged(
    "ShoppingItem.init(id:name:quantity:isBought:)", .assignsParameters)
  private static let preview = SurfaceJudged("ShoppingListClient.previewValue", .previewWithoutData)

  @Test(
    "a surface's DependencyValues accessor wired to the key its own file declares is a stub, and the `get { .init() }` and `set {}` stub still passes — catches a surface that wires its new client's accessor failing surface-check, so a parallel build's consumers can never inject a test client"
  )
  func wiredAccessorIsAStub() async throws {
    let (wired, wiredReport) = try await Self.run("allowed-dependency-accessor-wired")
    let (stubbed, stubbedReport) = try await Self.run("allowed-dependency-accessor-stub")

    #expect(
      Self.judged(wired) == [
        Self.item, Self.preview, SurfaceJudged("\(Self.client).get", .wiresDependency),
        SurfaceJudged("\(Self.client).set", .wiresDependency),
      ])
    #expect(wiredReport.verdict == .green, "\(wiredReport.findings.map(\.message))")
    #expect(wiredReport.verdict.exitCode == 0)
    #expect(
      Self.judged(stubbed) == [
        Self.item, Self.preview, SurfaceJudged("\(Self.client).get", .emptyDefault),
        SurfaceJudged("\(Self.client).set", .empty),
      ])
    #expect(stubbedReport.verdict == .green, "\(stubbedReport.findings.map(\.message))")
  }

  @Test(
    "an accessor may key on a type the base declares, or one another file of the same commit declares — catches the key looked up in only the accessor's own file"
  )
  func keyMayComeFromTheBaseOrTheCommit() async throws {
    let (judgements, report) = try await Self.run("allowed-dependency-accessor-keys")

    #expect(
      Self.judged(judgements) == [
        SurfaceJudged("DependencyValues.itemClient.get", .wiresDependency),
        SurfaceJudged("DependencyValues.itemClient.set", .wiresDependency),
        SurfaceJudged("DependencyValues.profileClient.get", .wiresDependency),
        SurfaceJudged("DependencyValues.profileClient.set", .wiresDependency),
      ])
    #expect(report.verdict == .green, "\(report.findings.map(\.message))")
  }

  @Test(
    "an accessor that does more than read or write its key's slot, keys on an undeclared type, or sits outside DependencyValues is behaviour — catches a getter that maps or replaces the client, or a setter that stores something else, passing as wiring"
  )
  func nearMissesAreBehaviour() async throws {
    let (judgements, report) = try await Self.run("rejected-dependency-accessor-near-miss")

    let wired = SurfaceJudgement.Outcome.stub(.wiresDependency)
    func notAStub(_ excerpt: String) -> SurfaceJudgement.Outcome {
      .behaviour(.notAStub(excerpt: excerpt))
    }
    let unknownKey = SurfaceJudgement.Outcome.behaviour(
      .undeclaredDependencyKey(key: "UnknownClient"))
    let expected: [(String, SurfaceJudgement.Outcome)] = [
      ("DependencyValues.mappedClient.get", notAStub("self[ItemClient.self].configured()")),
      ("DependencyValues.mappedClient.set", wired),
      ("DependencyValues.fixedTimeout.get", notAStub("30")),
      ("DependencyValues.fixedTimeout.set", .stub(.empty)),
      ("DependencyValues.resetClient.get", wired),
      ("DependencyValues.resetClient.set", notAStub("self[ItemClient.self] = .init()")),
      ("DependencyValues.renamedClient.get", wired),
      ("DependencyValues.renamedClient.set", notAStub("self[ItemClient.self] = client")),
      ("DependencyValues.unknownClient.get", unknownKey),
      ("DependencyValues.unknownClient.set", unknownKey),
      ("Store.client.get", notAStub("self[ItemClient.self]")),
      ("Store.client.set", notAStub("self[ItemClient.self] = newValue")),
    ]
    #expect(judgements.map(\.declaration) == expected.map(\.0))
    #expect(judgements.map(\.outcome) == expected.map(\.1))
    #expect(report.verdict == .red)
    #expect(report.verdict.exitCode == 1)
    let findings = report.findings.filter { $0.ruleID == SurfaceCheck.behaviourRuleID }
    #expect(findings.map(\.line) == [5, 10, 16, 21, 25, 26, 32, 33])
    #expect(findings.allSatisfy { $0.file == Self.accessors && $0.severity == .major })
    let unknown = try #require(findings.first { $0.line == 25 })
    #expect(
      unknown.message
        == "`DependencyValues.unknownClient.get` keys on `UnknownClient`, which neither the "
        + "commit nor its parent declares: a wired accessor reads and writes the slot of a key "
        + "type the surface or the code before it declares")
  }

  @Test(
    "the parent's declarations are read for a key only the base declares, and not for one the commit declares — catches every wired accessor parsing the parent's whole tree"
  )
  func parentReadOnlyForBaseKeys() async throws {
    struct CountingReader: SurfaceCommitReading {
      let inner: CapturedSurfaceReader
      let reads: Counter

      func read(_ commit: String) async throws(SurfaceReadError) -> SurfaceCommit {
        try await inner.read(commit)
      }

      func parentSwiftSources(of surface: SurfaceCommit) async throws(SurfaceReadError)
        -> [String: String]
      {
        await reads.increment()
        return try await inner.parentSwiftSources(of: surface)
      }
    }
    actor Counter {
      var value = 0
      func increment() { value += 1 }
    }

    let commitKey = Counter()
    _ = try await SurfaceCheckRun.judgements(
      commit: "x",
      reader: CountingReader(
        inner: CapturedSurfaceReader(name: "allowed-dependency-accessor-wired"), reads: commitKey))
    let baseKey = Counter()
    _ = try await SurfaceCheckRun.judgements(
      commit: "x",
      reader: CountingReader(
        inner: CapturedSurfaceReader(name: "allowed-dependency-accessor-keys"), reads: baseKey))

    #expect(await commitKey.value == 0)
    #expect(await baseKey.value == 1)
  }
}
