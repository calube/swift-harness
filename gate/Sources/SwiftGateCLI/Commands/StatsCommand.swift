import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain

enum StatsRenderer {
  static func human(_ rows: [TierStats], invalidLines: Int) -> String {
    guard !rows.isEmpty else {
      return "no runs recorded in \(RunLayout.historyFile)" + unreadable(invalidLines)
    }
    let header = ["command", "tier", "runs", "p50", "p95", "budget", "verdicts"]
    let body = rows.map { row -> [String] in
      let verdicts = Verdict.allCases.compactMap { verdict in
        row.verdicts[verdict].map { "\($0) \(verdict.rawValue)" }
      }
      return [
        row.command, row.tier.rawValue, "\(row.runs)",
        ReportRenderer.duration(row.p50Milliseconds),
        ReportRenderer.duration(row.p95Milliseconds) + (row.overBudget ? " OVER" : ""),
        row.budgetMilliseconds.map(ReportRenderer.duration) ?? "-",
        verdicts.joined(separator: ", "),
      ]
    }
    let table = [header] + body
    let widths = header.indices.map { column in table.map { $0[column].count }.max() ?? 0 }
    let lines = table.map { cells in
      zip(cells, widths).map { cell, width in
        cell + String(repeating: " ", count: width - cell.count)
      }
      .joined(separator: "  ")
      .trimmingCharacters(in: .whitespaces)
    }
    return lines.joined(separator: "\n") + unreadable(invalidLines)
  }

  private static func unreadable(_ count: Int) -> String {
    count == 0 ? "" : "\n\(count) unreadable history line\(count == 1 ? "" : "s") skipped"
  }

  struct Row: Encodable {
    let command: String
    let tier: String
    let runs: Int
    let p50Milliseconds: Int
    let p95Milliseconds: Int
    let budgetMilliseconds: Int?
    let overBudget: Bool
    let verdicts: [String: Int]
  }

  static func json(_ rows: [TierStats]) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let encoded = rows.map {
      Row(
        command: $0.command, tier: $0.tier.rawValue, runs: $0.runs,
        p50Milliseconds: $0.p50Milliseconds, p95Milliseconds: $0.p95Milliseconds,
        budgetMilliseconds: $0.budgetMilliseconds, overBudget: $0.overBudget,
        verdicts: Dictionary(uniqueKeysWithValues: $0.verdicts.map { ($0.key.rawValue, $0.value) }))
    }
    return String(decoding: try encoder.encode(encoded), as: UTF8.self)
  }
}

struct StatsCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "stats",
    abstract: "Per-command, per-tier duration p50/p95 against budgets, from run history.")

  @OptionGroup var output: OutputOptions

  func run() async throws {
    let root = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    let history = try RunStore(worktreeRoot: root).readHistory()
    // Budgets are optional context: without a readable config the table has no budget column.
    let budgets = (try? ConfigLoader().load(repositoryRoot: root))??.budgets
    let rows = RunStats.summarize(history.records, budgets: budgets)
    switch output.format {
    case .human: Console.write(StatsRenderer.human(rows, invalidLines: history.invalidLines))
    case .json: Console.write(try StatsRenderer.json(rows))
    }
  }
}
