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
    "a start that isn't an ISO 8601 time fails to decode — catches a clock read as some other date")
  func rejectsANonISOStart() throws {
    let text = String(decoding: try Self.clock.encoded(), as: UTF8.self)
      .replacingOccurrences(of: "2026-09-21T14:13:20.250Z", with: "yesterday")

    #expect(throws: DecodingError.self) { try RunClock.decode(Data(text.utf8)) }
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

  @Test("a stem with no letters or digits falls back to `run` — catches an empty slug")
  func slugFallsBackToRun() {
    #expect(RunSlug.make(specPath: "notes/___.md", isTaken: { _ in false }) == "run")
    #expect(RunSlug.make(specPath: "", isTaken: { _ in false }) == "run")
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
    "claude's argv carries the settings, the pinned model, then the prompt before the extra arguments — catches a variadic extra option swallowing the prompt"
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
        settings: "/repo/.claude/settings.json", prompt: prompt,
        extra: ["--add-dir", "/a", "/b"])
        == [
          "--settings", "/repo/.claude/settings.json", "--model", "claude-opus-5-5", prompt,
          "--add-dir", "/a", "/b",
        ])
  }
}
