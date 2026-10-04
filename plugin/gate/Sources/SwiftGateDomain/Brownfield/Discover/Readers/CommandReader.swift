/// Reads other build files (`mix.exs`, `CMakeLists.txt`, …): an area whose commands come only from CI.
public struct CommandReader: EcosystemReader {
  public init() {}
  public func areas(in tree: TrackedTreeSnapshot) -> [ProposedArea] { [] }
}
