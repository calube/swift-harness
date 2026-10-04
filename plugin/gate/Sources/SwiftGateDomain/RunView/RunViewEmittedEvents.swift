import Foundation

/// Folds the events a run emits for the view, spans, proofs, step starts and tool summaries,
/// into a view the derived spans already fill.
public enum RunViewEmittedEvents {
  public static func fold(_ events: [HarnessEvent], into view: RunView) -> RunView {
    view
  }
}
