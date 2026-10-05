import Foundation
import SwiftGateDomain

/// 1 area command that passed, as a later tier may take it without running it again.
public struct AreaStepPass: Sendable, Equatable, Codable {
  /// The gate run that ran it.
  public let runID: String
  public let tier: String

  public init(runID: String, tier: String) {
    self.runID = runID
    self.tier = tier
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

  public let directory: URL

  public init(directory: URL) {
    self.directory = directory
  }

  public init(layout: BrownfieldStateLayout) {
    self.init(
      directory: layout.cloneRoot.appending(path: Self.directoryName, directoryHint: .isDirectory))
  }

  /// A file that can't be read is no pass: the command runs.
  public func pass(_ key: String) -> AreaStepPass? {
    guard let data = try? Data(contentsOf: file(key)) else { return nil }
    return try? JSONDecoder().decode(AreaStepPass.self, from: data)
  }

  /// A pass that can't be written is only not reused.
  public func record(_ pass: AreaStepPass, key: String) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(pass) else { return }
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try? data.write(to: file(key), options: .atomic)
  }

  private func file(_ key: String) -> URL {
    directory.appending(path: "\(key).json")
  }
}
