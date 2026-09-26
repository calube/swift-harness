import IssueReporting

final class Cell {
  required init?(coder: NSCoder) { fatalError("storyboards unsupported") } // swiftgate:allow safety.fatal-error — no storyboard in this app; CellTests instantiates in code
  func unexpected() { reportIssue("unexpected state") }
  let note = "fatalError() needs a reason"
}
