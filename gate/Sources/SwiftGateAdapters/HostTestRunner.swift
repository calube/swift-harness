import Foundation
import SwiftGateDomain

/// The test targets of one package that a T1 run executes.
public struct HostTestSelection: Sendable, Equatable {
  /// Repository-relative package directory.
  public let packagePath: String
  public let targets: [TestTargetReference]

  public init(packagePath: String, targets: [TestTargetReference]) {
    self.packagePath = packagePath
    self.targets = targets
  }

  /// One `--filter` matching every test in the selected targets and nothing else. Test ids start
  /// with the target name for both frameworks (`Target.Class/test`, `Target.Suite/test()`).
  public var filter: String {
    "^(" + targets.map { NSRegularExpression.escapedPattern(for: $0.name) }.joined(separator: "|")
      + ")\\."
  }
}

/// What one package's run left: the evidence to judge, or why `swift test` could not run.
public enum HostTestPackageResult: Sendable, Equatable {
  case ran(HostTestEvidence, coverage: Data?)
  case failed(packagePath: String, SwiftPMError)
}

/// Runs `swift test` for T1 selections and gathers the evidence the domain rules judge. Always
/// builds with code coverage: toggling instrumentation invalidates the package's build (about 20s
/// for a TCA package), and `check` needs coverage at the push tier, so every T1 run shares one
/// build configuration.
public struct HostTestRunner: Sendable {
  private let swiftPM: any SwiftPM
  private let root: URL
  private let maxConcurrentPackages: Int

  /// - Parameter root: the worktree root the package paths are relative to.
  public init(swiftPM: any SwiftPM, root: URL, maxConcurrentPackages: Int = 2) {
    self.swiftPM = swiftPM
    self.root = root.standardizedFileURL.resolvingSymlinksInPath()
    self.maxConcurrentPackages = max(1, maxConcurrentPackages)
  }

  /// - Parameters:
  ///   - outputDirectory: where reports and console logs go (the run's directory).
  ///   - readCoverage: also read each package's llvm-cov export after its run.
  public func run(
    _ selections: [HostTestSelection], outputDirectory: URL, readCoverage: Bool
  ) async -> [HostTestPackageResult] {
    await withTaskGroup(of: (Int, HostTestPackageResult).self) { group in
      var results = [HostTestPackageResult?](repeating: nil, count: selections.count)
      var next = 0
      func start() {
        guard next < selections.count else { return }
        let index = next
        let selection = selections[index]
        next += 1
        group.addTask {
          (
            index,
            await runOne(selection, outputDirectory: outputDirectory, readCoverage: readCoverage)
          )
        }
      }
      for _ in 0..<maxConcurrentPackages { start() }
      for await (index, result) in group {
        results[index] = result
        start()
      }
      return results.compactMap { $0 }
    }
  }

  private func runOne(
    _ selection: HostTestSelection, outputDirectory: URL, readCoverage: Bool
  ) async -> HostTestPackageResult {
    let stem = Self.fileStem(selection.packagePath)
    let reportPath = outputDirectory.appending(path: "\(stem).xml").path
    let run: SwiftTestRun
    do throws(SwiftPMError) {
      try? FileManager.default.createDirectory(
        at: outputDirectory, withIntermediateDirectories: true)
      // A report left by an earlier run must not stand in for one this run failed to write.
      for path in [reportPath, LiveSwiftPM.swiftTestingReportPath(for: reportPath)] {
        try? FileManager.default.removeItem(atPath: path)
      }
      run = try await swiftPM.test(
        SwiftTestRequest(
          packageDirectory: selection.packagePath, filters: [selection.filter], parallel: true,
          codeCoverage: true, xunitOutputPath: reportPath))
    } catch {
      return .failed(packagePath: selection.packagePath, error)
    }
    let stdout = run.output.stdout.text
    let stderr = run.output.stderr.text
    try? Data((stdout + "\n--- stderr ---\n" + stderr).utf8).write(
      to: outputDirectory.appending(path: "\(stem).log"))

    let xctestReport = try? Data(contentsOf: URL(filePath: run.xctestReportPath))
    let swiftTestingReport = try? Data(contentsOf: URL(filePath: run.swiftTestingReportPath))
    var coverage: Data?
    // With no report the tests never ran, so any export on disk is from an earlier run.
    if readCoverage, xctestReport != nil || swiftTestingReport != nil,
      let path = try? await swiftPM.codeCoveragePath(packageDirectory: selection.packagePath)
    {
      coverage = try? Data(contentsOf: URL(filePath: path))
    }
    return .ran(
      HostTestEvidence(
        packagePath: selection.packagePath, testTargets: selection.targets,
        succeeded: run.output.status.isSuccess,
        xctestReport: xctestReport, swiftTestingReport: swiftTestingReport,
        stdout: stdout, stderr: stderr,
        testSourceFiles: selection.targets.flatMap { swiftFiles(under: $0.path) },
        repositoryRoot: root.path),
      coverage: coverage)
  }

  private func swiftFiles(under directory: String) -> [String] {
    let base = root.appending(path: directory, directoryHint: .isDirectory)
    guard let enumerator = FileManager.default.enumerator(atPath: base.path) else { return [] }
    return enumerator.compactMap { $0 as? String }
      .filter { $0.hasSuffix(".swift") }
      .map { "\(directory)/\($0)" }
      .sorted()
  }

  static func fileStem(_ packagePath: String) -> String {
    packagePath.isEmpty ? "root" : packagePath.replacingOccurrences(of: "/", with: "_")
  }
}
