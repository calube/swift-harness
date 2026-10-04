import Foundation
import SwiftGateAdapters
import SwiftGateDomain

/// Whether a checkout records events, under the profile its clone runs.
enum TelemetryOptIn {
  /// `[telemetry] enabled` of an owned repository's `.swiftgate.toml`; always on in a brownfield
  /// clone, whose events stay under the git dir (design §12); `nil` outside a project.
  static func enabled(root: URL) -> Result<Bool?, StaticCheckInputs.ConfigFailure> {
    guard let common = ConfigLoader.commonDirectory(enclosing: root) else {
      return StaticCheckInputs.loadConfig(root: root).map { $0?.telemetry.enabled }
    }
    do throws(ProfileLoadError) {
      switch try ConfigLoader().loadProfile(repositoryRoot: root, commonDir: common) {
      case nil: return .success(nil)
      case .owned(let config): return .success(config.telemetry.enabled)
      case .brownfield: return .success(true)
      }
    } catch {
      let outcome: StaticCheckOutcome =
        error.verdict == .red
        ? .invalid(reason: error.description) : .blocked(reason: error.description)
      return .failure(StaticCheckInputs.ConfigFailure(outcome: outcome))
    }
  }

  /// The checkout's event writer: `nil` outside a project or for a config that doesn't load, and
  /// a writer that keeps nothing when telemetry is off.
  static func writer(root: URL) -> (any HarnessEventWriting)? {
    guard case .success(let enabled?) = enabled(root: root) else { return nil }
    return EventWriterFactory.make(root: root, enabled: enabled)
  }
}
