import SwiftGateDomain
import Testing

@Suite("ResearchLanePin and ContextPackKey")
struct ResearchLanePinTests {
  @Test(
    "a short or full hex sha is a commit — catches a short sha read as an SDK pin",
    arguments: [
      "6ee3210", "6ee32101d306", "6EE32101D306B2FC", String(repeating: "a", count: 40),
      String(repeating: "b", count: 64),
    ])
  func hexIsCommit(raw: String) throws {
    let pin = try ResearchLanePin(parsing: raw)
    #expect(pin == .commit(raw))
    #expect(pin.claimPin == raw)
  }

  @Test("<pkg>@<version> is a package pin, and its claim pin is itself")
  func packagePin() throws {
    let pin = try ResearchLanePin(parsing: "swift-composable-architecture@1.26.2")
    #expect(pin == .package(identity: "swift-composable-architecture", version: "1.26.2"))
    #expect(pin.claimPin == "swift-composable-architecture@1.26.2")
  }

  @Test(
    "an SDK pin names its platform, and its claim pin is the bare version evidence check compares — catches a claim pinned to a string xcrun never prints"
  )
  func sdkPin() throws {
    let simulator = try ResearchLanePin(parsing: "iphonesimulator26.2")
    #expect(simulator == .sdk(platform: .iphonesimulator, version: "26.2"))
    #expect(simulator.claimPin == "26.2")
    #expect(
      try ResearchLanePin(parsing: "iphoneos26.0.1") == .sdk(platform: .iphoneos, version: "26.0.1")
    )
  }

  @Test(
    "anything outside the closed shapes fails and names itself — catches a catch-all SDK case",
    arguments: [
      "", "26.2", "abc", "6ee321", "6ee3210g", String(repeating: "a", count: 41), "macosx26.2",
      "iphonesimulator", "iphonesimulator26.", "@1.0", "pkg@", "pkg@1.0/x", "a/b@1.0", "pkg@1 .0",
      "../x@1.0",
    ])
  func unknownShapesFail(raw: String) {
    #expect(throws: ResearchLanePinError.unrecognized(raw)) { try ResearchLanePin(parsing: raw) }
  }

  @Test("each lane accepts only its own pin kind — catches a codebase lane pinned to a package")
  func laneExpectsItsKind() throws {
    #expect(ResearchLanePin.Kind.expected(for: .codebase) == .commit)
    #expect(ResearchLanePin.Kind.expected(for: .packages) == .package)
    #expect(ResearchLanePin.Kind.expected(for: .priorDecisions) == .package)
    #expect(ResearchLanePin.Kind.expected(for: .appleDocs) == .sdk)
    #expect(try ResearchLanePin(parsing: "6ee3210").kind == .commit)
    #expect(try ResearchLanePin(parsing: "a@1").kind == .package)
    #expect(try ResearchLanePin(parsing: "iphoneos26.2").kind == .sdk)
  }

  @Test(
    "a context-pack key is one safe path component — catches a key that writes outside the pack directory",
    arguments: ["/../x", "../x", "..", ".", ".hidden", "a/b", "", "a\0b", "a b", "a\nb", "-x"])
  func unsafeKeysFail(raw: String) {
    #expect(throws: ContextPackKeyError.unsafe(raw)) { try ContextPackKey(parsing: raw) }
  }

  @Test("an ordinary key is kept as written", arguments: ["codebase", "apple-docs", "task_1.2"])
  func safeKeysPass(raw: String) throws {
    #expect(try ContextPackKey(parsing: raw).value == raw)
  }
}
