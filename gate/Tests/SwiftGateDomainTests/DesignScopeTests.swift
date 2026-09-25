import Foundation
import SwiftGateDomain
import Testing

@Suite("DesignScope")
struct DesignScopeTests {
  private static func input(
    addsDependency: Bool = false, addsModuleKind: Bool = false, modulesAdded: Int = 0,
    modulesTouched: Int = 0
  ) throws -> DesignScopeInput {
    try DesignScopeInput(
      addsDependency: addsDependency, addsModuleKind: addsModuleKind,
      modulesAdded: modulesAdded, modulesTouched: modulesTouched)
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
  func newDependencyNeverQuick(_ counts: (modulesAdded: Int, modulesTouched: Int)) throws {
    for addsModuleKind in [false, true] {
      let recommendation = DesignScope.recommend(
        try Self.input(
          addsDependency: true, addsModuleKind: addsModuleKind, modulesAdded: counts.modulesAdded,
          modulesTouched: counts.modulesTouched))
      #expect(recommendation.tier != .quick)
    }
  }

  @Test(
    "a new module kind is never offered quick, for any module-count combination — catches an under-researched design skipping review",
    arguments: otherInputCombinations)
  func newModuleKindNeverQuick(_ counts: (modulesAdded: Int, modulesTouched: Int)) throws {
    for addsDependency in [false, true] {
      let recommendation = DesignScope.recommend(
        try Self.input(
          addsDependency: addsDependency, addsModuleKind: true, modulesAdded: counts.modulesAdded,
          modulesTouched: counts.modulesTouched))
      #expect(recommendation.tier != .quick)
    }
  }

  // MARK: - Quick

  @Test("a one-module change with no new dependency or module kind offers quick")
  func oneModuleChangeOffersQuick() throws {
    let recommendation = DesignScope.recommend(
      try Self.input(modulesAdded: 1, modulesTouched: 1))
    #expect(recommendation.tier == .quick)
    #expect(recommendation.reasons == [.noNewDependencyOrModuleKind])
  }

  @Test("no module-graph change at all offers quick")
  func noChangeOffersQuick() throws {
    let recommendation = DesignScope.recommend(try Self.input())
    #expect(recommendation.tier == .quick)
  }

  // MARK: - Deep: modulesAdded boundary (1 vs 2)

  @Test("adding 1 module does not trigger the modulesAdded deep rule")
  func oneModuleAddedIsNotDeep() throws {
    let recommendation = DesignScope.recommend(
      try Self.input(modulesAdded: 1, modulesTouched: 1))
    #expect(recommendation.tier != .deep)
  }

  @Test("adding 2 modules triggers the modulesAdded deep rule at its exact boundary")
  func twoModulesAddedIsDeep() throws {
    let recommendation = DesignScope.recommend(
      try Self.input(modulesAdded: 2, modulesTouched: 2))
    #expect(recommendation.tier == .deep)
    #expect(recommendation.reasons.contains(.modulesAdded))
  }

  // MARK: - Deep: modulesTouched boundary (3 vs 4)

  @Test("touching 3 modules does not trigger the modulesTouched deep rule")
  func threeModulesTouchedIsNotDeep() throws {
    let recommendation = DesignScope.recommend(try Self.input(modulesTouched: 3))
    #expect(recommendation.tier != .deep)
  }

  @Test("a 4-module change recommends deep with reasons, at its exact boundary")
  func fourModulesTouchedIsDeep() throws {
    let recommendation = DesignScope.recommend(try Self.input(modulesTouched: 4))
    #expect(recommendation.tier == .deep)
    #expect(recommendation.reasons == [.modulesTouched])
  }

  // MARK: - Deep: dependency-and-module-kind boundary (one alone vs. both together)

  @Test("a new dependency alone, with no module kind and low module counts, is standard, not deep")
  func dependencyAloneIsStandard() throws {
    let recommendation = DesignScope.recommend(try Self.input(addsDependency: true))
    #expect(recommendation.tier == .standard)
    #expect(recommendation.reasons == [.newDependency])
  }

  @Test("a new module kind alone, with no dependency and low module counts, is standard, not deep")
  func moduleKindAloneIsStandard() throws {
    let recommendation = DesignScope.recommend(try Self.input(addsModuleKind: true))
    #expect(recommendation.tier == .standard)
    #expect(recommendation.reasons == [.newModuleKind])
  }

  @Test(
    "a new dependency plus a new module kind together is deep even with no other change — the exact boundary between the two prior cases"
  )
  func dependencyAndModuleKindTogetherIsDeep() throws {
    let recommendation = DesignScope.recommend(
      try Self.input(addsDependency: true, addsModuleKind: true))
    #expect(recommendation.tier == .deep)
    #expect(recommendation.reasons == [.newDependencyAndModuleKind])
  }

  // MARK: - Multiple deep triggers report every reason

  @Test("every deep trigger that applies is reported, not just the first")
  func allDeepReasonsReported() throws {
    let recommendation = DesignScope.recommend(
      try Self.input(addsDependency: true, addsModuleKind: true, modulesAdded: 2, modulesTouched: 4)
    )
    #expect(
      Set(recommendation.reasons)
        == [.newDependencyAndModuleKind, .modulesAdded, .modulesTouched])
  }

  // MARK: - Input validation

  @Test("a negative modulesAdded is rejected")
  func negativeModulesAddedRejected() {
    #expect(throws: ReportContractViolation.self) {
      try DesignScopeInput(
        addsDependency: false, addsModuleKind: false, modulesAdded: -1, modulesTouched: 0)
    }
  }

  @Test("a negative modulesTouched is rejected")
  func negativeModulesTouchedRejected() {
    #expect(throws: ReportContractViolation.self) {
      try DesignScopeInput(
        addsDependency: false, addsModuleKind: false, modulesAdded: 0, modulesTouched: -1)
    }
  }

  @Test("modulesTouched under modulesAdded is rejected — an added module is always touched")
  func touchedLessThanAddedRejected() {
    #expect(throws: ReportContractViolation.self) {
      try DesignScopeInput(
        addsDependency: false, addsModuleKind: false, modulesAdded: 2, modulesTouched: 1)
    }
  }

  @Test("modulesTouched equal to modulesAdded is allowed")
  func touchedEqualToAddedAllowed() throws {
    let input = try DesignScopeInput(
      addsDependency: false, addsModuleKind: false, modulesAdded: 2, modulesTouched: 2)
    #expect(input.modulesAdded == 2)
    #expect(input.modulesTouched == 2)
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

  // MARK: - JSON decode contract

  @Test("a valid frame-answers file decodes to the matching input")
  func decodesValidFile() throws {
    let json = """
      {
        "schemaVersion": 1,
        "addsDependency": true,
        "addsModuleKind": false,
        "modulesAdded": 1,
        "modulesTouched": 3
      }
      """
    let input = try DesignScopeInputJSON.decode(Data(json.utf8))
    #expect(input.addsDependency)
    #expect(!input.addsModuleKind)
    #expect(input.modulesAdded == 1)
    #expect(input.modulesTouched == 3)
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
      {"schemaVersion": 1, "addsDependency": false, "addsModuleKind": false, "modulesAdded": 0}
      """
    #expect(throws: (any Error).self) {
      try DesignScopeInputJSON.decode(Data(json.utf8))
    }
  }

  @Test("an unsupported schemaVersion is rejected")
  func unsupportedSchemaVersionRejected() {
    let json = """
      {
        "schemaVersion": 2, "addsDependency": false, "addsModuleKind": false,
        "modulesAdded": 0, "modulesTouched": 0
      }
      """
    #expect(throws: ReportContractViolation.self) {
      try DesignScopeInputJSON.decode(Data(json.utf8))
    }
  }

  @Test("an invalid decoded value (modulesTouched under modulesAdded) is rejected, not clamped")
  func decodedInvalidValueRejected() {
    let json = """
      {
        "schemaVersion": 1, "addsDependency": false, "addsModuleKind": false,
        "modulesAdded": 3, "modulesTouched": 1
      }
      """
    #expect(throws: ReportContractViolation.self) {
      try DesignScopeInputJSON.decode(Data(json.utf8))
    }
  }
}
