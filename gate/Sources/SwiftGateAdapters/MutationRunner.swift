import Foundation
import SwiftGateDomain

public enum MutantBuildResult: Sendable, Equatable {
  case built
  /// The compiler rejected the code; `log` is the tail of its output.
  case failed(log: String)
  /// The build tool could not run: not evidence about the code.
  case unavailable(String)
}

public enum MutantTestResult: Sendable, Equatable {
  case passed(executed: Int)
  /// Failing test ids (`Target.Suite/test`), empty when the process died before reporting.
  case failed(failingTests: [String])
  case timedOut(after: Duration)
  case unavailable(String)
}

/// Builds and runs one package's tests inside a scratch tree. Build and test are separate so a
/// mutant that does not compile is told apart from one the tests kill, and so the per-mutant
/// timeout bounds only the test run.
public protocol MutationToolchain: Sendable {
  func buildTests(root: URL, packageDirectory: String) async -> MutantBuildResult

  /// - Parameter reportPath: absolute XCTest xUnit path; Swift Testing's lands beside it.
  func test(root: URL, selection: HostTestSelection, timeout: Duration, reportPath: String) async
    -> (result: MutantTestResult, elapsed: Duration)
}

/// ``MutationToolchain`` over `swift build --build-tests` and `swift test --skip-build`.
public struct LiveMutationToolchain: MutationToolchain {
  private let runner: any ProcessRunner
  private let executable: String
  private let buildTimeout: Duration

  public init(
    runner: any ProcessRunner, executable: String = "swift", buildTimeout: Duration = .seconds(900)
  ) {
    self.runner = runner
    self.executable = executable
    self.buildTimeout = buildTimeout
  }

  public func buildTests(root: URL, packageDirectory: String) async -> MutantBuildResult {
    let output: ProcessOutput
    do {
      output = try await runner.run(
        ProcessInvocation(
          executable: executable, arguments: ["build", "--build-tests"],
          workingDirectory: Self.directory(root, packageDirectory), timeout: buildTimeout))
    } catch {
      return .unavailable("swift build: \(error)")
    }
    guard output.status.isSuccess else {
      return .failed(log: Self.tail(output.stdout.text + output.stderr.text))
    }
    return .built
  }

  public func test(
    root: URL, selection: HostTestSelection, timeout: Duration, reportPath: String
  ) async -> (result: MutantTestResult, elapsed: Duration) {
    let swiftTestingPath = LiveSwiftPM.swiftTestingReportPath(for: reportPath)
    for path in [reportPath, swiftTestingPath] { try? FileManager.default.removeItem(atPath: path) }
    try? FileManager.default.createDirectory(
      at: URL(filePath: reportPath).deletingLastPathComponent(), withIntermediateDirectories: true)
    let output: ProcessOutput
    do {
      output = try await runner.run(
        ProcessInvocation(
          executable: executable,
          arguments: [
            "test", "--skip-build", "--parallel", "--xunit-output", reportPath, "--filter",
            selection.filter,
          ],
          // The snapshot library's default silently records missing references and passes.
          environmentOverlay: ["SNAPSHOT_TESTING_RECORD": "never"],
          workingDirectory: Self.directory(root, selection.packagePath), timeout: timeout))
    } catch {
      if case .timedOut(_, let after, _, _) = error { return (.timedOut(after: after), after) }
      return (.unavailable("swift test: \(error)"), .zero)
    }
    let cases = [reportPath, swiftTestingPath].flatMap { path -> [XUnitTestCase] in
      guard let data = FileManager.default.contents(atPath: path) else { return [] }
      return (try? XUnitReport.parse(data)) ?? []
    }
    guard output.status.isSuccess else {
      let failing = cases.compactMap { testCase -> String? in
        guard case .failed = testCase.outcome else { return nil }
        return "\(testCase.className)/\(testCase.name)"
      }
      return (.failed(failingTests: failing), output.elapsed)
    }
    return (.passed(executed: cases.count { $0.isExecuted }), output.elapsed)
  }

  private static func directory(_ root: URL, _ packageDirectory: String) -> String {
    packageDirectory.isEmpty ? root.path : root.appending(path: packageDirectory).path
  }

  private static func tail(_ text: String) -> String {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
    let errors = lines.filter { $0.contains("error:") }
    return (errors.isEmpty ? lines.suffix(5) : errors.prefix(5)).joined(separator: "\n")
  }
}

/// How long a mutant's tests may run: a multiple of the unmutated run in the same tree, never
/// under `floor`. A mutant that loops forever is stopped here and counted as killed.
public struct MutantTimeout: Sendable, Equatable {
  public let floor: Duration
  public let multiplier: Int

  public init(floor: Duration = .seconds(20), multiplier: Int = 5) {
    self.floor = floor
    self.multiplier = max(1, multiplier)
  }

  public func limit(baseline: Duration) -> Duration { max(floor, baseline * multiplier) }
}

/// One mutant to run: the file's text before and after, and the T1 selections that exercise it.
public struct MutantJob: Sendable, Equatable {
  public let mutant: Mutant
  public let originalText: String
  public let mutatedText: String
  /// Every package's test targets depending on the mutated module. Empty: no test can kill it.
  public let selections: [HostTestSelection]

  public init(
    mutant: Mutant, originalText: String, mutatedText: String, selections: [HostTestSelection]
  ) {
    self.mutant = mutant
    self.originalText = originalText
    self.mutatedText = mutatedText
    self.selections = selections
  }
}

public struct MutationRunResult: Sendable, Equatable {
  /// In job order.
  public let results: [MutantResult]
  public let workers: Int
}

/// Runs mutants in parallel scratch worktrees, one worker per tree, so builds never share a
/// build directory. Each worker builds and runs each package's tests unmutated once (the
/// baseline its timeouts scale from), then takes mutants as ``MutantSchedule`` hands them out:
/// write the mutant, build, run the affected tests, restore the file.
public struct MutationRunner: Sendable {
  private let scratch: any ScratchWorktrees
  private let toolchain: any MutationToolchain
  private let workers: Int
  private let timeout: MutantTimeout
  private let baselineTimeout: Duration

  public init(
    scratch: any ScratchWorktrees, toolchain: any MutationToolchain, workers: Int,
    timeout: MutantTimeout = MutantTimeout(), baselineTimeout: Duration = .seconds(900)
  ) {
    self.scratch = scratch
    self.toolchain = toolchain
    self.workers = max(1, workers)
    self.timeout = timeout
    self.baselineTimeout = baselineTimeout
  }

  /// - Parameters:
  ///   - tree: what every worker's scratch tree holds (the change, uncommitted work included).
  ///   - projectPrefix: where the project sits inside the tree (`""` at its toplevel); mutant
  ///     files and package paths are relative to the project.
  ///   - reportDirectory: where each worker writes its test reports.
  public func run(
    _ jobs: [MutantJob], tree: ScratchTreeRequest, projectPrefix: String, reportDirectory: URL
  ) async -> MutationRunResult {
    var results = [MutantOutcome?](repeating: nil, count: jobs.count)
    let pending = jobs.indices.filter { !jobs[$0].selections.isEmpty }
    for index in jobs.indices where jobs[index].selections.isEmpty { results[index] = .noTests }
    let workerCount = min(workers, pending.count)
    var scratchFailure: String?
    if workerCount > 0 {
      let queue = MutantQueue(
        pending, packages: pending.map { Set(jobs[$0].selections.map(\.packagePath)) })
      let finished = await withTaskGroup(of: WorkerOutput.self) { group in
        for worker in 1...workerCount {
          group.addTask {
            await work(
              worker, jobs: jobs, queue: queue, tree: tree, projectPrefix: projectPrefix,
              reportDirectory: reportDirectory.appending(path: "worker-\(worker)"))
          }
        }
        var outputs: [WorkerOutput] = []
        for await output in group { outputs.append(output) }
        return outputs
      }
      for output in finished {
        for (index, outcome) in output.outcomes { results[index] = outcome }
        if let failure = output.failure { scratchFailure = failure }
      }
    }
    let reason = scratchFailure ?? "no worker ran this mutant"
    return MutationRunResult(
      results: jobs.indices.map { index in
        MutantResult(mutant: jobs[index].mutant, outcome: results[index] ?? .noEvidence(reason))
      },
      workers: workerCount)
  }

  private struct WorkerOutput: Sendable {
    var outcomes: [(Int, MutantOutcome)] = []
    var failure: String?
  }

  private enum Baseline {
    case ready(Duration)
    case broken(String)
  }

  private func work(
    _ worker: Int, jobs: [MutantJob], queue: MutantQueue, tree: ScratchTreeRequest,
    projectPrefix: String, reportDirectory: URL
  ) async -> WorkerOutput {
    do throws(ScratchWorktreeError) {
      return try await scratch.withScratchTree(tree) { toplevel in
        let root = projectPrefix.isEmpty ? toplevel : toplevel.appending(path: projectPrefix)
        var output = WorkerOutput()
        var baselines: [String: Baseline] = [:]
        var reportIndex = 0
        func reportPath(_ selection: HostTestSelection) -> String {
          reportIndex += 1
          return reportDirectory.appending(
            path: "\(reportIndex)-\(HostTestRunner.fileStem(selection.packagePath)).xml"
          ).path
        }
        while let index = await queue.next(worker: worker) {
          let job = jobs[index]
          for selection in job.selections where baselines[selection.packagePath] == nil {
            baselines[selection.packagePath] = await baseline(
              selection, root: root, reportPath: reportPath(selection))
          }
          let outcome = await run(
            job, root: root, baselines: baselines, reportPath: reportPath)
          output.outcomes.append((index, outcome.outcome))
          if let failure = outcome.fatal {
            output.failure = failure
            await queue.finish(worker: worker)
            break
          }
        }
        return output
      }
    } catch {
      return WorkerOutput(failure: "scratch worktree: \(error)")
    }
  }

  private func baseline(_ selection: HostTestSelection, root: URL, reportPath: String) async
    -> Baseline
  {
    switch await toolchain.buildTests(root: root, packageDirectory: selection.packagePath) {
    case .failed(let log):
      return .broken("\(selection.packagePath) does not build unmutated: \(log)")
    case .unavailable(let reason): return .broken(reason)
    case .built: break
    }
    let (result, elapsed) = await toolchain.test(
      root: root, selection: selection, timeout: baselineTimeout, reportPath: reportPath)
    switch result {
    case .passed: return .ready(elapsed)
    case .failed(let tests):
      return .broken(
        "\(selection.packagePath) tests fail unmutated"
          + (tests.isEmpty ? "" : ": \(tests.prefix(3).joined(separator: ", "))"))
    case .timedOut(let after):
      return .broken("\(selection.packagePath) tests time out unmutated after \(after)")
    case .unavailable(let reason): return .broken(reason)
    }
  }

  /// `fatal` stops the worker: its tree can no longer be trusted to hold the unmutated change.
  private func run(
    _ job: MutantJob, root: URL, baselines: [String: Baseline],
    reportPath: (HostTestSelection) -> String
  ) async -> (outcome: MutantOutcome, fatal: String?) {
    var budgets: [Duration] = []
    for selection in job.selections {
      switch baselines[selection.packagePath] {
      case .ready(let elapsed): budgets.append(timeout.limit(baseline: elapsed))
      case .broken(let reason): return (.noEvidence(reason), nil)
      case nil: return (.noEvidence("no baseline for \(selection.packagePath)"), nil)
      }
    }
    let file = root.appending(path: job.mutant.file)
    guard let current = try? String(contentsOf: file, encoding: .utf8),
      current == job.originalText
    else {
      return (
        .noEvidence("the scratch tree's \(job.mutant.file) differs from the working tree"), nil
      )
    }
    do {
      try Data(job.mutatedText.utf8).write(to: file)
    } catch {
      return (.noEvidence("writing the mutant: \(error)"), nil)
    }
    let outcome = await judge(job, root: root, budgets: budgets, reportPath: reportPath)
    do {
      try Data(job.originalText.utf8).write(to: file)
    } catch {
      return (outcome, "restoring \(job.mutant.file) after a mutant: \(error)")
    }
    return (outcome, nil)
  }

  private func judge(
    _ job: MutantJob, root: URL, budgets: [Duration], reportPath: (HostTestSelection) -> String
  ) async -> MutantOutcome {
    for selection in job.selections {
      switch await toolchain.buildTests(root: root, packageDirectory: selection.packagePath) {
      case .built: continue
      case .failed(let log): return .unviable(log)
      case .unavailable(let reason): return .noEvidence(reason)
      }
    }
    var executed = 0
    for (selection, budget) in zip(job.selections, budgets) {
      let (result, _) = await toolchain.test(
        root: root, selection: selection, timeout: budget, reportPath: reportPath(selection))
      switch result {
      case .failed(let tests): return .killed(failingTests: tests)
      case .timedOut(let after): return .timedOut(after: after)
      case .unavailable(let reason): return .noEvidence(reason)
      case .passed(let count): executed += count
      }
    }
    return executed == 0 ? .noTests : .survived(testsRun: executed)
  }
}

private actor MutantQueue {
  private let indices: [Int]
  private var schedule: MutantSchedule

  init(_ indices: [Int], packages: [Set<String>]) {
    self.indices = indices
    schedule = MutantSchedule(jobPackages: packages)
  }

  func next(worker: Int) -> Int? { schedule.next(worker: worker).map { indices[$0] } }

  func finish(worker: Int) { schedule.finish(worker: worker) }
}
