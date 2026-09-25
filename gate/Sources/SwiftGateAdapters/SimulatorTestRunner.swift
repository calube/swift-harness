import Foundation
import SwiftGateDomain

/// Supplies a booted simulator for the duration of `body`.
public protocol SimulatorDeviceProvider: Sendable {
  func withDevice<T: Sendable>(_ body: @Sendable (SimulatorDevice) async throws -> T)
    async throws -> T
}

extension SimulatorClones: SimulatorDeviceProvider {
  public func withDevice<T: Sendable>(_ body: @Sendable (SimulatorDevice) async throws -> T)
    async throws -> T
  {
    try await withClone(body)
  }
}

public enum SimulatorJobResult: Sendable, Equatable {
  case ran(job: SimulatorJob, evidence: SimulatorTestEvidence)
  /// No evidence exists: the clone, `xcodebuild` or the result bundle failed.
  case notRun(job: SimulatorJob, reason: String)

  public var job: SimulatorJob {
    switch self {
    case .ran(let job, _), .notRun(let job, _): job
    }
  }
}

/// Runs simulator jobs one after another on a single clone: a clone boot costs tens of seconds,
/// and `xcodebuild` already parallelises within a job.
public struct SimulatorTestRunner: Sendable {
  private let devices: any SimulatorDeviceProvider
  private let xcodebuild: any Xcodebuild
  private let reader: any XcresultReader
  private let root: URL

  public init(
    devices: any SimulatorDeviceProvider, xcodebuild: any Xcodebuild, reader: any XcresultReader,
    root: URL
  ) {
    self.devices = devices
    self.xcodebuild = xcodebuild
    self.reader = reader
    self.root = root
  }

  /// Per-worktree DerivedData for a job (spec §4.4).
  public static func derivedDataPath(root: URL, job: SimulatorJob) -> URL {
    root.appending(path: HarnessGC.derivedDataDirectory, directoryHint: .isDirectory)
      .appending(path: job.name, directoryHint: .isDirectory)
  }

  public func run(
    _ jobs: [SimulatorJob], tier: Tier, outputDirectory: URL, recording: SnapshotRecording
  ) async -> [SimulatorJobResult] {
    guard !jobs.isEmpty else { return [] }
    let directory = outputDirectory.appending(
      path: tier.rawValue.lowercased(), directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    do {
      return try await devices.withDevice { device in
        var results: [SimulatorJobResult] = []
        for job in jobs {
          results.append(
            await runOne(
              job, tier: tier, device: device, directory: directory, recording: recording))
        }
        return results
      }
    } catch let error as SimulatorCloneError {
      return jobs.map { .notRun(job: $0, reason: Self.describe(error)) }
    } catch {
      return jobs.map { .notRun(job: $0, reason: "simulator: \(error)") }
    }
  }

  private func runOne(
    _ job: SimulatorJob, tier: Tier, device: SimulatorDevice, directory: URL,
    recording: SnapshotRecording
  ) async -> SimulatorJobResult {
    let bundle = directory.appending(path: "\(job.name).xcresult")
    // `xcodebuild` refuses to overwrite a bundle, and an old one must never stand in for this run.
    try? FileManager.default.removeItem(at: bundle)
    let derivedData = Self.derivedDataPath(root: root, job: job)
    try? FileManager.default.createDirectory(at: derivedData, withIntermediateDirectories: true)
    let request = XcodebuildTestRequest(
      container: container(job.container), scheme: job.scheme, destinationUDID: device.udid,
      derivedDataPath: derivedData.path, resultBundlePath: bundle.path,
      onlyTesting: job.onlyTesting, recording: recording)
    let run: XcodebuildTestRun
    do throws(XcodebuildError) {
      run = try await xcodebuild.test(
        request, logPath: directory.appending(path: "\(job.name).xcodebuild.log").path)
    } catch {
      return .notRun(job: job, reason: error.message)
    }
    let contents: XcresultContents
    do throws(XcresultReadError) {
      contents = try await reader.read(bundlePath: bundle.path)
    } catch {
      return .notRun(job: job, reason: error.message)
    }
    return .ran(
      job: job,
      evidence: SimulatorTestEvidence(
        tier: tier, testTargets: job.targets, succeeded: run.status.isSuccess,
        testResults: contents.testResults, buildResults: contents.buildResults,
        testSourceFiles: sourceFiles(for: job), repositoryRoot: root.path, recording: recording))
  }

  private func container(_ container: SimulatorJob.Container) -> XcodebuildContainer {
    switch container {
    case .package(let path):
      return .package(directory: root.appending(path: path, directoryHint: .isDirectory).path)
    case .app(let path):
      let absolute = root.appending(path: path).path
      return path.hasSuffix(".xcworkspace")
        ? .workspace(path: absolute) : .project(path: absolute)
    }
  }

  /// Package jobs resolve failures against their targets' sources; the app job, whose UI test
  /// targets the graph does not know, against every Swift file in the repository.
  private func sourceFiles(for job: SimulatorJob) -> [String] {
    let directories = job.targets.isEmpty ? [""] : job.targets.map(\.path)
    return directories.flatMap {
      RepositoryFiles.list(root: root, under: $0) { $0.hasSuffix(".swift") }
    }
  }

  private static func describe(_ error: SimulatorCloneError) -> String {
    switch error {
    case .lock(let error): "simulator slot: \(error)"
    case .simctl(let error): error.message
    case .selection(let error): error.message
    }
  }
}

/// Repository-relative files under a directory, skipping hidden directories (`.build`, `.git`,
/// `.harness`) and `DerivedData`.
public enum RepositoryFiles {
  public static func list(root: URL, under directory: String, where include: (String) -> Bool)
    -> [String]
  {
    let base =
      directory.isEmpty ? root : root.appending(path: directory, directoryHint: .isDirectory)
    guard
      let enumerator = FileManager.default.enumerator(
        at: base, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
    else { return [] }
    let prefix = base.standardizedFileURL.path + "/"
    var found: [String] = []
    for case let url as URL in enumerator {
      if url.lastPathComponent == "DerivedData" {
        enumerator.skipDescendants()
        continue
      }
      let relative = String(url.standardizedFileURL.path.dropFirst(prefix.count))
      guard include(relative) else { continue }
      found.append(directory.isEmpty ? relative : "\(directory)/\(relative)")
    }
    return found.sorted()
  }
}
