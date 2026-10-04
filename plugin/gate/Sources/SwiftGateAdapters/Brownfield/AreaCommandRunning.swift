import SwiftGateDomain

/// Runs 1 brownfield area command. The live runner spawns a process; tests pass a fake.
public protocol AreaCommandRunning: Sendable {
  func run(_ request: AreaCommandRequest) async -> AreaCommandOutcome
}
