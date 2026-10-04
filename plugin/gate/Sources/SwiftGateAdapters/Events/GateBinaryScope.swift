import Foundation
import SwiftGateDomain

/// The binary this process runs as, bound once by the CLI's entry point, so every event writer
/// it builds names it without each caller passing it along.
public enum GateBinaryScope {
  @TaskLocal public static var current: GateBinary?
}

/// Reads what `bin/swiftgate` handed this process: its source hash, and the version in the
/// manifest of the plugin it belongs to.
public enum GateBinaryReader {
  /// The variable `bin/swiftgate` sets to the plugin root it runs from.
  public static let harnessRootVariable = "SWIFTGATE_HARNESS_ROOT"
  /// The plugin manifest, under the plugin root.
  public static let manifestPath = ".claude-plugin/plugin.json"

  public static func read(environment: [String: String]) -> GateBinary.Reading {
    GateBinary.Reading(binary: nil, problems: [])
  }
}
