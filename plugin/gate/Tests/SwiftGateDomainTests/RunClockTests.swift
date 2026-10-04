import Foundation
import SwiftGateDomain
import Testing

@Suite struct RunClockTests {
  private static let clock = RunClock(
    started: Date(timeIntervalSince1970: 1_790_000_000.25), spec: "/repo/.git/plan/spec.md",
    origin: "/home/me/spec.md", specSource: .copied, planBranch: "swift-harness/export",
    base: "abc123")

  @Test(
    "clock.json writes the start in UTC ISO 8601 with milliseconds and reads back equal — catches a whole-second time that misorders events in the start's second"
  )
  func roundTrips() throws {
    let data = try Self.clock.encoded()
    let text = String(decoding: data, as: UTF8.self)

    #expect(text.contains(#""started" : "2026-09-21T14:13:20.250Z""#))
    #expect(text.contains(#""spec" : "/repo/.git/plan/spec.md""#), "slashes stay unescaped")
    #expect(text.hasSuffix("}\n"))
    #expect(try RunClock.decode(data) == Self.clock)
  }

  @Test(
    "the start reads only as an ISO 8601 time — catches a clock read as some other date or rejected when a person writes it"
  )
  func readsOnlyAnISOStart() throws {
    let json = """
      {"base": "abc123", "origin": "/home/me/spec.md", "planBranch": "swift-harness/export",
       "spec": "/repo/.git/plan/spec.md", "specSource": "copied", "started": "STARTED"}
      """

    let read = try RunClock.decode(
      Data(json.replacingOccurrences(of: "STARTED", with: "2026-09-21T14:13:20.250Z").utf8))
    #expect(read == Self.clock)
    #expect(throws: DecodingError.self) {
      try RunClock.decode(Data(json.replacingOccurrences(of: "STARTED", with: "yesterday").utf8))
    }
  }

  @Test(
    "the slug keeps the spec stem's letters and digits in lowercase, dash-joined — catches a slug that breaks a branch name"
  )
  func slugNormalisesTheStem() {
    #expect(
      RunSlug.make(specPath: "docs/Export the CSV_v2.md", isTaken: { _ in false })
        == "export-the-csv-v2")
    #expect(RunSlug.make(specPath: "--Café--.spec.md", isTaken: { _ in false }) == "caf-spec")
  }

  @Test(
    "a stem with no letters or digits falls back to `run`, suffixed like any other — catches an empty slug"
  )
  func slugFallsBackToRun() {
    #expect(RunSlug.make(specPath: "notes/___.md", isTaken: { _ in false }) == "run")
    #expect(RunSlug.make(specPath: "", isTaken: { _ in false }) == "run")
    #expect(RunSlug.make(specPath: "notes/___.md", isTaken: { $0 == "run" }) == "run-2")
  }

  @Test(
    "a taken slug gets the first free `-2`, `-3`, … suffix — catches a run reusing another's plan dir"
  )
  func slugSkipsTakenNames() {
    let taken: Set = ["export", "export-2", "export-3"]

    #expect(RunSlug.make(specPath: "export.md", isTaken: { taken.contains($0) }) == "export-4")
    #expect(RunSlug.make(specPath: "export.md", isTaken: { $0 == "export" }) == "export-2")
  }

  @Test(
    "claude's argv carries the settings, the pinned model and the session id, then the prompt before the extra arguments — catches a variadic extra option swallowing the prompt"
  )
  func launchArgumentsOrder() {
    let prompt = RunLaunch.prompt(
      slug: "export", spec: "/repo/spec.md", planBranch: "swift-harness/export")

    #expect(
      prompt
        == "/swift-harness:run This run comes from `swiftgate run`. Plan slug: export. "
        + "Spec: /repo/spec.md. Plan branch: swift-harness/export.")
    #expect(
      RunLaunch.arguments(
        settings: "/repo/.claude/settings.json", session: "0b6f3c2e-8d1a-4f5b-9c7e-2a4d6f8b0c1e",
        prompt: prompt, extra: ["--add-dir", "/a", "/b"])
        == [
          "--settings", "/repo/.claude/settings.json", "--model", "claude-opus-5-5",
          "--session-id", "0b6f3c2e-8d1a-4f5b-9c7e-2a4d6f8b0c1e", prompt, "--add-dir", "/a", "/b",
        ])
  }

  @Test(
    "an extra option that would change the session is named, in either spelling, and one after `--` is not — catches claude starting under a session that doesn't hold the plan's lock"
  )
  func conflictingSessionOptions() {
    #expect(RunLaunch.conflictingOption(in: ["-p", "--session-id", "x"]) == "--session-id")
    #expect(RunLaunch.conflictingOption(in: ["--resume=abc"]) == "--resume")
    #expect(RunLaunch.conflictingOption(in: ["-c"]) == "-c")
    #expect(RunLaunch.conflictingOption(in: ["--fork-session"]) == "--fork-session")
    #expect(RunLaunch.conflictingOption(in: ["-p", "--verbose", "--add-dir", "/a"]) == nil)
    #expect(RunLaunch.conflictingOption(in: ["--", "--resume"]) == nil)
  }
}
