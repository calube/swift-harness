import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

/// Focus files are written as the review workflow writes them and `review.json` and
/// `review-telemetry.json` are read back as JSON, so each check runs against any synthesis build.
@Suite("swiftgate review-synth: numbered-diff baseline and run telemetry")
struct ReviewSynthRunTests {
  static let counter = "Packages/CounterFeature/Sources/CounterCore/CounterFeature.swift"

  struct Run {
    let root: URL
    let directory: URL
    let files: [URL]

    func remove() { try? FileManager.default.removeItem(at: root) }

    func json(_ name: String) throws -> [String: Any] {
      let data = try Data(contentsOf: directory.appending(path: name))
      return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// `(file, line)` of each entry in one of review.json's finding lists.
    func located(_ key: String) throws -> [String] {
      let entries = try #require(try json("review.json")[key] as? [[String: Any]])
      return entries.compactMap { entry in
        guard let finding = entry["finding"] as? [String: Any],
          let file = finding["file"] as? String
        else { return nil }
        return "\(file):\(finding["line"] as? Int ?? 0)"
      }
    }
  }

  /// A verified concurrency finding on `file` at `line`; `extra` adds or overrides keys.
  static func finding(
    file: String = counter, line: Int, category: String = "effect-lifetime",
    _ extra: [String: Any] = [:]
  ) -> [String: Any] {
    var object: [String: Any] = [
      "severity": "major", "category": category, "file": file, "line": line,
      "title": "fact effect has no cancellation id",
      "failure_scenario": "tap Fact then Reset: the late response shows a fact after reset",
      "evidence": "CounterFeature.swift `.run` with no `.cancellable(id:)`",
      "fix": "add a cancel id",
      "verified": true,
    ]
    object.merge(extra) { $1 }
    return object
  }

  /// A temp `.harness/runs/<runID>` with one focus file per focus, `findings` in the concurrency
  /// file, and a review-input bundle carrying `patch` rendered as `diff-numbered.txt`.
  static func run(
    _ findings: [[String: Any]], patch: String?,
    runID: String = RunID.make(startedAt: Date(), suffix: 0x15a6_5d14)
  ) throws -> Run {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "swiftgate-synth-run-\(UUID().uuidString)", directoryHint: .isDirectory)
    let directory = root.appending(path: runID, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var files: [URL] = []
    for focus in ReviewFocus.allCases {
      let review: [String: Any] = [
        "schemaVersion": 1, "focus": focus.rawValue, "status": "reviewed",
        "findings": focus == .concurrency ? findings : [],
      ]
      let url = directory.appending(path: "\(focus.rawValue).json")
      try JSONSerialization.data(withJSONObject: review).write(to: url)
      files.append(url)
    }
    if let patch {
      let bundle = directory.appending(path: "review-input", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
      let manifest = ReviewInputManifest(
        runID: runID, base: "main", mergeBase: "abc", gateVerdict: .green,
        changedFiles: [counter], swiftUIUnits: [],
        artifacts: .init(
          check: "check.json", arch: "arch.json", testlint: "testlint.json",
          comments: "comments.json", diff: "diff.patch", numberedDiff: "diff-numbered.txt",
          mutate: "mutate.json"),
        notes: [])
      try JSONEncoder().encode(manifest).write(to: bundle.appending(path: "manifest.json"))
      try Data(NumberedDiff.render(patch).utf8).write(
        to: bundle.appending(path: "diff-numbered.txt"))
    }
    return Run(root: root, directory: directory, files: files)
  }

  static func cleanReset() throws -> String { try Fixture.text("Review/clean-reset.patch") }

  @Test(
    "clean-reset's baseline fact effect with no cancellation id is reported as pre-existing with its severity and leaves the verdict at merge — catches a defect the diff didn't add turning a clean change into fix-then-merge"
  )
  func baselineEffectIsPreExisting() throws {
    let run = try Self.run(
      [Self.finding(line: 49, ["severity_rule": "defect-users-hit"])], patch: Self.cleanReset())
    defer { run.remove() }
    let report = try ReviewSynthRun.run(files: run.files, runDirectory: run.directory)

    #expect(report.verdict == .merge)
    #expect(try run.located("findings").isEmpty)
    #expect(try run.located("preExisting") == ["\(Self.counter):49"])
    let entries = try #require(try run.json("review.json")["preExisting"] as? [[String: Any]])
    #expect((entries.first?["finding"] as? [String: Any])?["severity"] as? String == "blocker")
    let summary = ReviewSummary.render(report, reportPath: "review.json")
    #expect(summary.hasPrefix("review: merge"))
    #expect(summary.contains("PRE-EXISTING (not counted toward the verdict): 1"))
    #expect(summary.contains("\(Self.counter):49"))
  }

  @Test(
    "a finding on a line the diff added counts toward the verdict — catches every finding being filed as pre-existing"
  )
  func addedLineCounts() throws {
    let run = try Self.run([Self.finding(line: 67)], patch: Self.cleanReset())
    defer { run.remove() }
    let report = try ReviewSynthRun.run(files: run.files, runDirectory: run.directory)
    #expect(report.verdict == .fixThenMerge)
    #expect(try run.located("preExisting").isEmpty)
    #expect(try run.located("findings") == ["\(Self.counter):67"])
  }

  @Test(
    "a finding in a file the diff never touches is pre-existing — catches baseline debt elsewhere blocking the change"
  )
  func untouchedFileIsPreExisting() throws {
    let other = "Packages/APIClient/Sources/APIClient/APIClient.swift"
    let run = try Self.run(
      [Self.finding(file: other, line: 3, ["severity": "blocker"])], patch: Self.cleanReset())
    defer { run.remove() }
    let report = try ReviewSynthRun.run(files: run.files, runDirectory: run.directory)
    #expect(report.verdict == .merge)
    #expect(try run.located("preExisting") == ["\(other):3"])
  }

  @Test(
    "an unmatched finding on baseline code doesn't hold the verdict off merge — catches pre-existing debt blocking through the unmatched path"
  )
  func unmatchedPreExistingDoesNotBlock() throws {
    let run = try Self.run(
      [Self.finding(line: 49, ["verified": false, "unmatched": true])], patch: Self.cleanReset())
    defer { run.remove() }
    let report = try ReviewSynthRun.run(files: run.files, runDirectory: run.directory)
    #expect(report.verdict == .merge)
    let unmatched = try #require(try run.json("review.json")["unmatched"] as? [[String: Any]])
    #expect(unmatched.map { $0["preExisting"] as? Bool } == [true])
  }

  @Test(
    "a run with no review-input bundle counts every finding and names the missing manifest — catches a lost bundle silently filing blockers as pre-existing"
  )
  func missingBundleCountsEverything() throws {
    let run = try Self.run([Self.finding(line: 49)], patch: nil)
    defer { run.remove() }
    let report = try ReviewSynthRun.run(files: run.files, runDirectory: run.directory)
    #expect(report.verdict == .fixThenMerge)
    let reason = try #require(try run.json("review.json")["baselineUnavailable"] as? String)
    #expect(reason.contains("review-input/manifest.json"))
    let summary = ReviewSummary.render(report, reportPath: "review.json")
    #expect(summary.contains("pre-existing check unavailable: review-input/manifest.json"))
  }

  @Test(
    "added lines and the lines around a removal count as changed, context lines don't — catches a deleted guard filing its defect as pre-existing"
  )
  func linesAroundRemovalCount() throws {
    let patch = """
      diff --git a/S.swift b/S.swift
      --- a/S.swift
      +++ b/S.swift
      @@ -10,6 +10,6 @@ struct S {
         let a = 1
         let b = 2
      -  guard ok else { return }
         let c = 3
      +  let d = 4
         let e = 5
         let f = 6
      """
    let run = try Self.run(
      [
        Self.finding(file: "S.swift", line: 10, category: "a"),
        Self.finding(file: "S.swift", line: 12, category: "b"),
        Self.finding(file: "S.swift", line: 14, category: "c", ["end_line": 15]),
        Self.finding(file: "S.swift", line: 9, category: "d", ["end_line": 13]),
      ], patch: patch)
    defer { run.remove() }
    _ = try ReviewSynthRun.run(files: run.files, runDirectory: run.directory)
    #expect(try run.located("findings").sorted() == ["S.swift:12", "S.swift:9"])
    #expect(try run.located("preExisting").sorted() == ["S.swift:10", "S.swift:14"])
  }

  @Test(
    "synth writes review-telemetry.json with the wall time since review-input started, says the tokens are unknown without a workflow result, and names the file — catches a review whose cost nobody can find"
  )
  func telemetryWithoutWorkflowResult() throws {
    let started = Date().addingTimeInterval(-120)
    let run = try Self.run(
      [], patch: Self.cleanReset(), runID: RunID.make(startedAt: started, suffix: 7))
    defer { run.remove() }
    let report = try ReviewSynthRun.run(files: run.files, runDirectory: run.directory)

    let telemetry = try run.json("review-telemetry.json")
    let wall = try #require(telemetry["wallSeconds"] as? Int)
    #expect((119...600).contains(wall))
    #expect(telemetry["outputTokens"] == nil)
    let unavailable = try #require(telemetry["unavailable"] as? [String])
    #expect(unavailable.contains { $0.contains("--workflow-result") })
    let path = run.directory.appending(path: "review-telemetry.json").path
    #expect(try run.json("review.json")["telemetry"] as? String == path)
    #expect(ReviewSummary.render(report, reportPath: "review.json").contains("telemetry: \(path)"))
  }

  /// Runs the built `swiftgate review-synth` on `run`'s focus files from `run.root`, as the
  /// review skill does.
  static func synthWithBinary(_ run: Run) async throws -> ProcessOutput {
    let binary = Fixture.gateDirectory.appending(path: ".build/debug/swiftgate").path
    return try await LiveProcessRunner().run(
      ProcessInvocation(
        executable: binary,
        arguments: ["review-synth", "--run-directory", run.directory.path] + run.files.map(\.path),
        environmentOverlay: [
          "LLVM_PROFILE_FILE": run.root.appending(path: "swiftgate-%p.profraw").path
        ],
        workingDirectory: run.root.path, timeout: .seconds(120)))
  }

  @Test(
    "review-synth run as the real binary without --workflow-result writes review.json naming a telemetry file that exists, and when that file can't be written exits 2 and writes no review.json — catches a review.json with no telemetry behind it"
  )
  func binaryAlwaysWritesTelemetryFirst() async throws {
    let run = try Self.run([Self.finding(line: 67)], patch: Self.cleanReset())
    defer { run.remove() }
    let output = try await Self.synthWithBinary(run)
    #expect(output.status == .exited(0), "\(output.stderr.text)")
    let telemetry = try #require(try run.json("review.json")["telemetry"] as? String)
    #expect(telemetry == run.directory.appending(path: "review-telemetry.json").path)
    #expect(FileManager.default.fileExists(atPath: telemetry))

    let blocked = try Self.run([Self.finding(line: 67)], patch: Self.cleanReset())
    defer { blocked.remove() }
    try FileManager.default.createDirectory(
      at: blocked.directory.appending(path: "review-telemetry.json", directoryHint: .isDirectory),
      withIntermediateDirectories: true)
    let failed = try await Self.synthWithBinary(blocked)
    #expect(failed.status == .exited(2))
    #expect(failed.stderr.text.contains("review-telemetry.json"))
    #expect(
      !FileManager.default.fileExists(
        atPath: blocked.directory.appending(path: "review.json").path))
  }

  @Test(
    "review-synth --workflow-result records the output tokens and agent calls the workflow reported, and only those — catches telemetry numbers lost or invented"
  )
  func telemetryFromWorkflowResult() throws {
    let run = try Self.run([], patch: Self.cleanReset())
    defer { run.remove() }
    let workflow = run.directory.appending(path: "review-workflow.json")
    try Data(
      #"""
      {"bundle":"b","reviews":[],"telemetry":{"outputTokens":51234,
       "agents":[{"label":"review:concurrency","returned":true},{"label":"verify:concurrency","returned":false}],
       "unavailable":["per-agent tokens: the workflow script sees no usage per agent call"]}}
      """#.utf8
    ).write(to: workflow)

    let command = try ReviewSynthCommand.parse(
      ["--run-directory", run.directory.path, "--workflow-result", workflow.path]
        + run.files.map(\.path))
    try command.run()

    let telemetry = try run.json("review-telemetry.json")
    #expect(telemetry["outputTokens"] as? Int == 51234)
    let agents = try #require(telemetry["agents"] as? [[String: Any]])
    #expect(agents.map { $0["label"] as? String } == ["review:concurrency", "verify:concurrency"])
    #expect(agents.map { $0["returned"] as? Bool } == [true, false])
    #expect(
      telemetry["unavailable"] as? [String] == [
        "per-agent tokens: the workflow script sees no usage per agent call"
      ])
  }
}
