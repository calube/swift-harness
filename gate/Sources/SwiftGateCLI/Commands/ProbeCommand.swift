import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain

/// One probe in the report: its verdict file's content plus where the files are.
struct ProbeReportLine: Sendable, Equatable, Codable {
  let claimId: String
  let verdict: ProbeVerdictRecord.Outcome
  let cached: Bool
  /// Evidence-relative, as a probe claim cites it.
  let wrapper: String
  let verdictFile: String
  let diagnostics: [ProbeVerdictRecord.Diagnostic]
}

/// `swiftgate probe`'s report. GREEN when every probe passes, RED when any fails, BLOCKED when
/// no verdict could be trusted (bad input, a build that broke outside the probes, or a tool that
/// could not run).
struct ProbeReport: Sendable, Equatable, Codable {
  var command = "probe"
  let verdict: Verdict
  let design: String
  let platform: ProbePlatform?
  let sdk: String?
  /// `false` when the reuse cache answered every probe; `nil` when nothing was judged.
  let built: Bool?
  let probes: [ProbeReportLine]
  let notes: [String]
  let message: String
}

enum ProbeCommandRun {
  struct Options: Sendable, Equatable {
    var design: String
    /// Repo-relative or absolute directory of the Swift package the probes stand in for.
    var package: String
    var target: String
    var sdk: String?
    /// Stands in for `~` when locating the reuse cache.
    var cacheHome: URL
  }

  static func run(options: Options, root: URL, runner: any ProcessRunner) async -> ProbeReport {
    let design = options.design
    guard PlanFile.isValidDesignPath(design) else {
      return blocked(
        design, "--design `\(design)` must be a repo-relative docs/**/designs/<name>.md path")
    }
    let packageDirectory =
      options.package.hasPrefix("/")
      ? URL(filePath: options.package, directoryHint: .isDirectory)
      : root.appending(path: options.package, directoryHint: .isDirectory)

    let load: ProbeTargetLoader.Load
    do {
      load = try await ProbeTargetLoader.load(
        packageDirectory: packageDirectory, target: options.target, runner: runner,
        sdkVersion: options.sdk)
    } catch {
      return blocked(design, error.message)
    }

    let builder = ProbeBuilder(
      runner: runner, cache: EvidenceCacheStore(home: options.cacheHome),
      scratch: ProbeScratchLayout(worktreeRoot: root))
    let evidenceRoot = root.appending(
      path: EvidenceLayout(designDocPath: design).root, directoryHint: .isDirectory)
    let target = load.target
    switch await builder.run(evidenceRoot: evidenceRoot, target: target) {
    case .blocked(let message, let notes):
      return ProbeReport(
        verdict: .blocked, design: design, platform: target.platform, sdk: target.sdkVersion,
        built: nil, probes: [], notes: load.notes + notes, message: message)
    case .judged(let results, let built, let notes):
      let failed = results.filter { $0.record.verdict == .fail }.count
      let cached = results.filter(\.cached).count
      return ProbeReport(
        verdict: failed == 0 ? .green : .red, design: design, platform: target.platform,
        sdk: target.sdkVersion, built: built,
        probes: results.map {
          ProbeReportLine(
            claimId: $0.record.claimId, verdict: $0.record.verdict, cached: $0.cached,
            wrapper: $0.wrapperPath, verdictFile: $0.verdictPath,
            diagnostics: $0.record.diagnostics)
        },
        notes: load.notes + notes,
        message:
          "\(results.count) probe(s), \(failed) failed, \(cached) from the cache "
          + "(\(target.platform.rawValue) \(target.sdkVersion))")
    }
  }

  static func render(_ report: ProbeReport, format: OutputFormat) -> String {
    switch format {
    case .json:
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      return String(decoding: (try? encoder.encode(report)) ?? Data(), as: UTF8.self)
    case .human:
      var lines = ["probe: \(report.verdict.rawValue) \(report.message)"]
      for probe in report.probes {
        lines.append(
          "  \(probe.verdict.rawValue) \(probe.claimId)\(probe.cached ? " (cached)" : "")")
        for diagnostic in probe.diagnostics where diagnostic.level == .error {
          lines.append(
            "    \(diagnostic.file):\(diagnostic.line):\(diagnostic.column): \(diagnostic.message)")
        }
      }
      lines += report.notes.map { "  note: \($0)" }
      return lines.joined(separator: "\n")
    }
  }

  private static func blocked(_ design: String, _ message: String) -> ProbeReport {
    ProbeReport(
      verdict: .blocked, design: design, platform: nil, sdk: nil, built: nil, probes: [],
      notes: [], message: message)
  }
}

struct ProbeCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "probe",
    abstract: "Build a scratch package from a design's probe snippets and report pass/fail.",
    discussion:
      "Reads <slug>.evidence/probes/<ev-id>.snippet.swift and writes Probe_<id>.swift and "
      + "Probe_<id>.verdict.json beside them. The scratch package lives in .harness/probe/, "
      + "pinned to the package's Package.resolved and depending only on the target's remote "
      + "products. An iOS package builds with xcodebuild for the simulator, any other with "
      + "swift build. Exit 0 all pass, 1 any probe fails, 2 nothing could be judged.")

  @Option(help: "The design doc whose <slug>.evidence/probes/ snippets are built.")
  var design: String

  @Option(help: "The Swift package the probes stand in for.")
  var package: String

  @Option(help: "The package target whose remote products the probes may import.")
  var target: String

  @Option(help: "The SDK version in effect; defaults to what xcrun reports.")
  var sdk: String?

  @Option(help: "The directory standing in for ~ when locating the evidence reuse cache.")
  var cacheHome: String?

  @OptionGroup var output: OutputOptions

  func run() async throws {
    let root = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    let home =
      cacheHome.map { URL(filePath: $0, directoryHint: .isDirectory) }
      ?? FileManager.default.homeDirectoryForCurrentUser
    let report = await ProbeCommandRun.run(
      options: .init(
        design: design, package: package, target: target, sdk: sdk, cacheHome: home),
      root: root, runner: LiveProcessRunner())
    Console.write(ProbeCommandRun.render(report, format: output.format))
    if report.verdict != .green { throw ExitCode(report.verdict.exitCode) }
  }
}
