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
    var lines = [
      "schema 1", "tier \(inputs.tier.rawValue)", "tree \(inputs.treeHash)",
      "merge-base \(inputs.mergeBase)", "binary \(inputs.sourceHash)",
    ]
    for name in inputs.stateFiles.keys.sorted() {
      lines.append("file \(name) \((inputs.stateFiles[name] ?? nil) ?? "absent")")
    }
    return digest(Data(lines.joined(separator: "\n").utf8))
  }

  /// The key of 1 area command that passed under `inputs`, whichever tier ran it: a `final` on a
  /// tree whose `merge` ran the same command GREEN needn't run it again.
  public static func areaStepKey(_ inputs: Inputs, area: String, step: AreaStep, command: String)
    -> String
  {
    var lines = [
      "area-step schema 1", "tree \(inputs.treeHash)", "merge-base \(inputs.mergeBase)",
      "binary \(inputs.sourceHash)",
    ]
    for name in inputs.stateFiles.keys.sorted() {
      lines.append("file \(name) \((inputs.stateFiles[name] ?? nil) ?? "absent")")
    }
    lines += ["area \(area)", "step \(step.rawValue)", "command \(command)"]
    return digest(Data(lines.joined(separator: "\n").utf8))
  }

  /// The key of 1 area's prove: its reverted run's verdict reads only the tree prove makes,
  /// `mergeBase` with the changed tests copied in and each file renamed since put back at its new
  /// path, and the command it runs there. A `final` whose prove makes the same tree as a merge's
  /// needn't run it again, whatever else the head changed.
  /// - Parameters:
  ///   - inputs: the binary and the clone's config; the head's tree and the baseline aren't read.
  ///   - tests: the selectors the command runs.
  ///   - copied: each changed test file copied into the tree, by path, as a digest of its bytes;
  ///     `nil` for a file the head deleted.
  ///   - renames: new path → old path for each file renamed since `mergeBase`.
  public static func proveKey(
    _ inputs: Inputs, mergeBase: String, area: String, command: String, tests: [String],
    copied: [String: String?], renames: [String: String]
  ) -> String {
    var lines = [
      "prove schema 1", "merge-base \(mergeBase)", "binary \(inputs.sourceHash)",
      "config \((inputs.stateFiles["config"] ?? nil) ?? "absent")", "area \(area)",
      "command \(command)",
    ]
    lines += tests.sorted().map { "test \($0)" }
    lines += copied.keys.sorted().map { "copied \($0) \((copied[$0] ?? nil) ?? "absent")" }
    lines += renames.keys.sorted().map { "renamed \($0) \(renames[$0] ?? "")" }
    return digest(Data(lines.joined(separator: "\n").utf8))
  }

  /// The newest run of `command` recorded with `key` on a clean tree when it is GREEN, else `nil`.
  public static func reusable(_ records: [RunHistoryRecord], command: String, key: String)
    -> RunHistoryRecord?
  {
    // Only the newest run on these inputs answers: a GREEN behind a later RED is a flake.
    guard
      let newest = records.last(where: {
        $0.command == command && $0.reuseKey == key && $0.dirty == false
      }), newest.verdict == .green
    else { return nil }
    return newest
  }

  /// The SHA-256 hex digest of `data`, for ``Inputs/stateFiles``.
  public static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
