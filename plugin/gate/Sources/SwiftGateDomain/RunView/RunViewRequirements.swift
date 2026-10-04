import Foundation

/// The requirements a run's plan names, in the shape ``RunViewInput`` takes. Pure: the plan
/// arrives already parsed.
public enum RunViewRequirements {
  /// A spec page's slices: each slice's coverage id, titled by the acceptance line it quotes, or
  /// by its test name when it quotes none.
  public static func from(specPage: SpecPage) -> [RunViewRequirement] {
    []
  }

  /// A design's requirement bullets, each titled by its statement.
  public static func from(design: DesignDocument) -> [RunViewRequirement] {
    []
  }
}
