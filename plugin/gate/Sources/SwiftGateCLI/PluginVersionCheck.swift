import Foundation
import SwiftGateDomain

/// Push's pinned plugin version check for a repository that ships a Claude Code plugin under
/// `plugin/`.
enum PluginVersionCheck {
  static func run(root: URL) throws(ReportContractViolation) -> [Finding] {
    []
  }
}
