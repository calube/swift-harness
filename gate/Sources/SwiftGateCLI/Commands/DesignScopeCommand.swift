import ArgumentParser
import Foundation
import SwiftGateDomain

/// What `design-scope` prints: the recommended tier, every reason that applied (with its human
/// message), and the frame answers it was computed from, so a reader never has to re-derive the
/// reasons from raw booleans and counts.
struct DesignScopeReport: Sendable, Equatable, Encodable {
  struct Reason: Sendable, Equatable, Encodable {
    let code: DesignScopeReason
    let message: String

    init(_ reason: DesignScopeReason) {
      code = reason
      message = reason.message
    }
  }

  let command = "design-scope"
  let tier: DesignTier
  let reasons: [Reason]
  let input: DesignScopeInput
  let message: String

  init(input: DesignScopeInput, recommendation: DesignScopeRecommendation) {
    self.input = input
    self.tier = recommendation.tier
    self.reasons = recommendation.reasons.map(Reason.init)
    self.message =
      recommendation.reasons.isEmpty
      ? "recommends \(recommendation.tier.rawValue)"
      : "recommends \(recommendation.tier.rawValue): "
        + recommendation.reasons.map(\.message).joined(separator: "; ")
  }

  static func render(_ report: DesignScopeReport, format: OutputFormat) -> String {
    switch format {
    case .json:
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      let data = (try? encoder.encode(report)) ?? Data()
      return String(decoding: data, as: UTF8.self)
    case .human:
      return "design-scope: \(report.message)"
    }
  }
}

/// The deterministic body of `design-scope`, factored out of the `ParsableCommand` so it's
/// testable without going through argument parsing or stdout.
enum DesignScopeRun {
  enum Outcome: Sendable, Equatable {
    case recommended(DesignScopeReport)
    case failed(message: String)
  }

  static func run(frameAnswersPath: String?) -> Outcome {
    guard let frameAnswersPath else {
      return .failed(message: "missing required option '--frame-answers <path>'")
    }
    let data: Data
    do {
      data = try Data(contentsOf: URL(filePath: frameAnswersPath))
    } catch {
      return .failed(message: "can't read `\(frameAnswersPath)`: \(error.localizedDescription)")
    }
    let input: DesignScopeInput
    do {
      input = try DesignScopeInputJSON.decode(data)
    } catch {
      return .failed(
        message: "`\(frameAnswersPath)` is not a valid frame-answers file: \(error)")
    }
    return .recommended(
      DesignScopeReport(input: input, recommendation: DesignScope.recommend(input)))
  }
}

struct DesignScopeCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "design-scope",
    abstract: "Recommend a design depth tier (quick/standard/deep) from frame answers.",
    discussion:
      "Reads a frame-answers JSON file: {schemaVersion: 1, addsDependency, addsModuleKind "
      + "(bool), modulesAdded, modulesTouched (int, modulesTouched >= modulesAdded >= 0)}, "
      + "written by the design skill's frame step from its module-graph comparison. Deep when "
      + "the design adds a dependency and a module kind together, adds 2 or more modules, or "
      + "touches 4 or more modules (spec §8.1 Decisions; fixed thresholds, not config). Quick "
      + "only when it adds neither a dependency nor a module kind; everything else is standard. "
      + "Exit 0 with the recommendation whatever the tier. Exit 2 — and no recommendation — when "
      + "--frame-answers is missing, unreadable, not valid JSON, on an unsupported "
      + "schemaVersion, or has a negative or out-of-order module count.")

  @Option(name: .customLong("frame-answers"), help: "Path to the frame-answers JSON file.")
  var frameAnswers: String?

  @OptionGroup var output: OutputOptions

  func run() throws {
    switch DesignScopeRun.run(frameAnswersPath: frameAnswers) {
    case .recommended(let report):
      Console.write(DesignScopeReport.render(report, format: output.format))
    case .failed(let message):
      FileHandle.standardError.write(Data("swiftgate design-scope: \(message)\n".utf8))
      throw ExitCode(Verdict.blocked.exitCode)
    }
  }
}
