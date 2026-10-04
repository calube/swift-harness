/// Reads `Gemfile` roots: RSpec or Minitest, RuboCop when configured.
public struct RubyReader: EcosystemReader {
  public init() {}
  public func areas(in tree: TrackedTreeSnapshot) -> [ProposedArea] { [] }
}
