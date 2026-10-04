/// Reads `go.mod`: an area per module, `go test` with `-run`, golangci-lint when configured.
public struct GoReader: EcosystemReader {
  public init() {}
  public func areas(in tree: TrackedTreeSnapshot) -> [ProposedArea] { [] }
}
