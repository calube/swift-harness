import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import Testing

/// `SwiftGateDomainTests` has no `TOML` dependency (`SwiftGateDomain` stays pure, per gate
/// layering), so the one check that needs the shipped template's actual TOML bytes — not a
/// hand-built `ConfigValue` tree — lives here instead, against the real decoder.
@Suite("Stamped build presets (design spec §5.1, §10)")
struct BuildPresetTemplateTests {
  /// `plugin/templates/swiftgate.toml`, found relative to this test file so it always reads the
  /// file that ships, never a copy.
  private static let templatePath = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()
    .appending(path: "templates/swiftgate.toml", directoryHint: .notDirectory)

  private static let defaultPreset = BuildPreset(
    designTier: .standard, maxParallel: 3, review: .full, taskGate: .ledger, mergeGate: .push,
    workerModel: .tagged, timeBudgetMin: 0, stopStartsBeforeMin: 0, onDesignConflict: .amend,
    taskProof: .perTask, simQA: .changed)

  private static let timedPreset = BuildPreset(
    designTier: .sketch, maxParallel: 3, review: .gate, taskGate: .tier(.fast), mergeGate: .push,
    workerModel: .tagged, timeBudgetMin: 38, stopStartsBeforeMin: 8, onDesignConflict: .block,
    taskProof: .final, simQA: .changed)

  @Test(
    "the stamped default and timed presets parse to exactly the §5.1/§10 values, per-task and final proof and sim_qa changed included — catches a template that no longer loads or drifts from the spec"
  )
  func stampedPresetsMatchSpec() throws {
    let templateText = try String(contentsOf: Self.templatePath, encoding: .utf8)
    // Every other template placeholder ({{XCODE}}, {{PACKAGES}}, …) renders as the bootstrap
    // placeholder when nothing was inferred; that's still valid TOML, so this exercises the real
    // rendering and decoding path without needing a real repository survey.
    let rendered = ConfigInference.infer(
      RepositorySurvey(packageDirectories: [], schemes: nil, xcodeVersion: nil, devices: [])
    ).render(template: templateText)
    let config = try TOMLConfigDecoder().decode(rendered)
    #expect(
      config.buildPresets == [
        "default": Self.defaultPreset, "timed": Self.timedPreset,
      ])
  }
}
