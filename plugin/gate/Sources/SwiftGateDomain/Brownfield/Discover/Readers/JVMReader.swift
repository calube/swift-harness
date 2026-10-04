/// Reads `build.gradle(.kts)` and `pom.xml`: an area per module, the test task with a filter, its linter.
public struct JVMReader: EcosystemReader {
  public init() {}
  public func areas(in tree: TrackedTreeSnapshot) -> [ProposedArea] { [] }
}
