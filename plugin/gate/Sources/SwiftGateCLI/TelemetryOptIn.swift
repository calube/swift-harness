import Foundation
import SwiftGateAdapters
import SwiftGateDomain

/// Whether a checkout records events, under the profile its clone runs.
enum TelemetryOptIn {
  /// `[telemetry] enabled` of the checkout's config; `nil` outside a project.
  static func enabled(root: URL) -> Result<Bool?, StaticCheckInputs.ConfigFailure> {
    StaticCheckInputs.loadConfig(root: root).map { $0?.telemetry.enabled }
  }

  /// The checkout's event writer: `nil` outside a project or for a config that doesn't load, and
  /// a writer that keeps nothing when telemetry is off.
  static func writer(root: URL) -> (any HarnessEventWriting)? {
    guard case .success(let enabled?) = enabled(root: root) else { return nil }
    return EventWriterFactory.make(root: root, enabled: enabled)
  }
}
