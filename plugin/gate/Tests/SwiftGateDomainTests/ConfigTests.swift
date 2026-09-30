import SwiftGateDomain
import Testing

@Suite("Config")
struct ConfigTests {
  @Test(
    "a judge backend's host check wants exactly its egress host, and no host for a backend that sends nowhere — catches a lookalike or missing host allowing egress"
  )
  func egressIssueWantsTheExactHost() {
    let host = "api.typesafe.ai"
    #expect(
      JudgeBackend.jev.egressIssue(sendTo: nil, path: "p")
        == .judgeHostNotNamed(path: "p", backend: .jev, host: host))
    #expect(
      JudgeBackend.jev.egressIssue(sendTo: "api.typesafe.ai.example.com", path: "p")
        == .judgeHostMismatch(
          path: "p", value: "api.typesafe.ai.example.com", backend: .jev, host: host))
    #expect(JudgeBackend.jev.egressIssue(sendTo: host, path: "p") == nil)
    #expect(
      JudgeBackend.claude.egressIssue(sendTo: host, path: "p")
        == .judgeHostUnused(path: "p", backend: .claude))
    #expect(JudgeBackend.claude.egressIssue(sendTo: nil, path: "p") == nil)
  }

  @Test("building a Config in code enforces the same rules as the file — catches a bypass path")
  func initEnforcesInvariants() {
    #expect {
      _ = try Config(
        xcode: "26.2", appScheme: "App", packages: ["Packages/*"],
        simulator: SimulatorConfig(device: "iPhone 17", os: "26.2"),
        pyramid: PyramidConfig(maxFlows: 0),
        flows: [Flow(name: "checkout", reason: "revenue")],
        modules: [ModuleOverride(name: "Engine", kind: .engine, reason: nil)])
    } throws: { error in
      (error as? ConfigValidationError)?.issues == [
        .tooManyFlows(count: 1, max: 0),
        .missingReason(path: "modules[0].reason", module: "Engine", rule: .nonDefaultKind(.engine)),
      ]
    }
  }

  @Test(
    "a Jev judge built in code with the jev-latest alias fails naming the pin, and a versioned id builds — catches the pin rule living only in the file reader"
  )
  func codeBuiltJevConfigNeedsAPin() throws {
    func config(_ model: String) throws -> Config {
      try Config(
        xcode: "26.2", appScheme: "App", packages: ["Packages/*"],
        simulator: SimulatorConfig(device: "iPhone 17", os: "26.2"),
        judge: .enabled(
          backend: .jev, thresholds: JudgeThresholds(advisory: 0.6, block: 0.9), model: model))
    }
    #expect {
      _ = try config("jev-latest")
    } throws: { error in
      (error as? ConfigValidationError)?.issues == [
        .judgeModelNotPinned(
          path: "judge.model", value: "jev-latest", backend: .jev, pin: "jev-1.13.0")
      ]
    }
    #expect(try config("jev-2.0.10").judge != .disabled)
  }

  @Test(
    "only a Jev id of three numeric parts is pinned, and Claude's aliases stay allowed — catches an alias or a malformed version passing as a pin"
  )
  func jevPinShape() {
    for pinned in ["jev-1.13.0", "jev-10.0.123"] {
      #expect(JudgeBackend.jev.isPinned(pinned), "\(pinned)")
    }
    for alias in [
      "jev-latest", "jev-preview", "jev-1.13", "jev-1.13.0.1", "jev-1..0", "jev-1.13.0-rc1",
      "jev-١.٢.٣", "Jev-1.13.0", "1.13.0",
    ] {
      #expect(!JudgeBackend.jev.isPinned(alias), "\(alias)")
    }
    #expect(JudgeBackend.claude.isPinned("sonnet"))
  }

  @Test("schema reports a non-table document instead of trapping — catches crash on bad input")
  func nonTableDocument() {
    #expect {
      _ = try ConfigSchema.config(from: .string("x"))
    } throws: { error in
      (error as? ConfigValidationError)?.issues == [
        .wrongType(path: "(root)", expected: "table", found: "string")
      ]
    }
  }
}
