import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// pos-checkout-1's cart-quantities row: 13 steps over a checkout of 8 catalogue tiles, each with
/// an unlabelled inner button, 2 cart rows, and +/−/trash buttons drawn about 20 pt square.
@Suite("sim verify counts each control once and measures pressed tap targets")
struct SimTapTargetTests {
  static let row = "BrownfieldTrial/pos-checkout-1-cart-quantities"

  /// The captured row as `sim verify` loads it, with a stand-in screenshot per step: the PNGs
  /// aren't kept, and no rule reads their bytes beyond emptiness.
  static func evidence() throws -> SimEvidence {
    let steps = try SimStep.decodeLog(try Fixture.data("\(row)/sim/steps.ndjson"))
    var files: [String: SimEvidenceFile] = [:]
    for step in steps {
      files[step.screenshot] = .present(Data("png".utf8))
      if let tree = step.tree { files[tree] = .present(try Fixture.data("\(row)/sim/\(tree)")) }
    }
    return SimEvidence(
      runID: "20261005T123527Z-658b917a-row2",
      session: try SimSession.decode(try Fixture.data("\(row)/sim/session.json")), steps: steps,
      files: files)
  }

  static func flow() throws -> [FlowStep] {
    try FlowSteps.parse(try Fixture.data("\(row)/flow.json"))
  }

  static func judged() throws -> SimVerifyReport {
    let evidence = try evidence()
    return SimVerifyReport.judged(
      evidence, checkoutHead: .commit(evidence.session.headCommit),
      audit: .scope(profile: .brownfield, flowSteps: try flow()))
  }

  @Test(
    "the flow's press steps name the 5 controls it presses, and no control it only waits for or reads — catches tap targets measured on text the flow never touches"
  )
  func pressedSelectorsAreThePressSteps() throws {
    #expect(
      SimSelector.pressed(in: try Self.flow()).map(\.raw) == [
        #"id="catalogue.item.latte""#, #"id="catalogue.item.muffin""#,
        #"id="cart.line.muffin.increment""#, #"id="cart.line.muffin.decrement""#,
        #"id="cart.line.latte.remove""#,
      ])
  }

  @Test(
    "the trial row's untargeted nit counts its 10 distinct controls, 8 unlabelled tile buttons and 2 anonymous cart rows, where the trial counted 144 findings over 13 steps — catches a nit that counts every snapshot of the same control"
  )
  func untargetedNitCountsEachControlOnce() throws {
    let captured = try #require(
      try JSONSerialization.jsonObject(with: try Fixture.data("\(Self.row)/sim/report.json"))
        as? [String: Any])
    let trialNote = try #require((captured["notes"] as? [[String: Any]])?.first?["message"] as? String)
    #expect(trialNote.hasPrefix("144 findings"), "\(trialNote)")

    let report = try Self.judged()

    let untargeted = report.notes.filter { $0.rule == SimAuditScope.untargetedRuleID }
    #expect(untargeted.count == 1, "\(report.notes)")
    #expect(untargeted.first?.message.hasPrefix("10 controls ") == true, "\(untargeted)")
    #expect(report.verdict == .green, "\(report.findings.map(\.message))")
  }

  @Test(
    "the 3 pressed cart buttons drawn about 20 pt square earn 1 sim.tap-target nit naming each with its size, the 88×58 pt tiles it also presses don't, and the verdict stays GREEN — catches QA passing a + button too small to hit"
  )
  func smallPressedTargetsEarnANit() throws {
    let report = try Self.judged()

    let small = report.notes.filter { $0.rule == SimAuditScope.tapTargetRuleID }
    #expect(small.count == 1, "\(report.notes)")
    let message = try #require(small.first?.message)
    for id in ["cart.line.muffin.increment", "cart.line.muffin.decrement", "cart.line.latte.remove"] {
      #expect(message.contains(id), "\(message)")
    }
    #expect(message.contains("20×19 pt"), "\(message)")
    #expect(message.hasPrefix("3 "), "\(message)")
    #expect(!message.contains("catalogue.item"), "\(message)")
    #expect(report.verdict == .green)
  }
}
