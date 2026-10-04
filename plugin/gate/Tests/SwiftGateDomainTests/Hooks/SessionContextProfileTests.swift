import Foundation
import SwiftGateDomain
import Testing

/// The opening of the SessionStart context names the config and tiers of the profile the
/// project actually runs.
@Suite("Session context profile")
struct SessionContextProfileTests {
  static let config = "/clones/memos/.git/swift-harness/config.toml"

  func render(_ profile: SessionContext.Profile) -> String {
    SessionContext.render(
      SessionContext.Inputs(
        projectName: "memos", profile: profile, sessionID: "s-1", modules: [], xcode: nil,
        plans: .none, notes: []))
  }

  @Test(
    "a brownfield session's context names the common-dir config and the slice, merge and final tiers, never .swiftgate.toml or the fast tier, while an owned project's keeps both — catches owned-profile text telling a brownfield orchestrator about a config and a Stop tier it doesn't have"
  )
  func brownfieldText() {
    let text = render(.brownfield(config: Self.config))

    #expect(text.contains(Self.config))
    for tier in ["`slice`", "`merge`", "`final`"] {
      #expect(text.contains(tier), "\(tier)")
    }
    #expect(text.contains("Stop hook runs `swiftgate check --tier slice`"))
    #expect(!text.contains(".swiftgate.toml"))
    #expect(!text.contains("--tier fast"))
    #expect(text.contains("Session id: s-1"))

    let owned = render(.owned)
    #expect(owned.contains("swift-harness is active in memos (.swiftgate.toml)"))
    #expect(owned.contains("the Stop hook runs `swiftgate check --tier fast`"))
    #expect(!owned.contains("config.toml"))
  }
}
