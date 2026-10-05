import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// A Bash call of the third send-money trial's orchestrator that named a machine-wide temp path.
struct OrchestratorCall: Decodable {
  let command: String
}

@Suite("Bash guard on swiftgate output outside the run")
struct GateOutputGuardTests {
  static let out = "/CLONE/.git/swift-harness/plans/<plan>/out/"

  static func calls() throws -> [OrchestratorCall] {
    try JSONDecoder().decode(
      [OrchestratorCall].self, from: Fixture.data("Hooks/send-money-3-gate-output-bash.json"))
  }

  @Test(
    "of the trial orchestrator's 4 swiftgate calls naming /tmp, only the slice gate sending its JSON to /tmp/sv.json names a swiftgate output file there, and that file is denied naming the plan's out folder — catches a gate's JSON written where another run can overwrite it"
  )
  func capturedRedirectDenied() throws {
    let calls = try Self.calls()
    try #require(calls.count == 4)
    let targets = calls.map { GateOutputGuard.outputTargets(in: $0.command) }
    #expect(targets.map { $0.filter { !$0.hasPrefix("/dev/") } } == [[], ["/tmp/sv.json"], [], []])

    let violation = try #require(
      GateOutputGuard.evaluate(
        targets: ["/private/tmp/sv.json", "/dev/null"], allowedRoots: ["/CLONE", "/WORKTREE"],
        outFolder: Self.out))
    #expect(violation.ruleID == GateOutputGuard.ruleID)
    #expect(violation.reason.contains("`/private/tmp/sv.json`"), "\(violation.reason)")
    #expect(violation.reason.contains(Self.out), "\(violation.reason)")
  }

  @Test(
    "a swiftgate output file inside a checkout or the state root, or a device file, passes — catches the guard refusing the run's own out folder or /dev/null"
  )
  func insideTheRunPasses() {
    let roots = ["/CLONE", "/CLONE-spec-send-views"]
    for targets in [
      ["/CLONE/.git/swift-harness/plans/spec/out/slice.json"],
      ["/CLONE-spec-send-views/.harness/tmp/gate.json"],
      ["/dev/null", "/dev/stderr"],
      [],
    ] {
      #expect(
        GateOutputGuard.evaluate(targets: targets, allowedRoots: roots, outFolder: Self.out)
          == nil, "\(targets)")
    }
    #expect(
      GateOutputGuard.evaluate(
        targets: ["/CLONEX/out.json"], allowedRoots: roots, outFolder: Self.out) != nil)
  }

  @Test(
    "swiftgate's output file is found behind >, >>, &>, 2>, a tee it pipes into, an absolute path, and a variable the line set to the binary, and no other command's is — catches a spelling of the trial's redirect the guard misses, or a guard on every redirect",
    arguments: [
      ("swiftgate check --tier slice --json > /tmp/a.json", ["/tmp/a.json"]),
      ("/h/plugin/bin/swiftgate check >> /tmp/a.json", ["/tmp/a.json"]),
      ("swiftgate qa run --json &> /tmp/a.json", ["/tmp/a.json"]),
      ("swiftgate check 2> /tmp/err.txt", ["/tmp/err.txt"]),
      ("swiftgate check --json | tee /tmp/a.json | tail -3", ["/tmp/a.json"]),
      ("SG=/h/plugin/bin/swiftgate; \"$SG\" check --json > /tmp/a.json", ["/tmp/a.json"]),
      ("SG=\"${CLAUDE_PLUGIN_ROOT}/bin/swiftgate\" && ${SG} check > out/a.json", ["out/a.json"]),
      ("echo hi > /tmp/a.txt", []),
      ("X=/bin/echo; \"$X\" hi > /tmp/a.txt", []),
      ("swiftgate check --json 2>&1 | python3 -c 'print(1)' > /tmp/a.txt", []),
      ("cat /tmp/a.json | swiftgate hook pre-tool-use", []),
    ])
  func spellings(_ command: String, _ expected: [String]) {
    #expect(GateOutputGuard.outputTargets(in: command) == expected, "\(command)")
  }
}
