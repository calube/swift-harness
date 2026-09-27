import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateRules

/// `review-input`: the deterministic gather step of the review workflow (spec §9.2 step 1). Runs
/// the push gate and stops unless it is GREEN — reviewing code that fails its own gate wastes
/// reviewer tokens — then writes everything a reviewer reads into
/// `.harness/runs/<id>/review-input/`.
enum ReviewInputRun {
  static let directoryName = "review-input"
  static let manifestFile = "manifest.json"

  struct Dependencies: Sendable {
    let git: any Git
    let diff: any DiffReading
    /// The push-tier gate.
    let check: @Sendable (GateRun.Context) async throws -> GateRunParts
    /// Comment discipline on the lines added since the merge base.
    let comments: @Sendable ([AddedLines]) async -> StaticCheckOutcome
    /// Mutation testing on the changed lines: surviving mutants seed the test-quality reviewer.
    let mutate: @Sendable (GateRun.Context) async -> ChangedTestJudgement

    static func live(root: URL, base: String) -> Dependencies {
      let runner = LiveProcessRunner()
      let git = LiveGit(runner: runner, repositoryRoot: root.path)
      let swiftPM = ScopeResolution.liveSwiftPM(root: root)
      let check = CheckRun.Dependencies(
        root: root, swiftPM: swiftPM, git: git,
        formatter: LiveSwiftFormatter(runner: runner, repositoryRoot: root.path))
      return Dependencies(
        git: git, diff: git,
        check: { context in
          try await CheckRun.run(
            root: root, tier: .push, base: base, context: context, dependencies: check)
        },
        comments: { added in
          await CommentsCheck.run(added: added, root: root, swiftPM: swiftPM)
        },
        mutate: { context in
          await mutation(root: root, base: base, context: context, dependencies: check)
        })
    }

    /// `mutate` as `check --tier ready` runs it; a repository whose modules can't be resolved
    /// gets a note instead of mutants.
    private static func mutation(
      root: URL, base: String, context: GateRun.Context, dependencies: CheckRun.Dependencies
    ) async -> ChangedTestJudgement {
      let config: Config
      switch StaticCheckInputs.loadConfig(root: root) {
      case .success(let loaded?): config = loaded
      case .success(nil), .failure: return notRun("\(ConfigLoader.fileName) could not be loaded")
      }
      guard
        case .resolved(let scopes) = await ScopeResolution.resolve(
          config: config, root: root, swiftPM: dependencies.swiftPM),
        let graph = scopes.graph
      else { return notRun("the module graph could not be resolved") }
      return await MutateCheck.run(
        dependencies.mutation, graph: graph, config: config, base: base, context: context)
    }

    private static func notRun(_ reason: String) -> ChangedTestJudgement {
      let note = try? Finding(
        ruleID: CheckRun.notRunRuleID, severity: .nit, file: ".", line: nil,
        message: "mutate not run: \(reason)", failureScenario: nil)
      return ChangedTestJudgement(findings: note.map { [$0] } ?? [], blocked: true)
    }
  }

  enum Outcome: Sendable {
    case ready(ReviewInputManifest, directory: URL)
    /// The gate is not GREEN; nothing is reviewed.
    case stopped(RunReport, directory: URL)
    case blocked(String)
  }

  static func gather(
    root: URL, base: String, context: GateRun.Context, dependencies: Dependencies
  ) async throws -> Outcome {
    let directory = context.directory.appending(path: directoryName, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let mergeBase: String
    do throws(GitError) {
      guard let found = try await dependencies.git.mergeBase("HEAD", base) else {
        return .blocked("HEAD and \(base) share no history; pass --base <ref>")
      }
      mergeBase = found
    } catch {
      return .blocked("git: \(error)")
    }

    let (parts, milliseconds) = try await GateRun.timed { try await dependencies.check(context) }
    let check = try RunReport(
      runID: context.runID, durationMilliseconds: milliseconds, tiers: parts.tiers,
      findings: parts.findings, allowances: parts.allowances)
    try write(RunReportJSON.encode(check), "check.json", in: directory)
    guard check.verdict == .green else { return .stopped(check, directory: directory) }

    let archIDs = Set(ArchCheck.ruleIDs)
    let testlintIDs = Set(RuleCatalog.testlint.map(\.descriptor.id))
    try write(
      encode(check.findings.filter { archIDs.contains($0.ruleID) }), "arch.json", in: directory)
    try write(
      encode(check.findings.filter { testlintIDs.contains($0.ruleID) }), "testlint.json",
      in: directory)

    let changed: [String]
    let added: [AddedLines]
    let diff: String
    do throws(GitError) {
      changed = try await ChangedPaths.since(mergeBase, git: dependencies.git)
      let prefix = try await dependencies.git.workingDirectoryPrefix()
      added = try await dependencies.git.addedLines(since: mergeBase)
        .filter { $0.path.hasPrefix(prefix) }
        .map { AddedLines(path: String($0.path.dropFirst(prefix.count)), ranges: $0.ranges) }
      diff = try await dependencies.diff.unifiedDiff(since: mergeBase)
    } catch {
      return .blocked("git: \(error)")
    }
    let comments = try StaticCheckReport.make(
      runID: context.runID, durationMilliseconds: 0,
      outcome: await dependencies.comments(added.filter { $0.path.hasSuffix(".swift") }))
    try write(RunReportJSON.encode(comments), "comments.json", in: directory)
    // Mutation is ready-tier evidence, not a push gate: surviving mutants are what the
    // test-quality reviewer weighs, so its verdict is recorded and never stops the review.
    let mutation = await dependencies.mutate(context)
    try write(encode(mutation.findings), "mutate.json", in: directory)
    try write(Data(diff.utf8), "diff.patch", in: directory)

    let swiftFiles = changed.filter { $0.hasSuffix(".swift") }
    let manifest = ReviewInputManifest(
      runID: context.runID, base: base, mergeBase: mergeBase, gateVerdict: check.verdict,
      changedFiles: changed,
      swiftUIUnits: SwiftUIReach.touchedUnits(changedSwiftFiles: swiftFiles) {
        importsSwiftUI(unit: $0, root: root)
      },
      artifacts: ReviewInputManifest.Artifacts(
        check: "check.json", arch: "arch.json", testlint: "testlint.json",
        comments: "comments.json", diff: "diff.patch", mutate: "mutate.json"),
      notes: ["mutate: \(mutation.verdict.rawValue)"])
    try write(encode(manifest), manifestFile, in: directory)
    return .ready(manifest, directory: directory)
  }

  /// A module directory imports SwiftUI when any of its Swift files does; a lone file when it does.
  private static func importsSwiftUI(unit: String, root: URL) -> Bool {
    let url = root.appending(path: unit)
    guard unit.hasSuffix("/") else {
      return (try? String(contentsOf: url, encoding: .utf8)).map(SwiftUIReach.importsSwiftUI)
        ?? false
    }
    guard let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)
    else { return false }
    for case let file as URL in files where file.pathExtension == "swift" {
      if let text = try? String(contentsOf: file, encoding: .utf8),
        SwiftUIReach.importsSwiftUI(text)
      {
        return true
      }
    }
    return false
  }

  private static func encode(_ value: some Encodable) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
  }

  private static func write(_ data: Data, _ name: String, in directory: URL) throws {
    try data.write(to: directory.appending(path: name), options: .atomic)
  }
}

extension CommentsCheck {
  /// Comment rules over working-tree files, restricted to `added` lines (review gather step).
  static func run(added: [AddedLines], root: URL, swiftPM: any SwiftPM) async -> StaticCheckOutcome
  {
    let config: Config?
    switch StaticCheckInputs.loadConfig(root: root) {
    case .success(let loaded): config = loaded
    case .failure(let failure): return failure.outcome
    }
    let scopes: ResolvedScopes
    switch await ScopeResolution.resolve(config: config, root: root, swiftPM: swiftPM) {
    case .failed(let outcome): return outcome
    case .resolved(let resolved): scopes = resolved
    }
    var inputs: [SourceInput] = []
    for lines in added {
      guard let text = try? String(contentsOf: root.appending(path: lines.path), encoding: .utf8)
      else { return .blocked(reason: "could not read \(lines.path)") }
      inputs.append(SourceInput(path: lines.path, text: text))
    }
    return scopes.appendingNotices(
      to: StaticCheck.evaluate(
        RuleCatalog.comments, inputs, context: RuleContext(scopes: scopes.resolver),
        restrictTo: added))
  }
}

struct ReviewInputCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "review-input",
    abstract:
      "Gather the review bundle: push gate, arch/testlint/comments/mutate output, and the diff.",
    discussion:
      "Stops with the gate's exit status unless the push tier is GREEN. On success prints the "
      + "bundle directory (or the manifest with --json).")

  @Option(help: "Changes are measured from the merge base of HEAD and this ref.")
  var base = "origin/main"

  @OptionGroup var output: OutputOptions

  func run() async throws {
    let root = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    let startedAt = Date()
    let runID = RunID.make(startedAt: startedAt, suffix: UInt32.random(in: .min ... .max))
    let store = RunStore(worktreeRoot: root)
    let directory = try store.runDirectory(for: runID)
    let outcome = try await ReviewInputRun.gather(
      root: root, base: base, context: GateRun.Context(runID: runID, directory: directory),
      dependencies: .live(root: root, base: base))
    switch outcome {
    case .blocked(let reason):
      FileHandle.standardError.write(Data("swiftgate review-input: BLOCKED — \(reason)\n".utf8))
      throw ExitCode(Verdict.blocked.exitCode)
    case .stopped(let report, _):
      recordHistory(report, store: store)
      Console.write(try ReportRenderer.render(report, format: output.format))
      if output.format == .human {
        Console.write(
          "review-input: stopped — the push gate is \(report.verdict.rawValue.uppercased()); fix it first"
        )
      }
      throw ExitCode(report.verdict.exitCode)
    case .ready(let manifest, let bundle):
      if output.format == .json {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        Console.write(String(decoding: try encoder.encode(manifest), as: UTF8.self))
      } else {
        Console.write(
          "review-input: ready — \(bundle.path)\n"
            + "focuses: \(manifest.focuses.map(\.rawValue).joined(separator: ", "))\n"
            + "changed files: \(manifest.changedFiles.count)")
      }
    }
  }

  private func recordHistory(_ report: RunReport, store: RunStore) {
    do {
      try store.record(report, finishedAt: Date(), command: "review-input")
    } catch {
      FileHandle.standardError.write(Data("swiftgate: could not record run: \(error)\n".utf8))
    }
  }
}

/// `review-synth`: deterministic synthesis of the per-focus verifier outputs (spec §9.2 step 4).
enum ReviewSynthRun {
  static let reportFile = "review.json"

  struct InputFailure: Error, Sendable, Equatable, CustomStringConvertible {
    let file: String
    let detail: String
    var description: String { "\(file): \(detail)" }
  }

  /// Reads every focus file, writes `review.json` into `runDirectory`, and returns the report.
  static func run(files: [URL], runDirectory: URL) throws -> ReviewReport {
    var inputs: [FocusReview] = []
    for file in files {
      do {
        inputs.append(try FocusReviewJSON.decode(Data(contentsOf: file)))
      } catch {
        throw InputFailure(file: file.path, detail: "\(error)")
      }
    }
    let report: ReviewReport
    do {
      report = try ReviewSynthesis.synthesize(inputs)
    } catch {
      throw InputFailure(file: "(inputs)", detail: "\(error)")
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
    try encoder.encode(report).write(
      to: runDirectory.appending(path: reportFile), options: .atomic)
    return report
  }
}

/// `review-synth --design`: the design review verdict (design spec §8.2) over per-reviewer files,
/// through the same input-failure path and exit contract as `review-synth`.
enum DesignReviewSynthRun {
  static let reportFile = "design-review.json"

  static func run(design: URL, tier: DesignTier, files: [URL], runDirectory: URL) throws
    -> DesignReviewReport
  {
    let text: String
    do {
      text = try String(contentsOf: design, encoding: .utf8)
    } catch {
      throw ReviewSynthRun.InputFailure(file: design.path, detail: "\(error)")
    }
    var inputs: [DesignReview] = []
    for file in files {
      do {
        inputs.append(try DesignReviewJSON.decode(Data(contentsOf: file)))
      } catch {
        throw ReviewSynthRun.InputFailure(file: file.path, detail: "\(error)")
      }
    }
    let report: DesignReviewReport
    do {
      report = try DesignReviewSynthesis.synthesize(
        inputs, tier: tier, document: MarkdownDocument.parse(text))
    } catch {
      throw ReviewSynthRun.InputFailure(file: "(inputs)", detail: "\(error)")
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
    try encoder.encode(report).write(
      to: runDirectory.appending(path: reportFile), options: .atomic)
    return report
  }
}

struct ReviewSynthCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "review-synth",
    abstract:
      "Dedupe verified review findings and decide merge / fix-then-merge / refactor-needed.",
    discussion:
      "Each input is one focus's verified findings (schemaVersion 1). A focus with no input "
      + "counts as NOT REVIEWED. Writes review.json into --run-directory and prints the verdict "
      + "and the top 10 findings. Exit 0 whatever the verdict; 2 when an input breaks the contract.\n\n"
      + "With --design <doc> --tier <quick|standard|deep|sketch>, each input is one design reviewer's "
      + "findings (schemaVersion 1, located by section anchor) and the verdict is ready / revise / "
      + "rethink plus the reviewers to re-run, written to design-review.json. A required reviewer "
      + "with no input counts as NOT REVIEWED. Exit 0 whatever the verdict; 2 on a contract "
      + "violation (unknown reviewer, duplicate reviewer, anchor absent from the doc, bad tier)."
  )

  @Option(help: "The review run directory (.harness/runs/<id>); review.json is written there.")
  var runDirectory: String

  @Flag(help: "Print review.json instead of the summary.")
  var json = false

  @Option(help: "Synthesize a design review of this design doc instead of a code review.")
  var design: String?

  @Option(help: "The design's depth tier (quick, standard, deep, sketch); required with --design.")
  var tier: String?

  @Argument(help: "Per-focus findings files (per-reviewer files with --design).")
  var findings: [String] = []

  func validate() throws {
    // Only a design review may have no inputs: quick tier runs no reviewers.
    if design == nil, tier == nil, findings.isEmpty {
      throw ValidationError("Missing expected argument '<findings> ...'")
    }
  }

  func run() throws {
    if design != nil || tier != nil {
      try runDesign()
      return
    }
    let directory = URL(filePath: runDirectory, directoryHint: .isDirectory)
    let report: ReviewReport
    do {
      report = try ReviewSynthRun.run(
        files: findings.map { URL(filePath: $0) }, runDirectory: directory)
    } catch let failure as ReviewSynthRun.InputFailure {
      FileHandle.standardError.write(Data("swiftgate review-synth: \(failure)\n".utf8))
      throw ExitCode(Verdict.blocked.exitCode)
    }
    let path = directory.appending(path: ReviewSynthRun.reportFile).path
    if json {
      Console.write(
        String(decoding: try Data(contentsOf: URL(filePath: path)), as: UTF8.self))
    } else {
      Console.write(ReviewSummary.render(report, reportPath: path))
    }
  }

  private func runDesign() throws {
    guard let design else { try fail("--tier needs --design <doc>") }
    guard let tier else { try fail("--design needs --tier <quick|standard|deep|sketch>") }
    guard let designTier = DesignTier(rawValue: tier) else {
      try fail(
        "unknown tier '\(tier)'; expected one of "
          + DesignTier.allCases.map(\.rawValue).joined(separator: ", "))
    }
    let directory = URL(filePath: runDirectory, directoryHint: .isDirectory)
    let report: DesignReviewReport
    do {
      report = try DesignReviewSynthRun.run(
        design: URL(filePath: design), tier: designTier, files: findings.map { URL(filePath: $0) },
        runDirectory: directory)
    } catch let failure as ReviewSynthRun.InputFailure {
      try fail("\(failure)")
    }
    let path = directory.appending(path: DesignReviewSynthRun.reportFile).path
    if json {
      Console.write(
        String(decoding: try Data(contentsOf: URL(filePath: path)), as: UTF8.self))
    } else {
      Console.write(DesignReviewSummary.render(report, reportPath: path))
    }
  }

  private func fail(_ message: String) throws -> Never {
    FileHandle.standardError.write(Data("swiftgate review-synth: \(message)\n".utf8))
    throw ExitCode(Verdict.blocked.exitCode)
  }
}
