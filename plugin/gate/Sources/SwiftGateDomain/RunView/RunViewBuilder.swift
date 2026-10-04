import Foundation

/// Folds 1 build run's events, ledger and plan into a ``RunView``. Pure.
public enum RunViewBuilder {
  public static func build(_ input: RunViewInput) -> RunView {
    RunView(run: RunView.Run(id: input.buildRun))
  }
}
