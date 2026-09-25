import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain

/// `snapshots record`: the only legal way to rewrite snapshot references (spec §7.2 rule 4). It
/// runs the T2 snapshot targets with recording on, on a clone of the pinned simulator under the
/// pinned Xcode, and lists the reference files that changed so they show up for review.
enum SnapshotRecord {
  static func run(
    root: URL, swiftPM: any SwiftPM, packages: [String],
    dependencies: SimulatorTestCheck.Dependencies, context: GateRun.Context
  ) async throws -> GateRunParts {
    let repository: ConfiguredRepository.Loaded
    switch await ConfiguredRepository.load(
      root: root, swiftPM: swiftPM, command: "snapshots record")
    {
    case .failed(let outcome): return try TestCheck.parts(failure: outcome, tier: .t2)
    case .loaded(let loaded): repository = loaded
    }
    let config = repository.config

    // References rendered by another Xcode differ by anti-aliasing and fonts, so they would fail
    // every pinned run afterwards.
    let installed = (try? await dependencies.xcodebuild.version()).flatMap(Doctor.xcodeVersion)
    guard let installed, Doctor.matchesPin(installed: installed, pin: config.xcode) else {
      return try TestCheck.parts(
        failure: .blocked(
          reason:
            "snapshots record needs the pinned Xcode \(config.xcode); "
            + "\(installed.map { "Xcode \($0)" } ?? "no Xcode") is selected"),
        tier: .t2)
    }

    var jobs = SimulatorJob.packageJobs(
      plan: TierPlan(allOf: repository.graph, tier: .t2), graph: repository.graph)
    if !packages.isEmpty {
      let known = Set(repository.graph.packages.map(\.name))
      if let unknown = packages.first(where: { !known.contains($0) }) {
        return try TestCheck.parts(
          failure: .invalid(
            reason: "no package named \(unknown); known: \(known.sorted().joined(separator: ", "))"),
          tier: .t2)
      }
      jobs = jobs.filter { job in
        packages.contains { name in
          repository.graph.packages.first { $0.name == name }.map {
            job.container == .package(path: $0.path)
          } ?? false
        }
      }
    }
    guard !jobs.isEmpty else {
      return try TestCheck.parts(
        failure: .invalid(reason: "no simulator (T2) test target to record snapshots from"),
        tier: .t2)
    }

    let directories = jobs.flatMap { $0.targets.map(\.path) }
    let before = HarnessFiles.snapshotReferences(root: root, directories: directories)
    var parts = try await SimulatorTestCheck.run(
      jobs, tier: .t2, config: config, root: root, dependencies: dependencies,
      context: context, recording: .all)
    let after = HarnessFiles.snapshotReferences(root: root, directories: directories)
    for change in SnapshotReferences.changes(before: before, after: after) {
      parts.findings.append(
        try Finding(
          ruleID: SnapshotReferences.recordedRuleID, severity: .nit, file: change.path,
          line: nil, message: "reference \(change.kind.rawValue); review it in the diff",
          failureScenario: nil))
    }
    return parts
  }
}

struct SnapshotsCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "snapshots", abstract: "Manage snapshot references.",
    subcommands: [SnapshotsRecordCommand.self])
}

struct SnapshotsRecordCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "record",
    abstract:
      "Re-record snapshot references on the pinned simulator and Xcode; lists changed files.")

  @Option(name: .customLong("package"), help: "Only this package (repeatable).")
  var packages: [String] = []

  @OptionGroup var output: OutputOptions

  func run() async throws {
    let root = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    let swiftPM = ScopeResolution.liveSwiftPM(root: root)
    try await GateRun.execute(root: root, format: output.format, command: "snapshots record") {
      context in
      try await SnapshotRecord.run(
        root: root, swiftPM: swiftPM, packages: packages, dependencies: .live(),
        context: context)
    }
  }
}
