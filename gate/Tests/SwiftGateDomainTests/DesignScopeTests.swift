import Foundation
import SwiftGateDomain
import Testing

@Suite("DesignScope")
struct DesignScopeTests {
  // MARK: - recommend(_:) over already-derived facts

  private static func facts(
    addsDependency: Bool = false, addsModuleKind: Bool = false, modulesAdded: Int = 0,
    modulesTouched: Int = 0
  ) -> DesignScopeGraphFacts {
    DesignScopeGraphFacts(
      addsDependency: addsDependency, addsModuleKind: addsModuleKind, modulesAdded: modulesAdded,
      modulesTouched: modulesTouched)
  }

  // MARK: - Safety property: quick is never offered with a new dependency or module kind.

  /// Every combination of the other three inputs, at and around their thresholds, so the safety
  /// property is checked exhaustively rather than on hand-picked cases.
  private static let otherInputCombinations: [(modulesAdded: Int, modulesTouched: Int)] = {
    let counts = [0, 1, 2, 3, 4, 5]
    return counts.flatMap { added in counts.map { touched in (added, touched) } }
      .filter { $0.1 >= $0.0 }
  }()

  @Test(
    "a new dependency is never offered quick, for any module-count combination — catches an under-researched design skipping review",
    arguments: otherInputCombinations)
  func newDependencyNeverQuick(_ counts: (modulesAdded: Int, modulesTouched: Int)) {
    for addsModuleKind in [false, true] {
      let recommendation = DesignScope.recommend(
        Self.facts(
          addsDependency: true, addsModuleKind: addsModuleKind, modulesAdded: counts.modulesAdded,
          modulesTouched: counts.modulesTouched))
      #expect(recommendation.tier != .quick)
    }
  }

  @Test(
    "a new module kind is never offered quick, for any module-count combination — catches an under-researched design skipping review",
    arguments: otherInputCombinations)
  func newModuleKindNeverQuick(_ counts: (modulesAdded: Int, modulesTouched: Int)) {
    for addsDependency in [false, true] {
      let recommendation = DesignScope.recommend(
        Self.facts(
          addsDependency: addsDependency, addsModuleKind: true, modulesAdded: counts.modulesAdded,
          modulesTouched: counts.modulesTouched))
      #expect(recommendation.tier != .quick)
    }
  }

  // MARK: - Quick

  @Test("a one-module change with no new dependency or module kind offers quick")
  func oneModuleChangeOffersQuick() {
    let recommendation = DesignScope.recommend(Self.facts(modulesAdded: 1, modulesTouched: 1))
    #expect(recommendation.tier == .quick)
    #expect(recommendation.reasons == [.noNewDependencyOrModuleKind])
  }

  @Test("no module-graph change at all offers quick")
  func noChangeOffersQuick() {
    let recommendation = DesignScope.recommend(Self.facts())
    #expect(recommendation.tier == .quick)
  }

  // MARK: - Deep: modulesAdded boundary (1 vs 2)

  @Test("adding 1 module does not trigger the modulesAdded deep rule")
  func oneModuleAddedIsNotDeep() {
    let recommendation = DesignScope.recommend(Self.facts(modulesAdded: 1, modulesTouched: 1))
    #expect(recommendation.tier != .deep)
  }

  @Test("adding 2 modules triggers the modulesAdded deep rule at its exact boundary")
  func twoModulesAddedIsDeep() {
    let recommendation = DesignScope.recommend(Self.facts(modulesAdded: 2, modulesTouched: 2))
    #expect(recommendation.tier == .deep)
    #expect(recommendation.reasons.contains(.modulesAdded))
  }

  // MARK: - Deep: modulesTouched boundary (3 vs 4)

  @Test("touching 3 modules does not trigger the modulesTouched deep rule")
  func threeModulesTouchedIsNotDeep() {
    let recommendation = DesignScope.recommend(Self.facts(modulesTouched: 3))
    #expect(recommendation.tier != .deep)
  }

  @Test("a 4-module change recommends deep with reasons, at its exact boundary")
  func fourModulesTouchedIsDeep() {
    let recommendation = DesignScope.recommend(Self.facts(modulesTouched: 4))
    #expect(recommendation.tier == .deep)
    #expect(recommendation.reasons == [.modulesTouched])
  }

  // MARK: - Deep: dependency-and-module-kind boundary (one alone vs. both together)

  @Test("a new dependency alone, with no module kind and low module counts, is standard, not deep")
  func dependencyAloneIsStandard() {
    let recommendation = DesignScope.recommend(Self.facts(addsDependency: true))
    #expect(recommendation.tier == .standard)
    #expect(recommendation.reasons == [.newDependency])
  }

  @Test("a new module kind alone, with no dependency and low module counts, is standard, not deep")
  func moduleKindAloneIsStandard() {
    let recommendation = DesignScope.recommend(Self.facts(addsModuleKind: true))
    #expect(recommendation.tier == .standard)
    #expect(recommendation.reasons == [.newModuleKind])
  }

  @Test(
    "a new dependency plus a new module kind together is deep even with no other change — the exact boundary between the two prior cases"
  )
  func dependencyAndModuleKindTogetherIsDeep() {
    let recommendation = DesignScope.recommend(
      Self.facts(addsDependency: true, addsModuleKind: true))
    #expect(recommendation.tier == .deep)
    #expect(recommendation.reasons == [.newDependencyAndModuleKind])
  }

  // MARK: - Multiple deep triggers report every reason

  @Test("every deep trigger that applies is reported, not just the first")
  func allDeepReasonsReported() {
    let recommendation = DesignScope.recommend(
      Self.facts(
        addsDependency: true, addsModuleKind: true, modulesAdded: 2, modulesTouched: 4))
    #expect(
      Set(recommendation.reasons)
        == [.newDependencyAndModuleKind, .modulesAdded, .modulesTouched])
  }

  // MARK: - Reasons are closed and every case has a distinct human message

  @Test(
    "every reason has a non-empty, distinct human message", arguments: DesignScopeReason.allCases)
  func everyReasonHasAMessage(_ reason: DesignScopeReason) {
    #expect(!reason.message.isEmpty)
  }

  @Test("reason messages are distinct across cases — catches two reasons sharing one message")
  func reasonMessagesAreDistinct() {
    let messages = DesignScopeReason.allCases.map(\.message)
    #expect(Set(messages).count == messages.count)
  }

  @Test("the dependency-and-module-kind message names both signals")
  func dependencyAndModuleKindMessage() {
    let message = DesignScopeReason.newDependencyAndModuleKind.message
    #expect(message.contains("dependency"))
    #expect(message.contains("module kind"))
  }

  @Test("the modulesAdded message names its threshold")
  func modulesAddedMessage() {
    #expect(
      DesignScopeReason.modulesAdded.message.contains("\(DesignScope.modulesAddedDeepThreshold)"))
  }

  @Test("the newModuleKind message names a module kind, not a dependency")
  func newModuleKindMessage() {
    let message = DesignScopeReason.newModuleKind.message
    #expect(message.contains("module kind"))
    #expect(!message.contains("dependency"))
  }

  // MARK: - deriveFacts(answers:graph:): counting against a real, in-memory module graph

  /// A small graph with two existing kinds (`.feature` from `Core`, `.client` from `APIClient`
  /// and `APIClientLive`), pure in-memory: no SwiftPM, no files, no IO.
  private static func graph() throws -> ModuleGraph {
    try ModuleGraph(packages: [
      PackageManifest(
        name: "Sample", path: "Sample",
        targets: [
          PackageTarget(name: "Core", type: .library, path: "Sample/Sources/Core"),
          PackageTarget(name: "APIClient", type: .library, path: "Sample/Sources/APIClient"),
          PackageTarget(
            name: "APIClientLive", type: .library, path: "Sample/Sources/APIClientLive",
            targetDependencies: ["APIClient"]),
        ])
    ])
  }

  @Test("a new module kind absent from the graph is counted as adding a module kind")
  func newModuleKindDetected() throws {
    let facts = try DesignScope.deriveFacts(
      answers: DesignScopeAnswers(
        touchedModules: [], newModules: [DesignScopeNewModule(name: "Engine", kind: .engine)],
        newDependencies: []),
      graph: Self.graph())
    #expect(facts.addsModuleKind)
    #expect(facts.modulesAdded == 1)
    #expect(facts.modulesTouched == 1)
  }

  @Test(
    "a new module whose kind already exists in the graph is not a new kind — the exact boundary against the previous case"
  )
  func newModuleWithExistingKindIsNotANewKind() throws {
    let facts = try DesignScope.deriveFacts(
      answers: DesignScopeAnswers(
        touchedModules: [], newModules: [DesignScopeNewModule(name: "Widget", kind: .feature)],
        newDependencies: []),
      graph: Self.graph())
    #expect(!facts.addsModuleKind)
  }

  @Test("modulesTouched is the distinct union of touchedModules and newModules' names")
  func modulesTouchedIsTheUnion() throws {
    let facts = try DesignScope.deriveFacts(
      answers: DesignScopeAnswers(
        touchedModules: ["Core", "APIClient"],
        newModules: [DesignScopeNewModule(name: "Widget", kind: .feature)], newDependencies: []),
      graph: Self.graph())
    #expect(facts.modulesTouched == 3)
    #expect(facts.modulesAdded == 1)
  }

  @Test("addsDependency is true exactly when newDependencies isn't empty")
  func addsDependencyReflectsNewDependencies() throws {
    let withDependency = try DesignScope.deriveFacts(
      answers: DesignScopeAnswers(
        touchedModules: [], newModules: [], newDependencies: ["swift-algorithms"]),
      graph: Self.graph())
    #expect(withDependency.addsDependency)
    let withoutDependency = try DesignScope.deriveFacts(
      answers: DesignScopeAnswers(touchedModules: [], newModules: [], newDependencies: []),
      graph: Self.graph())
    #expect(!withoutDependency.addsDependency)
  }

  @Test("a touched module absent from the graph is rejected, not silently ignored")
  func touchedModuleNotInGraphRejected() throws {
    #expect(throws: DesignScopeValidationError.touchedModuleNotInGraph("Ghost")) {
      try DesignScope.deriveFacts(
        answers: DesignScopeAnswers(
          touchedModules: ["Ghost"], newModules: [], newDependencies: []), graph: Self.graph())
    }
  }

  @Test("a \"new\" module that already exists in the graph is rejected, not silently accepted")
  func newModuleAlreadyExistsRejected() throws {
    #expect(throws: DesignScopeValidationError.newModuleAlreadyExists("Core")) {
      try DesignScope.deriveFacts(
        answers: DesignScopeAnswers(
          touchedModules: [], newModules: [DesignScopeNewModule(name: "Core", kind: .feature)],
          newDependencies: []), graph: Self.graph())
    }
  }

  @Test("a name repeated within touchedModules is rejected")
  func duplicateWithinTouchedRejected() throws {
    #expect(throws: DesignScopeValidationError.duplicateName("Core")) {
      try DesignScope.deriveFacts(
        answers: DesignScopeAnswers(
          touchedModules: ["Core", "Core"], newModules: [], newDependencies: []),
        graph: Self.graph())
    }
  }

  @Test("a name repeated within newModules is rejected")
  func duplicateWithinNewRejected() throws {
    #expect(throws: DesignScopeValidationError.duplicateName("Widget")) {
      try DesignScope.deriveFacts(
        answers: DesignScopeAnswers(
          touchedModules: [],
          newModules: [
            DesignScopeNewModule(name: "Widget", kind: .feature),
            DesignScopeNewModule(name: "Widget", kind: .engine),
          ], newDependencies: []), graph: Self.graph())
    }
  }

  @Test(
    "a name in both touchedModules and newModules is a duplicate, checked before graph membership"
  )
  func duplicateAcrossTouchedAndNewRejected() throws {
    #expect(throws: DesignScopeValidationError.duplicateName("Core")) {
      try DesignScope.deriveFacts(
        answers: DesignScopeAnswers(
          touchedModules: ["Core"],
          newModules: [DesignScopeNewModule(name: "Core", kind: .feature)], newDependencies: []),
        graph: Self.graph())
    }
  }

  // MARK: - JSON decode contract

  @Test("a valid frame-answers file decodes to the matching answers")
  func decodesValidFile() throws {
    let json = """
      {
        "schemaVersion": 1,
        "touchedModules": ["Core"],
        "newModules": [{"name": "Engine", "kind": "engine"}],
        "newDependencies": ["swift-algorithms"]
      }
      """
    let answers = try DesignScopeInputJSON.decode(Data(json.utf8))
    #expect(answers.touchedModules == ["Core"])
    #expect(answers.newModules == [DesignScopeNewModule(name: "Engine", kind: .engine)])
    #expect(answers.newDependencies == ["swift-algorithms"])
  }

  @Test("malformed JSON fails to decode — never falls back to a default tier")
  func malformedJSONFailsToDecode() {
    #expect(throws: (any Error).self) {
      try DesignScopeInputJSON.decode(Data("{not json".utf8))
    }
  }

  @Test("a missing key fails to decode")
  func missingKeyFailsToDecode() {
    let json = """
      {"schemaVersion": 1, "touchedModules": [], "newModules": []}
      """
    #expect(throws: (any Error).self) {
      try DesignScopeInputJSON.decode(Data(json.utf8))
    }
  }

  @Test("an unrecognised module kind fails to decode, never becomes a default kind")
  func unknownKindFailsToDecode() {
    let json = """
      {
        "schemaVersion": 1, "touchedModules": [],
        "newModules": [{"name": "Engine", "kind": "not-a-kind"}], "newDependencies": []
      }
      """
    #expect(throws: (any Error).self) {
      try DesignScopeInputJSON.decode(Data(json.utf8))
    }
  }

  @Test("an unsupported schemaVersion is rejected")
  func unsupportedSchemaVersionRejected() {
    let json = """
      {
        "schemaVersion": 2, "touchedModules": [], "newModules": [], "newDependencies": []
      }
      """
    #expect(throws: ReportContractViolation.self) {
      try DesignScopeInputJSON.decode(Data(json.utf8))
    }
  }
}
