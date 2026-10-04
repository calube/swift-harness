import Foundation
import SwiftGateDomain

/// Push's pinned plugin version check for a repository that ships a Claude Code plugin under
/// `plugin/` (ADR 0002). A repository with no plugin manifest is skipped; a manifest that can't be
/// read gates, never a silent pass.
enum PluginVersionCheck {
  static func run(root: URL) throws(ReportContractViolation) -> [Finding] {
    let manifestURL = root.appending(path: PluginVersionRule.manifestPath)
    guard FileManager.default.fileExists(atPath: manifestURL.path) else { return [] }
    let manifest: String
    do {
      manifest = try String(contentsOf: manifestURL, encoding: .utf8)
    } catch {
      return [
        try PluginVersionRule.malformed(PluginVersionRule.manifestPath, "can't be read: \(error)")
      ]
    }
    let marketplaceURL = root.appending(path: PluginVersionRule.marketplacePath)
    var marketplace: String?
    if FileManager.default.fileExists(atPath: marketplaceURL.path) {
      do {
        marketplace = try String(contentsOf: marketplaceURL, encoding: .utf8)
      } catch {
        return [
          try PluginVersionRule.malformed(
            PluginVersionRule.marketplacePath, "can't be read: \(error)")
        ]
      }
    }
    return try PluginVersionRule.findings(manifest: manifest, marketplace: marketplace)
  }
}
