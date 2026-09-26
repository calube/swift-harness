public enum Score {
  /// Letter grade for a 0–100 score.
  public static func grade(_ points: Int) -> String {
    if points >= 90 { return "A" }
    if points >= 70 { return "B" }
    return "F"
  }

  public static func isPassing(_ points: Int) -> Bool {
    points >= 70
  }
}
