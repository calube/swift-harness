import Foundation

/// A `qa run --before-merge`'s rows, kept beside its report with the tree its trial merge made,
/// so a later run whose trial merge makes the same tree takes the rows that passed there.
public struct QAMergedTreeRun: Sendable, Equatable, Codable {
  public static let fileName = "merged-tree-run.json"

  /// The trial merge's tree: `<merge commit>^{tree}`.
  public let tree: String
  /// The rows, each with its check's digest; `preparedBy` names the task merged.
  public let run: QAAtBaseRun

  public init(tree: String, run: QAAtBaseRun) {
    self.tree = tree
    self.run = run
  }

  /// The newest record of `records` made on `tree`; run ids start with their UTC start time.
  public static func newest(on tree: String, in records: [QAMergedTreeRun]) -> QAMergedTreeRun? {
    nil
  }

  public func encoded() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(self) + Data("\n".utf8)
  }

  public static func decode(_ data: Data) throws -> QAMergedTreeRun {
    try JSONDecoder().decode(QAMergedTreeRun.self, from: data)
  }
}
