/// The closed set of values `index set` may write to a plan's `status` (spec §5.8): `designing`
/// → `in-review` → `approved` → `planned` → `building` → `done`, plus `abandoned` and
/// `superseded` from any state. `index set` rejects any other value with exit 2; readers tolerate
/// an unknown or legacy value in an old index by treating it as unfinished, so a bad entry stays
/// visible instead of silently disappearing from the active list.
public enum PlanStatus: String, Sendable, Equatable, Codable, CaseIterable {
  case designing
  case inReview = "in-review"
  case approved
  case planned
  case building
  case done
  case abandoned
  case superseded

  /// SessionStart stops listing a plan as active once it reaches one of these (spec §5.8).
  public var isFinished: Bool {
    switch self {
    case .done, .abandoned, .superseded: true
    case .designing, .inReview, .approved, .planned, .building: false
    }
  }
}
