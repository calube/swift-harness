import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@Suite("brownfield design conflict")
struct BrownfieldDesignConflictTests {
  /// The fourth memos trial's `config.toml`, whose first discovery wrote `block`.
  private static func memos4() throws -> BrownfieldConfig {
    let file = Fixture.directory.appending(path: "BrownfieldTrial/memos-4-config.toml")
    return try TOMLConfigDecoder().decodeBrownfield(String(contentsOf: file, encoding: .utf8))
  }

  @Test(
    "a clone's first discovery writes a brownfield preset that answers a design conflict with amend, and it loads back — catches a brownfield write-set conflict recommending stop"
  )
  func firstDiscoveryAmends() throws {
    let trial = try Self.memos4()
    #expect(trial.buildPresets["brownfield"]?.onDesignConflict == .block)
    let proposal = DiscoverProposal(
      head: trial.brownfield.discoveredAt, areas: [], dirty: [])
    let discovered = Discover.config(from: proposal, keeping: nil)
    #expect(discovered.buildPresets["brownfield"]?.onDesignConflict == .amend)
    let reloaded = try TOMLConfigDecoder().decodeBrownfield(BrownfieldConfigTOML.render(discovered))
    #expect(reloaded.buildPresets["brownfield"]?.onDesignConflict == .amend)
    #expect(reloaded.buildPresets["brownfield"]?.designTier == BuildPreset.DesignStep.none)
  }

  @Test(
    "the memos-4 config with its preset set to amend loads, design_tier none and all — catches a brownfield clone refused the only answer that keeps a run going"
  )
  func brownfieldLoadsAmendWithoutDesign() throws {
    let trial = try Self.memos4()
    let text = BrownfieldConfigTOML.render(trial).replacingOccurrences(
      of: "on_design_conflict = \"block\"", with: "on_design_conflict = \"amend\"")
    let amended = try TOMLConfigDecoder().decodeBrownfield(text)
    #expect(amended.buildPresets["brownfield"]?.onDesignConflict == .amend)
    #expect(amended.areas == trial.areas)
  }
}
