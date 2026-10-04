/// Whether a shipped Claude Code plugin pins a version that would stop installs refreshing.
public enum PluginVersionRule {
  public static let pinnedRuleID = "plugin-version.pinned"
  public static let malformedRuleID = "plugin-version.malformed"
  public static let summaryRuleID = "plugin-version.summary"

  public static let manifestPath = "plugin/.claude-plugin/plugin.json"
  public static let marketplacePath = ".claude-plugin/marketplace.json"

  /// - Parameters:
  ///   - manifest: the plugin's `plugin.json`.
  ///   - marketplace: the repository's `marketplace.json`; `nil` when the repository has none.
  public static func findings(manifest: String, marketplace: String?)
    throws(ReportContractViolation) -> [Finding]
  {
    []
  }
}
