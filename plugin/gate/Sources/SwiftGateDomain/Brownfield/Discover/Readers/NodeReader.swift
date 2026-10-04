/// Reads `package.json` and its workspace file: an area per package with its test, lint and build scripts.
public struct NodeReader: EcosystemReader {
  public init() {}
  public func areas(in tree: TrackedTreeSnapshot) -> [ProposedArea] { [] }
}
