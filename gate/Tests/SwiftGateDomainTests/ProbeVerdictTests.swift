import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@Suite("Probe verdicts")
struct ProbeVerdictTests {
  private static let good = "ev-good-effect-cancel"
  private static let warns = "ev-warns-but-compiles"
  private static let fabricated = "ev-fabricated-symbol"
  private static let wrongSignature = "ev-wrong-signature"
  private static let allClaims = [good, warns, fabricated, wrongSignature]

  @Test(
    "ev- ids sanitise to legal, unique identifiers — catches a hyphen reaching a Swift enum name")
  func idsSanitiseToLegalUniqueIdentifiers() {
    let ids = [
      "ev-tca-effect-run-supports-cancellation", "ev-good-effect-cancel", "ev-fabricated-symbol",
    ]
    let names = ids.map(ProbeIdentifier.enumName(forClaimID:))
    for name in names {
      #expect(name.hasPrefix("Probe_"))
      #expect(!name.contains("-"))
      #expect(name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" })
    }
    #expect(Set(names).count == names.count)
    #expect(
      ProbeIdentifier.fileName(forClaimID: "ev-good-effect-cancel")
        == "Probe_ev_good_effect_cancel.swift")
  }

  @Test("parse reads only the primary diagnostic line — catches a caret continuation counted twice")
  func parseIgnoresContextLines() throws {
    let diagnostics = CompilerDiagnostics.parse(try Fixture.text("Probe/good.stdout"))
    #expect(diagnostics.count == 1)
    let diagnostic = try #require(diagnostics.first)
    #expect(diagnostic.file.hasSuffix("Probe_ev_warns_but_compiles.swift"))
    #expect(diagnostic.line == 3)
    #expect(diagnostic.column == 9)
    #expect(diagnostic.level == .warning)
    #expect(diagnostic.message.contains("'unused' was never used"))
  }

  @Test("a warning-only probe passes — catches a warning mistaken for a failure")
  func warningsDoNotFail() throws {
    let diagnostics = CompilerDiagnostics.parse(try Fixture.text("Probe/good.stdout"))
    let attribution = ProbeAttribution.attribute(diagnostics, probes: [Self.good, Self.warns])
    #expect(attribution.verdict == .green)
    #expect(attribution.verdicts.first { $0.claimID == Self.warns }?.verdict == .green)
    #expect(attribution.verdicts.first { $0.claimID == Self.good }?.diagnostics.isEmpty == true)
  }

  @Test(
    "a fabricated API fails only its own probe — catches one probe failing its siblings")
  func fabricatedAPIFailsOnlyItsOwnProbe() throws {
    let diagnostics = CompilerDiagnostics.parse(try Fixture.text("Probe/mixed.stdout"))
    let attribution = ProbeAttribution.attribute(diagnostics, probes: Self.allClaims)
    let byClaim = Dictionary(uniqueKeysWithValues: attribution.verdicts.map { ($0.claimID, $0) })
    #expect(byClaim[Self.fabricated]?.verdict == .red)
    #expect(byClaim[Self.fabricated]?.diagnostics.count == 1)
    #expect(
      byClaim[Self.fabricated]?.diagnostics.first?.message.contains("fabricatedAPIThatDoesNotExist")
        == true)
    #expect(byClaim[Self.good]?.verdict == .green)
    #expect(byClaim[Self.good]?.diagnostics.isEmpty == true)
    #expect(byClaim[Self.warns]?.verdict == .green)
  }

  @Test("a wrong signature fails — catches a real API called with the wrong shape passing")
  func wrongSignatureFails() throws {
    let diagnostics = CompilerDiagnostics.parse(try Fixture.text("Probe/mixed.stdout"))
    let attribution = ProbeAttribution.attribute(diagnostics, probes: Self.allClaims)
    let verdict = attribution.verdicts.first { $0.claimID == Self.wrongSignature }
    #expect(verdict?.verdict == .red)
    #expect(
      verdict?.diagnostics.first?.message.contains("cannot convert value of type 'Int'") == true)
    #expect(attribution.verdict == .red)
  }

  @Test(
    "an unattributed error blocks even when every probed claim is green — catches a mismatched probe file silently passing"
  )
  func unattributedErrorNeverPassesSilently() throws {
    let diagnostics = CompilerDiagnostics.parse(try Fixture.text("Probe/unattributed.stdout"))
    // Only the two clean probes are under test here: every error in this build belongs to a file
    // (Extra.swift, the fabricated probe, the wrong-signature probe) outside that set.
    let attribution = ProbeAttribution.attribute(diagnostics, probes: [Self.good, Self.warns])
    #expect(attribution.verdicts.allSatisfy { $0.verdict == .green })
    #expect(!attribution.unattributed.isEmpty)
    #expect(attribution.verdict == .blocked)
    #expect(attribution.verdict != .green)
  }

  @Test(
    "an unattributed error never hides a real probe failure — catches blocked masking red")
  func unattributedErrorDoesNotMaskARealFailure() throws {
    let diagnostics = CompilerDiagnostics.parse(try Fixture.text("Probe/unattributed.stdout"))
    // Only the fabricated and wrong-signature probes are under test: `Extra.swift`'s six repeated
    // errors and the `warns` probe's warning all match neither, so they are unattributed
    // alongside the two real, correctly attributed failures.
    let attribution = ProbeAttribution.attribute(
      diagnostics, probes: [Self.fabricated, Self.wrongSignature])
    #expect(attribution.verdicts.allSatisfy { $0.verdict == .red })
    #expect(attribution.unattributed.count == 7)
    #expect(attribution.verdict == .red)
  }
}
