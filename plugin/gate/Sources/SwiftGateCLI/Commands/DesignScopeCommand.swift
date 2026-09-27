import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain

/// What `design-scope` prints: the recommended tier, every reason that applied (with its human
/// message), and both the raw frame answers and the counts derived from them against the module
/// graph, so a reader never has to re-derive the reasons or trust the derivation blindly.
struct DesignScopeReport: Sendable, Equatable, Encodable {
  struct Reason: Sendable, Equatable, Encodable {
    let code: DesignScopeReason
    let message: String

    init(_ reason: DesignScopeReason) {
      code = reason
      message = reason.message
    }
  }

  struct Input: Sendable, Equatable, Encodable {
    let answers: DesignScopeAnswers
    let derived: DesignScopeGraphFacts
  }

  let command = "design-scope"
  let tier: DesignTier
  let reasons: [Reason]
  let input: Input
  let message: String

  init(
    answers: DesignScopeAnswers, facts: DesignScopeGraphFacts,
    recommendation: DesignScopeRecommendation
  ) {
    self.input = Input(answers: answers, derived: facts)
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
/// testable without going through argument parsing or stdout. Loads the module graph through the
/// same adapters `arch` uses (`ConfigLoader`, `ModuleGraphLoader`) — no second loader — so the
/// counts `DesignScope.deriveFacts` computes are checked against the repository's real modules,
/// never hand-counted by whatever wrote the frame-answers file.
enum DesignScopeRun {
  enum Outcome: Sendable, Equatable {
    case recommended(DesignScopeReport)
    case failed(message: String)
  }

  static func run(frameAnswersPath: String?, root: URL, swiftPM: any SwiftPM) async -> Outcome {
    guard let frameAnswersPath else {
      return .failed(message: "missing required option '--frame-answers <path>'")
    }
    let data: Data
    do {
      data = try Data(contentsOf: URL(filePath: frameAnswersPath))
    } catch {
      return .failed(message: "can't read `\(frameAnswersPath)`: \(error.localizedDescription)")
    }
    let answers: DesignScopeAnswers
    do {
      answers = try DesignScopeInputJSON.decode(data)
    } catch {
      return .failed(
        message: "`\(frameAnswersPath)` is not a valid frame-answers file: \(error)")
    }

    let config: Config
    switch StaticCheckInputs.loadConfig(root: root) {
    case .success(let loaded?):
      config = loaded
    case .success(nil):
      return .failed(
        message: "no \(ConfigLoader.fileName): design-scope needs the module graph")
    case .failure(let failure):
      return .failed(message: configFailureMessage(failure.outcome))
    }

    let graph: ModuleGraph
    do {
      graph = try await ModuleGraphLoader(swiftPM: swiftPM, root: root).load(config: config)
    } catch {
      return .failed(message: "can't load the module graph: \(error)")
    }

    let facts: DesignScopeGraphFacts
    do {
      facts = try DesignScope.deriveFacts(answers: answers, graph: graph)
    } catch {
      return .failed(message: "\(error)")
    }

    return .recommended(
      DesignScopeReport(
        answers: answers, facts: facts, recommendation: DesignScope.recommend(facts)))
  }

  private static func configFailureMessage(_ outcome: StaticCheckOutcome) -> String {
    switch outcome {
    case .blocked(let reason): reason
    case .invalid(let reason, _): reason
    case .checked: "\(ConfigLoader.fileName) could not be loaded"
    }
  }
}

struct DesignScopeCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "design-scope",
    abstract: "Recommend a design depth tier (quick/standard/deep) from frame answers.",
    discussion:
      "Reads a frame-answers JSON file: {schemaVersion: 1, touchedModules: [String], "
      + "newModules: [{name, kind}] (kind is a ModuleKind raw value), newDependencies: "
      + "[String]}, written by the design skill's frame step. design-scope loads the "
      + "repository's module graph itself (the same ConfigLoader/ModuleGraphLoader arch uses) "
      + "and derives modulesAdded, modulesTouched, addsModuleKind and addsDependency from it — "
      + "the frame answers name modules, they never count them. Deep when the design adds a "
      + "dependency and a module kind together, adds 2 or more modules, or touches 4 or more "
      + "(a client/live or core/UI pair counts once) "
      + "modules (spec §8.1 Decisions; fixed thresholds, not config). Quick only when it adds "
      + "neither a dependency nor a module kind; everything else is standard. Exit 0 with the "
      + "recommendation whatever the tier. Exit 2 — and no recommendation — when "
      + "--frame-answers is missing, unreadable, not valid JSON, on an unsupported "
      + "schemaVersion, names an unrecognised module kind, names a touched module the graph "
      + "doesn't have, names a new module the graph already has, or repeats a module name, or "
      + "when the module graph itself can't be loaded (missing .swiftgate.toml, a bad config, "
      + "or a SwiftPM failure).")

  @Option(name: .customLong("frame-answers"), help: "Path to the frame-answers JSON file.")
  var frameAnswers: String?

  @OptionGroup var output: OutputOptions

  func run() async throws {
    let root = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    let outcome = await DesignScopeRun.run(
      frameAnswersPath: frameAnswers, root: root, swiftPM: ScopeResolution.liveSwiftPM(root: root))
    switch outcome {
    case .recommended(let report):
      Console.write(DesignScopeReport.render(report, format: output.format))
    case .failed(let message):
      FileHandle.standardError.write(Data("swiftgate design-scope: \(message)\n".utf8))
      throw ExitCode(Verdict.blocked.exitCode)
    }
  }
}
