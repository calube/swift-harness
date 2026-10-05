import Foundation
import SwiftGateDomain

/// 1 area command that passed, as a later tier may take it without running it again.
public struct AreaStepPass: Sendable, Equatable, Codable {
  /// The gate run that ran it.
  public let runID: String
  public let tier: String
  /// What a test or e2e step's reports counted when it passed; `nil` for other steps, or when
  /// they left no report that reads.
  public let tests: AreaTestCounts?

  public init(runID: String, tier: String, tests: AreaTestCounts? = nil) {
    self.runID = runID
    self.tier = tier
    self.tests = tests
  }
}

/// The area commands that passed in a clone, by ``GateReuse/areaStepKey(_:area:step:command:)``.
public protocol AreaStepReusing: Sendable {
  /// The pass recorded for `key`, or `nil`.
  func pass(_ key: String) -> AreaStepPass?
  func record(_ pass: AreaStepPass, key: String)
}

/// ``AreaStepReusing`` as 1 file per key under `<clone root>/area-steps/`.
public struct AreaStepResults: AreaStepReusing {
  public static let directoryName = "area-steps"

  public var directory: URL { files.directory }
  private let files: KeyedJSONFiles<AreaStepPass>

  public init(directory: URL) {
    files = KeyedJSONFiles(directory: directory)
  }

  public init(layout: BrownfieldStateLayout) {
    self.init(
      directory: layout.cloneRoot.appending(path: Self.directoryName, directoryHint: .isDirectory))
  }

  /// A file that can't be read is no pass: the command runs.
  public func pass(_ key: String) -> AreaStepPass? { files.value(key) }

  /// A pass that can't be written is only not reused.
  public func record(_ pass: AreaStepPass, key: String) { files.write(pass, key: key) }
}

/// 1 area's prove that proved every changed test it ran, as a later gate on the same reverted
/// tree, or at the same head tree with the same changed tests, may take it without running it
/// again.
public struct ProvePass: Sendable, Equatable, Codable {
  /// The gate run that ran it.
  public let runID: String
  public let tier: String
  /// What it found for each changed test, for the later run's `prove.result` events.
  public let proved: [ProvedTest]
  /// What its judgement said, none of them gating.
  public let findings: [Finding]
  public let proven: Int
  public let total: Int

  public init(
    runID: String, tier: String, proved: [ProvedTest], findings: [Finding], proven: Int,
    total: Int
  ) {
    self.runID = runID
    self.tier = tier
    self.proved = proved
    self.findings = findings
    self.proven = proven
    self.total = total
  }
}

/// The proves that passed in a clone, each by both
/// ``GateReuse/proveKey(_:mergeBase:area:command:tests:copied:renames:)`` and
/// ``GateReuse/proveHeadKey(_:area:command:tests:copied:)``.
public protocol ProveReusing: Sendable {
  /// The pass recorded for `key`, or `nil`.
  func pass(_ key: String) -> ProvePass?
  func record(_ pass: ProvePass, key: String)
}

/// ``ProveReusing`` as 1 file per key under `<clone root>/prove-results/`.
public struct ProveResults: ProveReusing {
  public static let directoryName = "prove-results"

  private let files: KeyedJSONFiles<ProvePass>

  public init(directory: URL) {
    files = KeyedJSONFiles(directory: directory)
  }

  public init(layout: BrownfieldStateLayout) {
    self.init(
      directory: layout.cloneRoot.appending(path: Self.directoryName, directoryHint: .isDirectory))
  }

  /// A file that can't be read is no pass: the prove runs.
  public func pass(_ key: String) -> ProvePass? { files.value(key) }

  /// A pass that can't be written is only not reused.
  public func record(_ pass: ProvePass, key: String) { files.write(pass, key: key) }
}

/// 1 JSON file per key in `directory`, each written by atomic rename.
struct KeyedJSONFiles<Value: Codable>: Sendable {
  let directory: URL

  func value(_ key: String) -> Value? {
    guard let data = try? Data(contentsOf: file(key)) else { return nil }
    return try? JSONDecoder().decode(Value.self, from: data)
  }

  func write(_ value: Value, key: String) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(value) else { return }
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try? data.write(to: file(key), options: .atomic)
  }

  private func file(_ key: String) -> URL {
    directory.appending(path: "\(key).json")
  }
}
