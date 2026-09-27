import SwiftGateDomain
import Testing

@Suite("Build presets (design spec §5.1)")
struct BuildPresetConfigTests {
  /// A root table with only the keys `ConfigSchema` requires, so each test adds just the
  /// `[build.presets.<name>]` table it cares about.
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

  /// The `default` preset's spec §5.1 values, as a TOML-shaped table.
  private static let defaultPresetTable: ConfigValue = .table([
    "design_tier": .string("standard"),
    "max_parallel": .integer(3),
    "review": .string("full"),
    "task_gate": .string("ledger"),
    "merge_gate": .string("push"),
    "worker_model": .string("tagged"),
    "time_budget_min": .integer(0),
    "stop_starts_before_min": .integer(0),
    "on_design_conflict": .string("amend"),
  ])

  private static let defaultPreset = BuildPreset(
    designTier: .standard, maxParallel: 3, review: .full, taskGate: .ledger, mergeGate: .push,
    workerModel: .tagged, timeBudgetMin: 0, stopStartsBeforeMin: 0, onDesignConflict: .amend)

  private func root(withDefaultPreset overrides: [String: ConfigValue] = [:]) -> ConfigValue {
    guard case .table(var presetFields) = Self.defaultPresetTable else { fatalError() }
    for (key, value) in overrides { presetFields[key] = value }
    return minimalRoot(
      merging: [
        "build": .table(["presets": .table(["default": .table(presetFields)])])
      ])
  }

  @Test(
    "a full preset table decodes to the closed BuildPreset it names — catches a decoder that drops or coerces a field"
  )
  func fullPresetDecodes() throws {
    let config = try ConfigSchema.config(from: root())
    #expect(config.buildPresets == ["default": Self.defaultPreset])
  }

  @Test(
    "a preset missing one key is a config issue naming the preset and key — catches a silent default"
  )
  func missingKeyNamesPresetAndKey() {
    guard case .table(var presetFields) = Self.defaultPresetTable else { fatalError() }
    presetFields.removeValue(forKey: "review")
    let input = minimalRoot(
      merging: [
        "build": .table(["presets": .table(["default": .table(presetFields)])])
      ])
    #expect {
      _ = try ConfigSchema.config(from: input)
    } throws: { error in
      (error as? ConfigValidationError)?.issues == [
        .missingKey(path: "build.presets.default.review")
      ]
    }
  }

  @Test(
    "an unknown review value is a config issue — catches an unrecognized value passing silently")
  func unknownReviewValueIsAnIssue() {
    let input = root(withDefaultPreset: ["review": .string("partial")])
    #expect {
      _ = try ConfigSchema.config(from: input)
    } throws: { error in
      (error as? ConfigValidationError)?.issues == [
        .unknownEnumValue(
          path: "build.presets.default.review", value: "partial", allowed: ["full", "gate"])
      ]
    }
  }

  @Test(
    "stop_starts_before_min above time_budget_min is a config issue — catches a stop point beyond the budget it belongs to"
  )
  func stopStartsBeforeMinAboveBudgetIsAnIssue() {
    let input = root(
      withDefaultPreset: ["time_budget_min": .integer(38), "stop_starts_before_min": .integer(50)])
    #expect {
      _ = try ConfigSchema.config(from: input)
    } throws: { error in
      (error as? ConfigValidationError)?.issues == [
        .outOfRange(
          path: "build.presets.default.stop_starts_before_min", value: "50",
          allowed: "<= build.presets.default.time_budget_min")
      ]
    }
  }

  @Test(
    "max_parallel below 1, a negative time budget and a negative stop point are each an issue — catches a preset that would schedule zero workers or stop before it starts"
  )
  func negativeIntegersAreIssues() {
    let input = root(
      withDefaultPreset: [
        "max_parallel": .integer(0), "time_budget_min": .integer(-5),
        "stop_starts_before_min": .integer(-1),
      ])
    #expect {
      _ = try ConfigSchema.config(from: input)
    } throws: { error in
      (error as? ConfigValidationError)?.issues == [
        .outOfRange(path: "build.presets.default.max_parallel", value: "0", allowed: ">= 1"),
        .outOfRange(path: "build.presets.default.time_budget_min", value: "-5", allowed: ">= 0"),
        .outOfRange(
          path: "build.presets.default.stop_starts_before_min", value: "-1", allowed: ">= 0"),
      ]
    }
  }

  @Test(
    "[build] with no [build.presets] table is a missing-key issue — catches a build section that declares no preset"
  )
  func buildWithoutPresetsIsMissingKey() {
    let input = minimalRoot(merging: ["build": .table([:])])
    #expect {
      _ = try ConfigSchema.config(from: input)
    } throws: { error in
      (error as? ConfigValidationError)?.issues == [.missingKey(path: "build.presets")]
    }
  }

  @Test(
    "a preset entry that isn't a table is a wrong-type issue — catches `[build.presets] default = 1` instead of a table"
  )
  func presetEntryNotATableIsWrongType() {
    let input = minimalRoot(
      merging: ["build": .table(["presets": .table(["default": .integer(1)])])])
    #expect {
      _ = try ConfigSchema.config(from: input)
    } throws: { error in
      (error as? ConfigValidationError)?.issues == [
        .wrongType(path: "build.presets.default", expected: "table", found: "integer")
      ]
    }
  }
}
