/// Accessibility identifiers the UI tests and simulator flows drive.
public enum AccessibilityID {
  public enum Watchlist {
    public static let list = "watchlist.list"
    public static let loading = "watchlist.loading"
    public static let error = "watchlist.error"
    public static let retry = "watchlist.retry"
    public static let lastUpdated = "watchlist.lastUpdated"
    /// `watchlist.row.bitcoin`: the tappable row.
    public static func row(_ id: String) -> String { "watchlist.row.\(id)" }
    public static func name(_ id: String) -> String { "watchlist.name.\(id)" }
    public static func price(_ id: String) -> String { "watchlist.price.\(id)" }
    public static func change(_ id: String) -> String { "watchlist.change.\(id)" }
  }

  public enum Detail {
    public static let name = "detail.name"
    public static let price = "detail.price"
    public static let chart = "detail.chart"
    public static let chartLoading = "detail.chart.loading"
    public static let chartError = "detail.chart.error"
    public static let chartRetry = "detail.chart.retry"
  }
}
