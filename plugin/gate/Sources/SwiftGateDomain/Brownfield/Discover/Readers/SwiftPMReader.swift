/// Reads Package.swift files: an area per package, `swift test --package-path` with `--filter`.
public struct SwiftPMReader: EcosystemReader {
  public init() {}
  public func areas(in tree: TrackedTreeSnapshot) -> [ProposedArea] { [] }
}
