/// Proposes areas for 1 ecosystem from tracked files alone: no build, no network, no other IO.
public protocol EcosystemReader: Sendable {
  func areas(in tree: TrackedTreeSnapshot) -> [ProposedArea]
}

/// Every reader discovery runs, in the order their proposals are merged.
public enum EcosystemReaders {
  public static let all: [any EcosystemReader] = [
    SwiftPMReader(), XcodeReader(), NodeReader(), PythonReader(), RubyReader(), JVMReader(),
    GoReader(), CargoReader(), CommandReader(),
  ]
}
