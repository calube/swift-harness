import Foundation
import SwiftGateAdapters
import SwiftGateDomain

/// Reads the machine's Xcode through the same seam `doctor` and `snapshots record` use
/// (`Xcodebuild.version()`), then judges it with ``XcodePinGate``. `test`'s t1/t2/t3 and `check`'s
/// T1 and simulator tiers all call this before they build or run anything.
enum XcodePinCheck {
  static func message(pin: String, xcodebuild: any Xcodebuild) async -> String? {
    let installed = (try? await xcodebuild.version()).flatMap(Doctor.xcodeVersion)
    return XcodePinGate.message(installed: installed, pin: pin)
  }

  static func finding(_ message: String) throws(ReportContractViolation) -> Finding {
    try Finding(
      ruleID: Doctor.xcodePinRuleID, severity: .minor, file: Config.fileName, line: nil,
      message: message, failureScenario: nil)
  }

  static func blockedTier(_ tier: Tier) throws(ReportContractViolation) -> TierResult {
    try TierResult(tier: tier, verdict: .blocked, durationMilliseconds: 0, testCounts: nil)
  }

  /// The parts a tier reports when it stops here, or `nil` when it may proceed.
  static func blockedParts(tier: Tier, pin: String, xcodebuild: any Xcodebuild)
    async
    throws(ReportContractViolation) -> GateRunParts?
  {
    guard let text = await message(pin: pin, xcodebuild: xcodebuild) else { return nil }
    return GateRunParts(tiers: [try blockedTier(tier)], findings: [try finding(text)])
  }
}
