import Foundation

/// Whether a shipped Claude Code plugin pins a version that would stop installs refreshing.
///
/// Claude Code takes an install's version from `plugin.json`'s `version`, then the marketplace
/// entry's `version`, then the marketplace clone's commit, and `claude plugin update` keeps an
/// install whose version string is unchanged. With neither pinned, every commit is a new version.
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
    guard let plugin = object(manifest), let name = plugin["name"] as? String else {
      return [
        try malformed(manifestPath, "isn't a JSON object with a \"name\", so it can't be checked.")
      ]
    }
    var found: [Finding] = []
    if plugin["version"] != nil {
      found.append(try pinned(manifestPath, "pins \"version\""))
    }
    if let marketplace {
      guard let plugins = object(marketplace)?["plugins"] as? [Any],
        plugins.allSatisfy({ $0 is [String: Any] })
      else {
        return found + [
          try malformed(
            marketplacePath,
            "isn't a JSON object with a \"plugins\" array of objects, so it "
              + "can't be checked.")
        ]
      }
      let entries = plugins.compactMap { $0 as? [String: Any] }
      if entries.contains(where: { $0["name"] as? String == name && $0["version"] != nil }) {
        found.append(try pinned(marketplacePath, "pins \"version\" in the \(name) entry"))
      }
    }
    guard found.isEmpty else { return found }
    return [
      try finding(
        summaryRuleID, .nit, manifestPath,
        "\(name) pins no version, so installs take the marketplace commit as theirs and "
          + "`claude plugin update` refreshes them on every commit.")
    ]
  }

  private static func object(_ json: String) -> [String: Any]? {
    (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
  }

  private static func pinned(_ file: String, _ what: String) throws(ReportContractViolation)
    -> Finding
  {
    try finding(
      pinnedRuleID, .major, file,
      "\(file) \(what). A pinned version stops `claude plugin update` from refreshing installs "
        + "until someone raises it; remove it so installs take the marketplace commit.")
  }

  /// A manifest that can't be read or parsed gates rather than passing unchecked.
  public static func malformed(_ file: String, _ reason: String) throws(ReportContractViolation)
    -> Finding
  {
    try finding(malformedRuleID, .major, file, "\(file) \(reason)")
  }

  private static func finding(
    _ rule: String, _ severity: Severity, _ file: String, _ message: String
  ) throws(ReportContractViolation) -> Finding {
    try Finding(
      ruleID: rule, severity: severity, file: file, line: nil, message: message,
      failureScenario: nil)
  }
}
