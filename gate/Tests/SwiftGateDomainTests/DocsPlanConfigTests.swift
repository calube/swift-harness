import SwiftGateDomain
import Testing

@Suite("Docs and plan config")
struct DocsPlanConfigTests {
  /// A root table with only the keys `ConfigSchema` requires, so each test adds just the `docs` /
  /// `plan` keys it cares about.
  private func minimalRoot(merging extra: [String: ConfigValue] = [:]) -> ConfigValue {
    var table: [String: ConfigValue] = [
      "schema": .integer(1),
      "xcode": .string("26.2"),
      "app_scheme": .string("App"),
      "packages": .array([.string("Packages/*")]),
      "simulator": .table(["device": .string("iPhone 17"), "os": .string("26.2")]),
    ]
    for (key, value) in extra { table[key] = value }
    return .table(table)
  }

  @Test(
    "docs and plan sections default when absent — catches an unconfigured repo losing every bound")
  func defaultsApplyWhenAbsent() throws {
    let config = try ConfigSchema.config(from: minimalRoot())
    #expect(config.docs == DocsConfig())
    #expect(config.plan == PlanConfig())
  }

  @Test("an unknown [plan] key is rejected — catches a typo disabling a bound")
  func unknownPlanKeyRejected() {
    let root = minimalRoot(merging: ["plan": .table(["max_paralel": .integer(3)])])
    #expect {
      _ = try ConfigSchema.config(from: root)
    } throws: { error in
      (error as? ConfigValidationError)?.issues == [.unknownKey(path: "plan.max_paralel")]
    }
  }

  @Test("an unknown [docs] key is rejected — catches a typo disabling a doc rule")
  func unknownDocsKeyRejected() {
    let root = minimalRoot(merging: ["docs": .table(["managed_file": .array([])])])
    #expect {
      _ = try ConfigSchema.config(from: root)
    } throws: { error in
      (error as? ConfigValidationError)?.issues == [.unknownKey(path: "docs.managed_file")]
    }
  }

  @Test(
    "a banned phrase without a reason is rejected — catches an unexplained ban nobody can act on")
  func bannedPhraseWithoutReasonRejected() {
    let root = minimalRoot(
      merging: [
        "docs": .table([
          "banned_phrases": .array([.table(["phrase": .string("leverage")])])
        ])
      ])
    #expect {
      _ = try ConfigSchema.config(from: root)
    } throws: { error in
      (error as? ConfigValidationError)?.issues == [
        .missingKey(path: "docs.banned_phrases[0].reason")
      ]
    }
  }

  @Test(
    "nested [docs.budgets] parses per-section word budgets — catches a flat budgets table silently dropping per-section limits"
  )
  func nestedDocsBudgetsParses() throws {
    let root = minimalRoot(
      merging: [
        "docs": .table([
          "budgets": .table([
            "router": .integer(500),
            "topic": .integer(900),
            "design": .integer(1_300),
            "agents_md_lines": .integer(70),
            "sections": .table(["Problem": .integer(150), "Risks": .integer(100)]),
          ])
        ])
      ])
    let config = try ConfigSchema.config(from: root)
    #expect(config.docs.budgets.router == 500)
    #expect(config.docs.budgets.topic == 900)
    #expect(config.docs.budgets.design == 1_300)
    #expect(config.docs.budgets.agentsMdLines == 70)
    #expect(
      config.docs.budgets.sections == ["architecture": 80, "Problem": 150, "Risks": 100])
  }

  @Test(
    "an unconfigured [docs.budgets.sections] keeps Architecture's default 80-word budget — catches the spec's own limit going unenforced when a repo sets no override"
  )
  func architectureDefaultSurvivesWhenSectionsUnconfigured() throws {
    let root = minimalRoot(merging: ["docs": .table(["budgets": .table([:])])])
    let config = try ConfigSchema.config(from: root)
    #expect(config.docs.budgets.sections == ["architecture": 80])
  }

  @Test(
    "an unrelated [docs.budgets.sections] key merges over, not replaces, Architecture's default — catches one section's override erasing every other section's default"
  )
  func unrelatedSectionKeyMergesOverArchitectureDefault() throws {
    let root = minimalRoot(
      merging: [
        "docs": .table([
          "budgets": .table(["sections": .table(["risks": .integer(50)])])
        ])
      ])
    let config = try ConfigSchema.config(from: root)
    #expect(config.docs.budgets.sections == ["architecture": 80, "risks": 50])
  }

  @Test(
    "a configured [docs.budgets.sections.architecture] overrides, rather than adds to, the default"
  )
  func configuredArchitectureBudgetOverridesDefault() throws {
    let root = minimalRoot(
      merging: [
        "docs": .table([
          "budgets": .table(["sections": .table(["architecture": .integer(120)])])
        ])
      ])
    let config = try ConfigSchema.config(from: root)
    #expect(config.docs.budgets.sections == ["architecture": 120])
  }

  @Test(
    "a non-integer section budget is rejected — catches a stray string budget passing type-checking"
  )
  func nonIntegerSectionBudgetRejected() {
    let root = minimalRoot(
      merging: [
        "docs": .table([
          "budgets": .table(["sections": .table(["Problem": .string("a lot")])])
        ])
      ])
    #expect {
      _ = try ConfigSchema.config(from: root)
    } throws: { error in
      (error as? ConfigValidationError)?.issues == [
        .wrongType(path: "docs.budgets.sections.Problem", expected: "integer", found: "string")
      ]
    }
  }

  @Test("plan est_lines_max below est_lines_min is rejected — catches an inverted sizing bound")
  func estLinesMaxBelowMinRejected() {
    #expect {
      _ = try Config(
        xcode: "26.2", appScheme: "App", packages: ["Packages/*"],
        simulator: SimulatorConfig(device: "iPhone 17", os: "26.2"),
        plan: PlanConfig(estLinesMin: 100, estLinesMax: 50))
    } throws: { error in
      (error as? ConfigValidationError)?.issues == [
        .outOfRange(path: "plan.est_lines_max", value: "50", allowed: ">= plan.est_lines_min")
      ]
    }
  }

  @Test(
    "a managed file path outside the repository is rejected — catches an absolute or traversal path"
  )
  func managedFilePathOutsideRepoRejected() {
    #expect {
      _ = try Config(
        xcode: "26.2", appScheme: "App", packages: ["Packages/*"],
        simulator: SimulatorConfig(device: "iPhone 17", os: "26.2"),
        docs: DocsConfig(managedFiles: ["../outside.md"]))
    } throws: { error in
      (error as? ConfigValidationError)?.issues == [
        .outOfRange(
          path: "docs.managed_files[0]", value: "../outside.md",
          allowed: "a repository-relative path")
      ]
    }
  }
}
