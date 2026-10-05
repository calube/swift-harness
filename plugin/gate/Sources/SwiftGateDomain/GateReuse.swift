import CryptoKit
import Foundation

/// A brownfield gate that already ran GREEN on the same inputs answers again without running.
/// The key names everything a brownfield tier's verdict reads: the tier, the committed tree, the
/// merge base it is measured from, the gate binary, and the clone's config, baseline and warm-up
/// times for that merge base. Any input that can't be read leaves the run with no key, so it runs.
public enum GateReuse {
  public static let ruleID = "gate.reused"

  /// What a brownfield tier's verdict depends on, outside the code it runs.
  public struct Inputs: Sendable, Equatable {
    public let tier: CheckTier
    /// `HEAD^{tree}` of a clean working tree.
    public let treeHash: String
    /// The merge base of `HEAD` and `--base`.
    public let mergeBase: String
    /// The hash of the sources the running `swiftgate` was built from.
    public let sourceHash: String
    /// Each state file the tier reads, by name, as a SHA-256 hex digest of its bytes; `nil` for a
    /// file that doesn't exist.
    public let stateFiles: [String: String?]

    public init(
      tier: CheckTier, treeHash: String, mergeBase: String, sourceHash: String,
      stateFiles: [String: String?]
    ) {
      self.tier = tier
      self.treeHash = treeHash
      self.mergeBase = mergeBase
      self.sourceHash = sourceHash
      self.stateFiles = stateFiles
    }
  }

  /// A SHA-256 hex digest over every input, in a fixed order.
  public static func key(_ inputs: Inputs) -> String {
    ""
  }

  /// The newest GREEN run of `command` recorded with `key` on a clean tree, or `nil`.
  public static func reusable(_ records: [RunHistoryRecord], command: String, key: String)
    -> RunHistoryRecord?
  {
    nil
  }

  /// The SHA-256 hex digest of `data`, for ``Inputs/stateFiles``.
  public static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
