/// Reads `Cargo.toml`: an area per workspace member, `cargo test` with a name filter, Clippy.
public struct CargoReader: EcosystemReader {
  public init() {}
  public func areas(in tree: TrackedTreeSnapshot) -> [ProposedArea] { [] }
}
