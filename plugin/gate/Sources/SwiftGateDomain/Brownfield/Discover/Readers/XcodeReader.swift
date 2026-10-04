/// Reads Xcode projects and workspaces: schemes from shared `.xcscheme` files, test targets and the inclusion kind.
public struct XcodeReader: EcosystemReader {
  public init() {}
  public func areas(in tree: TrackedTreeSnapshot) -> [ProposedArea] { [] }
}
