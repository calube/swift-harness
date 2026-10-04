import Foundation
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
    "task_proof": .string("per-task"),
    "sim_qa": .string("changed"),
  ])

  private static let defaultPreset = BuildPreset(
    designTier: .standard, maxParallel: 3, review: .full, taskGate: .ledger, mergeGate: .push,
    workerModel: .tagged, timeBudgetMin: 0, stopStartsBeforeMin: 0, onDesignConflict: .amend,
    taskProof: .perTask, simQA: .changed)

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
    "an unknown merge_gate value is a config issue listing fast|push|ready — catches a value the shared CheckTier doesn't recognize"
  )
  func unknownMergeGateValueIsAnIssue() {
    let input = root(withDefaultPreset: ["merge_gate": .string("slow")])
    #expect {
      _ = try ConfigSchema.config(from: input)
    } throws: { error in
      (error as? ConfigValidationError)?.issues == [
        .unknownEnumValue(
          path: "build.presets.default.merge_gate", value: "slow",
          allowed: ["fast", "push", "ready"])
      ]
    }
  }

  @Test(
    "an unknown task_gate value is a config issue listing ledger|fast|push|ready — catches a value that is neither ledger nor a CheckTier"
  )
  func unknownTaskGateValueIsAnIssue() {
    let input = root(withDefaultPreset: ["task_gate": .string("slow")])
    #expect {
      _ = try ConfigSchema.config(from: input)
    } throws: { error in
      (error as? ConfigValidationError)?.issues == [
        .unknownEnumValue(
          path: "build.presets.default.task_gate", value: "slow",
          allowed: ["ledger", "fast", "push", "ready"])
      ]
    }
  }

  @Test(
    "task_gate accepts every CheckTier value, not only ledger — catches task_gate silently limited to ledger"
  )
  func taskGateAcceptsEveryCheckTier() throws {
    let input = root(withDefaultPreset: ["task_gate": .string("ready")])
    let config = try ConfigSchema.config(from: input)
    #expect(config.buildPresets["default"]?.taskGate == .tier(.ready))
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
  @Test(
    "a preset without sim_qa is a config issue naming build.presets.<name>.sim_qa — catches a preset that silently skips or runs simulator QA"
  )
  func missingSimQANamesTheKey() {
    guard case .table(var presetFields) = Self.defaultPresetTable else { fatalError() }
    presetFields.removeValue(forKey: "sim_qa")
    let input = minimalRoot(
      merging: [
        "build": .table(["presets": .table(["default": .table(presetFields)])])
      ])
    #expect {
      _ = try ConfigSchema.config(from: input)
    } throws: { error in
      (error as? ConfigValidationError)?.issues == [
        .missingKey(path: "build.presets.default.sim_qa")
      ]
    }
  }

  @Test(
    "sim_qa = \"sometimes\" is a config issue listing changed|off — catches an unrecognized QA mode passing silently"
  )
  func unknownSimQAValueIsAnIssue() {
    let input = root(withDefaultPreset: ["sim_qa": .string("sometimes")])
    #expect {
      _ = try ConfigSchema.config(from: input)
    } throws: { error in
      (error as? ConfigValidationError)?.issues == [
        .unknownEnumValue(
          path: "build.presets.default.sim_qa", value: "sometimes", allowed: ["changed", "off"])
      ]
    }
  }

  @Test("sim_qa off decodes to off — catches the key read but ignored")
  func simQAOffDecodes() throws {
    let config = try ConfigSchema.config(from: root(withDefaultPreset: ["sim_qa": .string("off")]))
    #expect(config.buildPresets["default"]?.simQA == .off)
  }

  @Test(
    "a preset missing task_proof is a config issue naming the key — catches a preset that silently picks a proof mode"
  )
  func missingTaskProofNamesTheKey() {
    guard case .table(var presetFields) = Self.defaultPresetTable else { fatalError() }
    presetFields.removeValue(forKey: "task_proof")
    let input = minimalRoot(
      merging: [
        "build": .table(["presets": .table(["default": .table(presetFields)])])
      ])
    #expect {
      _ = try ConfigSchema.config(from: input)
    } throws: { error in
      (error as? ConfigValidationError)?.issues == [
        .missingKey(path: "build.presets.default.task_proof")
      ]
    }
  }

  @Test(
    "an unknown task_proof value is a config issue listing per-task|final — catches an unrecognized proof mode passing silently"
  )
  func unknownTaskProofValueIsAnIssue() {
    let input = root(withDefaultPreset: ["task_proof": .string("never")])
    #expect {
      _ = try ConfigSchema.config(from: input)
    } throws: { error in
      (error as? ConfigValidationError)?.issues == [
        .unknownEnumValue(
          path: "build.presets.default.task_proof", value: "never",
          allowed: ["per-task", "final"])
      ]
    }
  }

  @Test(
    "task_proof final decodes to the final proof mode — catches the key read but ignored"
  )
  func taskProofFinalDecodes() throws {
    let config = try ConfigSchema.config(
      from: root(withDefaultPreset: ["task_proof": .string("final")]))
    #expect(config.buildPresets["default"]?.taskProof == .final)
  }

  @Test(
    "run.json keeps a preset's task proof mode, and a run recorded before the key existed reads as per-task — catches a final run checked as per-task, or older runs failing to load"
  )
  func taskProofRoundTripsThroughRunJSON() throws {
    let final = BuildPreset(
      designTier: .sketch, maxParallel: 3, review: .gate, taskGate: .tier(.fast), mergeGate: .push,
      workerModel: .tagged, timeBudgetMin: 38, stopStartsBeforeMin: 8, onDesignConflict: .block,
      taskProof: .final)
    let decoded = try JSONDecoder().decode(BuildPreset.self, from: JSONEncoder().encode(final))
    #expect(decoded.taskProof == .final)

    let older = Data(
      #"{"designTier":"standard","maxParallel":3,"review":"full","taskGate":"ledger","mergeGate":"push","workerModel":"tagged","timeBudgetMin":0,"stopStartsBeforeMin":0,"onDesignConflict":"amend"}"#
        .utf8)
    #expect(try JSONDecoder().decode(BuildPreset.self, from: older).taskProof == .perTask)

    let unknown = Data(
      #"{"designTier":"standard","maxParallel":3,"review":"full","taskGate":"ledger","mergeGate":"push","workerModel":"tagged","timeBudgetMin":0,"stopStartsBeforeMin":0,"onDesignConflict":"amend","taskProof":"never"}"#
        .utf8)
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(BuildPreset.self, from: unknown)
    }
  }

  @Test(
    "a preset with design_tier none and on_design_conflict block loads as the none design step — catches a config that rejects the design-free value"
  )
  func designTierNoneLoads() throws {
    let config = try ConfigSchema.config(
      from: root(
        withDefaultPreset: [
          "design_tier": .string("none"), "on_design_conflict": .string("block"),
        ]))
    #expect(config.buildPresets["default"]?.designTier == BuildPreset.DesignStep.none)
  }

  @Test(
    "design_tier none with on_design_conflict amend fails naming both keys — catches a design-free build told to amend a design it doesn't have"
  )
  func designTierNoneNeedsBlock() {
    let input = root(
      withDefaultPreset: ["design_tier": .string("none"), "on_design_conflict": .string("amend")])
    #expect {
      _ = try ConfigSchema.config(from: input)
    } throws: { error in
      guard let issues = (error as? ConfigValidationError)?.issues, issues.count == 1 else {
        return false
      }
      let message = issues[0].description
      return issues[0].path == "build.presets.default.on_design_conflict"
        && message.contains("amend")
        && message.contains("build.presets.default.design_tier")
    }
  }

  @Test(
    "an unknown design_tier names itself and lists none with every design tier — catches none missing from the accepted values"
  )
  func unknownDesignTierNamesItself() {
    let input = root(withDefaultPreset: ["design_tier": .string("nothing")])
    #expect {
      _ = try ConfigSchema.config(from: input)
    } throws: { error in
      (error as? ConfigValidationError)?.issues == [
        .unknownEnumValue(
          path: "build.presets.default.design_tier", value: "nothing",
          allowed: ["quick", "standard", "deep", "sketch", "none"])
      ]
    }
  }

  @Test(
    "run.json with design tier none, and one written with a design tier, each decode and re-encode byte for byte — catches none lost in a run record or older runs reading differently"
  )
  func runJSONDesignStepRoundTrips() throws {
    let designFree = BuildRunRecord(
      runID: "20260928T120000Z-0a1b2c3d", plan: "2026-09-28-queue",
      startedAt: Date(timeIntervalSince1970: 1_790_000_000), presetName: "fast",
      preset: BuildPreset(
        designTier: .none, maxParallel: 2, review: .gate, taskGate: .tier(.push),
        mergeGate: .push, workerModel: .opus, timeBudgetMin: 40, stopStartsBeforeMin: 8,
        onDesignConflict: .block, taskProof: .final))
    let encoded = try BuildRunJSON.encode(designFree)
    #expect(String(decoding: encoded, as: UTF8.self).contains(#""designTier" : "none""#))
    let decoded = try BuildRunJSON.decode(encoded)
    #expect(decoded == designFree)
    #expect(try BuildRunJSON.encode(decoded) == encoded)

    let older = Data(Self.olderRunJSON.utf8)
    let olderRecord = try BuildRunJSON.decode(older)
    #expect(olderRecord.preset.designTier == .design(.standard))
    #expect(try BuildRunJSON.encode(olderRecord) == older)
  }

  private static let olderRunJSON = """
    {
      "plan" : "2026-09-26-search",
      "preset" : {
        "designTier" : "standard",
        "maxParallel" : 3,
        "mergeGate" : "push",
        "onDesignConflict" : "amend",
        "review" : "full",
        "stopStartsBeforeMin" : 0,
        "taskGate" : "ledger",
        "taskProof" : "per-task",
        "timeBudgetMin" : 0,
        "workerModel" : "tagged"
      },
      "presetName" : "default",
      "runId" : "20260926T120000Z-0a1b2c3d",
      "schemaVersion" : 1,
      "startedAt" : "2026-09-26T12:00:00Z"
    }

    """
}
