import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateRules

/// Checker hygiene (spec §10): every rule has seeded fixtures, every `bad` fixture trips its rule,
/// every `good` fixture and the sample app pass. Each failure is one finding; any failure is RED.
enum SelfTest {
  static let ruleID = "swiftgate.self-test"
  static let rulesDirectory = "gate/Fixtures/rules"
  static let archDirectory = "gate/Fixtures/arch"
  static let sampleDirectory = "examples/SampleApp"

  private struct Failure: Sendable {
    let file: String
    let message: String
  }

  private enum Part: Sendable {
    case failures([Failure])
    /// The environment stopped a check (SwiftPM, file system); the self-test proves nothing.
    case blocked(String)
  }

  static func run(harnessRoot: URL) async -> StaticCheckOutcome {
    let parts = await withTaskGroup(of: Part.self) { group in
      group.addTask { ruleFixtures(harnessRoot: harnessRoot) }
      group.addTask { await archFixtures(harnessRoot: harnessRoot) }
      group.addTask { await sampleApp(harnessRoot: harnessRoot) }
      var collected: [Part] = []
      for await part in group { collected.append(part) }
      return collected
    }
    var failures: [Failure] = []
    for part in parts {
      switch part {
      case .blocked(let reason): return .blocked(reason: "self-test: \(reason)")
      case .failures(let found): failures += found
      }
    }
    do {
      let findings = try failures.sorted { ($0.file, $0.message) < ($1.file, $1.message) }.map {
        failure throws(ReportContractViolation) in
        try Finding(
          ruleID: ruleID, severity: .major, file: failure.file, line: nil,
          message: failure.message, failureScenario: nil)
      }
      return .checked(RuleRunResult(findings: findings, allowances: []))
    } catch {
      return .blocked(reason: "self-test: \(error)")
    }
  }

  // MARK: - Single-file rule fixtures

  private static func ruleFixtures(harnessRoot: URL) -> Part {
    let root = harnessRoot.appending(path: rulesDirectory, directoryHint: .isDirectory)
    var failures = hygiene(
      directory: rulesDirectory, present: subdirectories(of: root),
      expected: RuleCatalog.all.map(\.descriptor.id))
    for rule in RuleCatalog.all {
      let id = rule.descriptor.id
      let ruleRoot = root.appending(path: id, directoryHint: .isDirectory)
      guard FileManager.default.fileExists(atPath: ruleRoot.path) else { continue }
      let manifest: RuleFixtureManifest
      do {
        let file = ruleRoot.appending(path: "fixture.json")
        manifest =
          FileManager.default.fileExists(atPath: file.path)
          ? try JSONDecoder().decode(RuleFixtureManifest.self, from: Data(contentsOf: file))
          : RuleFixtureManifest()
      } catch {
        failures.append(
          Failure(file: "\(rulesDirectory)/\(id)/fixture.json", message: "unreadable: \(error)"))
        continue
      }
      for variant in ["bad", "good"] {
        let relative = "\(rulesDirectory)/\(id)/\(variant)"
        let files = swiftFiles(in: ruleRoot.appending(path: variant, directoryHint: .isDirectory))
        guard !files.isEmpty else {
          failures.append(Failure(file: relative, message: "no \(variant) fixtures for \(id)"))
          continue
        }
        let results: [RuleFixtureCheck.FileResult]
        do {
          results = try RuleFixtureCheck.run(rule: rule, manifest: manifest, files: files)
        } catch {
          failures.append(Failure(file: relative, message: "could not check: \(error)"))
          continue
        }
        for result in results {
          let file = "\(relative)/\(result.fileName)"
          if variant == "bad", result.findings.isEmpty {
            failures.append(Failure(file: file, message: "\(id) did not fire"))
          } else if variant == "good", let first = result.findings.first {
            failures.append(
              Failure(
                file: file,
                message:
                  "\(id) fired on a good fixture at line \(first.line ?? 0): \(first.message)"))
          }
        }
      }
    }
    return .failures(failures)
  }

  // MARK: - Package-tree arch fixtures

  private static func archFixtures(harnessRoot: URL) async -> Part {
    let root = harnessRoot.appending(path: archDirectory, directoryHint: .isDirectory)
    let expected = ArchCheck.ruleIDs
    var failures = hygiene(
      directory: archDirectory, present: subdirectories(of: root), expected: expected)
    let trees = expected.flatMap { id in ["bad", "good"].map { (id, $0) } }.filter { id, variant in
      FileManager.default.fileExists(atPath: root.appending(path: "\(id)/\(variant)").path)
    }
    let parts = await withTaskGroup(of: Part.self) { group in
      for (id, variant) in trees {
        group.addTask {
          let tree = root.appending(path: "\(id)/\(variant)", directoryHint: .isDirectory)
          let outcome = await ArchCheck.run(
            root: tree, swiftPM: ScopeResolution.liveSwiftPM(root: tree))
          return judgeArch(
            outcome, ruleID: id, variant: variant, file: "\(archDirectory)/\(id)/\(variant)")
        }
      }
      var collected: [Part] = []
      for await part in group { collected.append(part) }
      return collected
    }
    for part in parts {
      switch part {
      case .blocked: return part
      case .failures(let found): failures += found
      }
    }
    return .failures(failures)
  }

  private static func judgeArch(
    _ outcome: StaticCheckOutcome, ruleID: String, variant: String, file: String
  ) -> Part {
    switch outcome {
    case .blocked(let reason): return .blocked("\(file): \(reason)")
    case .invalid(let reason, _):
      return .failures([Failure(file: file, message: "invalid fixture: \(reason)")])
    case .checked(let result):
      let gating = result.findings.filter(\.severity.failsGate)
      let fired = Set(gating.map(\.ruleID))
      if variant == "bad", fired != [ruleID] {
        return .failures([
          Failure(
            file: file,
            message:
              "expected RED from \(ruleID) only, got [\(fired.sorted().joined(separator: ", "))]")
        ])
      }
      if variant == "good", let first = gating.first {
        return .failures([
          Failure(file: file, message: "expected GREEN, got \(first.ruleID): \(first.message)")
        ])
      }
      return .failures([])
    }
  }

  // MARK: - Sample app

  private static func sampleApp(harnessRoot: URL) async -> Part {
    let root = harnessRoot.appending(path: sampleDirectory, directoryHint: .isDirectory)
    guard
      FileManager.default.fileExists(atPath: root.appending(path: ConfigLoader.fileName).path)
    else {
      return .failures([
        Failure(
          file: sampleDirectory,
          message: "no \(ConfigLoader.fileName); the clean sample must be gated and GREEN")
      ])
    }
    let swiftPM = ScopeResolution.liveSwiftPM(root: root)
    let checks: [(String, StaticCheckOutcome)] = [
      ("lint", await LintCheck.run(root: root, paths: [], swiftPM: swiftPM)),
      ("testlint", await TestlintCheck.run(root: root, paths: [], swiftPM: swiftPM)),
      ("arch", await ArchCheck.run(root: root, swiftPM: swiftPM)),
    ]
    var failures: [Failure] = []
    for (name, outcome) in checks {
      switch outcome {
      case .blocked(let reason): return .blocked("\(sampleDirectory) \(name): \(reason)")
      case .invalid(let reason, let file):
        failures.append(
          Failure(file: "\(sampleDirectory)/\(file)", message: "\(name): invalid: \(reason)"))
      case .checked(let result):
        for finding in result.findings where finding.severity.failsGate {
          failures.append(
            Failure(
              file: "\(sampleDirectory)/\(finding.file)",
              message: "\(name): \(finding.ruleID) at line \(finding.line ?? 0): \(finding.message)"
            ))
        }
      }
    }
    return .failures(failures)
  }

  // MARK: - Helpers

  private static func hygiene(directory: String, present: Set<String>, expected: [String])
    -> [Failure]
  {
    let expectedSet = Set(expected)
    return expectedSet.subtracting(present).sorted().map {
      Failure(file: "\(directory)/\($0)", message: "rule \($0) has no fixture")
    }
      + present.subtracting(expectedSet).sorted().map {
        Failure(file: "\(directory)/\($0)", message: "fixture for unknown rule \($0)")
      }
  }

  private static func subdirectories(of directory: URL) -> Set<String> {
    let entries =
      (try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles))
      ?? []
    return Set(
      entries.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
        .map(\.lastPathComponent))
  }

  private static func swiftFiles(in directory: URL) -> [(name: String, text: String)] {
    let entries =
      (try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil)) ?? []
    return entries.filter { $0.pathExtension == "swift" }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
      .compactMap { url in
        (try? String(contentsOf: url, encoding: .utf8)).map { (url.lastPathComponent, $0) }
      }
  }
}

struct SelfTestCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "self-test",
    abstract: "Prove every rule trips on its seeded violations and passes clean code.")

  static let harnessRootVariable = "SWIFTGATE_HARNESS_ROOT"

  @Option(
    help:
      "The swift-harness checkout to test. Default: $SWIFTGATE_HARNESS_ROOT (set by bin/swiftgate)."
  )
  var harnessRoot: String?

  @Flag(
    help: "Calibrate the judge instead: precision and recall per question on gate/Fixtures/judge.")
  var judge = false

  @Option(
    help: ArgumentHelp(
      "With --judge: answer with a live backend (claude) instead of the stored recording. "
        + "Costs money and sends the calibration set to the backend."))
  var judgeBackend: JudgeBackend?

  @Option(help: "With --judge-backend: the backend's model.")
  var model = JudgeFactory.defaultModel

  @Flag(help: "With --judge-backend: replace the stored recording with the live answers.")
  var record = false

  @OptionGroup var output: OutputOptions

  func validate() throws {
    if !judge, judgeBackend != nil || record {
      throw ValidationError("--judge-backend and --record need --judge")
    }
    if record, judgeBackend == nil { throw ValidationError("--record needs --judge-backend") }
  }

  func run() async throws {
    guard
      let path = harnessRoot ?? ProcessInfo.processInfo.environment[Self.harnessRootVariable]
    else {
      throw ValidationError(
        "pass --harness-root, or run through bin/swiftgate, which sets \(Self.harnessRootVariable)")
    }
    let root = CanonicalPath.url(URL(filePath: path, directoryHint: .isDirectory))
    if judge {
      let live = judgeBackend.flatMap {
        JudgeFactory.make(
          .enabled(backend: $0, thresholds: JudgeThresholds(advisory: 0, block: 1), model: model),
          runner: LiveProcessRunner(), cacheDirectory: nil)
      }
      try await StaticCheckRun.execute(root: root, format: output.format) {
        await JudgeSelfTest.run(harnessRoot: root, judge: live, record: record)
      }
      return
    }
    try await StaticCheckRun.execute(root: root, format: output.format) {
      await SelfTest.run(harnessRoot: root)
    }
  }
}
