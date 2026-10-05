import Foundation
import SwiftGateDomain

/// Seeds a worktree's DerivedData from the area's seed with an APFS clone of its
/// `SourcePackages`: the resolved package checkouts and binary artifacts. Build products and
/// module caches stay behind: they name the seed's absolute paths, so a build elsewhere
/// recompiles them anyway, and its build database deletes the seed's products as stale.
public struct DerivedDataSeeding: Sendable {
  public enum Outcome: Sendable, Equatable {
    case seeded
    /// The destination already exists, so an earlier run seeded or built it.
    case alreadyPresent
    /// The seed has no `SourcePackages` yet.
    case noSeed
    /// The build then starts cold.
    case failed(String)
  }

  public static let sourcePackages = "SourcePackages"
  /// SwiftPM's record of the resolved packages, which names their absolute paths.
  public static let workspaceState = "workspace-state.json"

  private let processRunner: any ProcessRunner

  public init(processRunner: any ProcessRunner = LiveProcessRunner()) {
    self.processRunner = processRunner
  }

  /// Clones into a staging folder beside the destination, then renames it into place, so a
  /// failed or concurrent seed never leaves a half-filled DerivedData behind.
  public func seed(_ copy: DerivedDataSeedCopy) async -> Outcome {
    let files = FileManager.default
    guard !files.fileExists(atPath: copy.destination) else { return .alreadyPresent }
    let packages = "\(copy.seed)/\(Self.sourcePackages)"
    guard files.fileExists(atPath: "\(packages)/\(Self.workspaceState)") else { return .noSeed }
    let destination = URL(filePath: copy.destination, directoryHint: .isDirectory)
    let staging = destination.deletingLastPathComponent().appending(
      path: ".\(destination.lastPathComponent).seeding-\(UUID().uuidString)",
      directoryHint: .isDirectory)
    defer { try? files.removeItem(at: staging) }
    do {
      try files.createDirectory(at: staging, withIntermediateDirectories: true)
      let cloned = staging.appending(path: Self.sourcePackages).path(percentEncoded: false)
      let output = try await processRunner.run(
        ProcessInvocation(
          executable: "/bin/cp", arguments: ["-c", "-R", packages, cloned],
          timeout: .seconds(300)))
      guard output.status.isSuccess else {
        return .failed(
          "cp -c -R \(packages) exited \(output.status): "
            + output.stderr.text.trimmingCharacters(in: .whitespacesAndNewlines))
      }
      let state = URL(filePath: "\(cloned)/\(Self.workspaceState)")
      let text = try String(contentsOf: state, encoding: .utf8)
      try Data(text.replacingOccurrences(of: copy.seed + "/", with: copy.destination + "/").utf8)
        .write(to: state, options: .atomic)
      try files.moveItem(at: staging, to: destination)
    } catch {
      return files.fileExists(atPath: copy.destination) ? .alreadyPresent : .failed("\(error)")
    }
    return .seeded
  }
}
