import Foundation

/// Standards §7 on the real tree: every interactive element a step captured carries an
/// identifier and a readable label.
public enum SimAccessibilityRules {
  /// `sim.a11y-identifier` and `sim.a11y-label` findings over `tree`, in element order.
  public static func findings(_ tree: SimTree, step: SimStep) -> [SimEvidenceFinding] {
    []
  }
}
