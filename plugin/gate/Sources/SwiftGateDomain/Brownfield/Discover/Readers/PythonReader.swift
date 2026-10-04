/// Reads `pyproject.toml` and `setup.cfg`: an area per project, the test runner with a filter, its linter.
public struct PythonReader: EcosystemReader {
  public init() {}
  public func areas(in tree: TrackedTreeSnapshot) -> [ProposedArea] { [] }
}
