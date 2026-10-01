import Foundation
import SwiftGateDomain

/// The writer every emitter gets. `[telemetry] enabled = false` gets a writer that keeps nothing.
/// The judge's scope writes its audit trail through ``HarnessEventFiles`` directly, so the
/// opt-out never reaches it.
public enum EventWriterFactory {
  public static func make(root: URL, enabled: Bool) -> any HarnessEventWriting {
    enabled ? HarnessEventFiles(root: root) : DisabledEventWriter()
  }
}

/// Keeps nothing and never fails.
public struct DisabledEventWriter: HarnessEventWriting {
  public init() {}

  public func append(_ event: HarnessEvent) throws(HarnessEventWriteError) {}

  public func append(contentsOf events: [HarnessEvent]) throws(HarnessEventWriteError) {}
}
