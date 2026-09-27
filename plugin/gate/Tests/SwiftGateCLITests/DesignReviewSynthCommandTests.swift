import ArgumentParser
import Foundation
import Testing

@testable import SwiftGateCLI

@Suite("swiftgate review-synth --design: exit codes and design-review.json")
struct DesignReviewSynthCommandTests {
  static let doc = """
    # Cache the menu

    ## Decision

    - Cache the menu per brand.

    ## Risks

    - A stale menu after an edit.
    """

  /// A scratch directory holding the design doc and reviewer files; `run/` is the run directory.
  struct Scratch {
    let root: URL
    var run: URL { root.appending(path: "run", directoryHint: .isDirectory) }
    var report: URL { run.appending(path: DesignReviewSynthRun.reportFile) }
    var doc: String { root.appending(path: "design.md").path }

    init() throws {
      root = FileManager.default.temporaryDirectory.appending(
        path: "swiftgate-design-synth-\(UUID().uuidString)", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      try Data(DesignReviewSynthCommandTests.doc.utf8).write(
        to: root.appending(path: "design.md"))
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    /// Writes one reviewer file; `finding` is `(severity, anchor)` or none.
    func reviewer(
      _ name: String, file: String? = nil, finding: (String, String)? = nil
    ) throws -> String {
      let findings = finding.map { severity, anchor in
        """
        [{"severity": "\(severity)", "category": "blind-spot", "location": {"anchor": "\(anchor)"},
          "title": "t", "failure_scenario": "a stale menu is served for a day",
          "evidence": "e", "fix": "f", "verified": true}]
        """
      }
      let url = root.appending(path: file ?? "\(name).json")
      try Data(
        """
        {"schemaVersion": 1, "reviewer": "\(name)", "status": "reviewed",
         "findings": \(findings ?? "[]")}
        """.utf8
      ).write(to: url)
      return url.path
    }

    func exitCode(_ arguments: [String]) -> Int32 {
      do {
        var command = try SwiftGate.parseAsRoot(
          ["review-synth", "--run-directory", run.path] + arguments)
        try command.run()
        return 0
      } catch {
        return SwiftGate.exitCode(for: error).rawValue
      }
    }
  }

  @Test(
    "every verdict exits 0 and writes design-review.json with that verdict — catches a revise or rethink being read as a tool failure",
    arguments: [
      ("ready", nil), ("revise", ("major", "risks")), ("rethink", ("blocker", "decision")),
    ] as [(String, (String, String)?)])
  func verdictsExitZero(expected: String, finding: (String, String)?) throws {
    let scratch = try Scratch()
    defer { scratch.remove() }
    let files = [
      try scratch.reviewer("evidence-auditor"),
      try scratch.reviewer("standards-reviewer", finding: finding),
      try scratch.reviewer("challenger"),
    ]

    #expect(scratch.exitCode(["--design", scratch.doc, "--tier", "standard"] + files) == 0)

    let report = try JSONDecoder().decode(
      DesignReviewReportProbe.self, from: Data(contentsOf: scratch.report))
    #expect(report.verdict == expected)
  }

  @Test(
    "sketch with no reviewer files is ready, the same as quick — catches sketch demanding an agent it never runs"
  )
  func sketchRunsNoReviewers() throws {
    let scratch = try Scratch()
    defer { scratch.remove() }

    #expect(scratch.exitCode(["--design", scratch.doc, "--tier", "sketch"]) == 0)

    let report = try JSONDecoder().decode(
      DesignReviewReportProbe.self, from: Data(contentsOf: scratch.report))
    #expect(report.verdict == "ready")
  }

  enum Failure: String, CaseIterable {
    case badTier, missingTier, missingDesign, unknownReviewer, duplicateReviewer, absentAnchor
    case unreadableReviewerFile, unreadableDesign
  }

  @Test(
    "a contract violation exits 2 and writes no design-review.json — catches a malformed review producing a verdict file",
    arguments: Failure.allCases)
  func violationsExitTwo(failure: Failure) throws {
    let scratch = try Scratch()
    defer { scratch.remove() }
    let clean = try scratch.reviewer("challenger")
    let arguments: [String]
    switch failure {
    case .badTier:
      arguments = ["--design", scratch.doc, "--tier", "Standard", clean]
    case .missingTier:
      arguments = ["--design", scratch.doc, clean]
    case .missingDesign:
      arguments = ["--tier", "quick", clean]
    case .unknownReviewer:
      arguments = [
        "--design", scratch.doc, "--tier", "quick", try scratch.reviewer("architecture"),
      ]
    case .duplicateReviewer:
      let second = try scratch.reviewer("challenger", file: "challenger-2.json")
      arguments = ["--design", scratch.doc, "--tier", "quick", clean, second]
    case .absentAnchor:
      let located = try scratch.reviewer(
        "challenger", file: "cased.json", finding: ("nit", "Decision"))
      arguments = ["--design", scratch.doc, "--tier", "quick", located]
    case .unreadableReviewerFile:
      arguments = [
        "--design", scratch.doc, "--tier", "quick", scratch.root.appending(path: "gone.json").path,
      ]
    case .unreadableDesign:
      arguments = ["--design", scratch.root.appending(path: "gone.md").path, "--tier", "quick"]
    }

    #expect(scratch.exitCode(arguments) == 2)
    #expect(!FileManager.default.fileExists(atPath: scratch.report.path))
  }

  @Test(
    "without --design a missing findings argument is still a usage error — catches quick tier's empty input loosening code review"
  )
  func codeReviewStillNeedsFiles() throws {
    let scratch = try Scratch()
    defer { scratch.remove() }
    #expect(scratch.exitCode([]) == ExitCode.validationFailure.rawValue)
  }

  /// Reads only the verdict, so this test doesn't restate the report's Codable shape.
  struct DesignReviewReportProbe: Decodable {
    let verdict: String
  }
}
