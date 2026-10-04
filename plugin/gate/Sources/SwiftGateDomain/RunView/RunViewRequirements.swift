import Foundation

/// The requirements a run's plan names, in the shape ``RunViewInput`` takes, and the spec rows
/// the view draws from them. Pure: the plan arrives already parsed.
public enum RunViewRequirements {
  /// A spec page's slices: each slice's coverage id, titled by the acceptance line it quotes, or
  /// by its test name when it quotes none.
  public static func from(specPage: SpecPage) -> [RunViewRequirement] {
    specPage.slices.map { slice in
      switch slice.spec {
      case .quote(let line): RunViewRequirement(id: slice.id, title: line)
      case .none: RunViewRequirement(id: slice.id, title: slice.testName)
      }
    }
  }

  /// 1 row per requirement in plan order, with the tasks whose `covers` name it in ledger order.
  /// An uncovered requirement keeps its row with no tasks.
  static func rows(_ requirements: [RunViewRequirement], tasks: [LedgerTask]) -> [RunView.SpecRow] {
    requirements.map { requirement in
      RunView.SpecRow(
        id: requirement.id,
        title: RunViewText.cut(requirement.title, toBytes: RunView.maxTitleBytes),
        tasks: tasks.filter { $0.covers.contains(requirement.id) }.map(\.id))
    }
  }
}

enum RunViewText {
  /// `text`'s longest prefix of whole characters within `limit` UTF-8 bytes.
  static func cut(_ text: String, toBytes limit: Int) -> String {
    guard text.utf8.count > limit else { return text }
    var bytes = 0
    var end = text.startIndex
    for index in text.indices {
      let next = text.index(after: index)
      bytes += text[index..<next].utf8.count
      guard bytes <= limit else { break }
      end = next
    }
    return String(text[..<end])
  }
}
