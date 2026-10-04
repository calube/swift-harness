import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain

/// `judge diff-risk`: how much review the change since a base needs (design §11.5).
enum JudgeDiffRiskRun {
  enum Outcome: Sendable, Equatable {
    case rated(DiffRiskVerdict)
    /// No level, and why: never a default level.
    case noAnswer(String)
  }

  /// Rates the change from the merge base of `HEAD` and `base` to the working tree. A path
  /// matching `sensitive` is `high` without asking `judge`.
  static func run(
    base: String, git: any Git, diff: any DiffReading, sensitive: [String],
    judge: BrownfieldJudge?
  ) async -> Outcome {
    let change: DiffRiskChange
    do throws(GitError) {
      guard let mergeBase = try await git.mergeBase("HEAD", base) else {
        return .noAnswer("HEAD and \(base) share no history, so there is no change to rate")
      }
      change = DiffRiskChange(
        id: "diff-risk:\(mergeBase)", paths: try await git.changedFiles(since: mergeBase),
        diff: try await diff.unifiedDiff(since: mergeBase))
    } catch {
      return .noAnswer("git: \(error)")
    }
    guard let judge else {
      if let verdict = DiffRisk.sensitive(change.paths, globs: sensitive) {
        return .rated(verdict)
      }
      return .noAnswer(BrownfieldJudge.notConfigured)
    }
    let verdict: DiffRiskVerdict
    do throws(JudgeClassificationError) {
      verdict = try await DiffRisk.classify(change, sensitive: sensitive) { subject, questions in
        try await judge.ask(subject, questions, questions)
      }
    } catch {
      switch error {
      case .noAnswer(let why): return .noAnswer("the judge gave no answer: \(why)")
      case .unreadable(let why):
        return .noAnswer("the judge's answer doesn't read as a level: \(why)")
      }
    }
    return .rated(verdict)
  }

  /// The printed text and the exit status: 0 with a level, 1 without one. `--json` prints
  /// `{"level": "low"|"medium"|"high", "by": "judge"}`,
  /// `{"level": "high", "by": "sensitive", "path": …, "glob": …}` or `{"level": null, "reason": …}`.
  static func render(_ outcome: Outcome, json: Bool) -> (text: String, status: Int32) {
    let status: Int32 =
      switch outcome {
      case .rated: 0
      case .noAnswer: 1
      }
    guard json else {
      switch outcome {
      case .rated(.sensitive(let path, let glob)):
        return ("diff-risk: high: \(path) matches the sensitive glob \(glob)", status)
      case .rated(.judged(let level)):
        return ("diff-risk: \(level.rawValue), as the judge rated it", status)
      case .noAnswer(let why):
        return ("diff-risk: no level: \(why)", status)
      }
    }
    let object: [String: Any] =
      switch outcome {
      case .rated(.sensitive(let path, let glob)):
        ["level": DiffRiskLevel.high.rawValue, "by": "sensitive", "path": path, "glob": glob]
      case .rated(.judged(let level)): ["level": level.rawValue, "by": "judge"]
      case .noAnswer(let why): ["level": NSNull(), "reason": why]
      }
    guard
      let data = try? JSONSerialization.data(
        withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    else { return ("{\"level\":null,\"reason\":\"the answer didn't encode\"}", 1) }
    return (String(decoding: data, as: UTF8.self), status)
  }

  /// The clone's sensitive globs and judge: a brownfield config's `[brownfield] sensitive` and
  /// `[judge]`, or an owned config's `[judge]` with no sensitive globs.
  static func settings(root: URL) -> Result<(sensitive: [String], judge: JudgeConfig), Failure> {
    guard let common = ConfigLoader.commonDirectory(enclosing: root) else {
      return .failure(Failure("\(root.path) is not in a git checkout"))
    }
    do throws(ProfileLoadError) {
      switch try ConfigLoader().loadProfile(repositoryRoot: root, commonDir: common) {
      case .brownfield(let config)?: return .success((config.brownfield.sensitive, config.judge))
      case .owned(let config)?: return .success(([], config.judge))
      case nil: return .failure(Failure("no swift-harness config here"))
      }
    } catch {
      return .failure(Failure("the config can't be read: \(error)"))
    }
  }

  struct Failure: Error {
    let reason: String
    init(_ reason: String) { self.reason = reason }
  }
}

struct JudgeDiffRiskCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "diff-risk",
    abstract: "Rate how much review the change since --base needs: low, medium or high.",
    discussion:
      "Rates the change from the merge base of HEAD and --base to the working tree. A path "
      + "matching 1 of the brownfield config's [brownfield] sensitive globs rates high without "
      + "asking the judge; otherwise the [judge] cascade answers the diff-risk question set (Jev, "
      + "once more after a transport error, then Claude). No answer is never a level. --json "
      + "prints {\"level\": \"low\"|\"medium\"|\"high\", \"by\": \"judge\"|\"sensitive\"} (with "
      + "\"path\" and \"glob\" for sensitive) or {\"level\": null, \"reason\": …}. Exit 0 with a "
      + "level; 1 when no judge is configured or none answered; 2 outside a project or for a "
      + "config that doesn't load.")

  @Option(help: "The change is measured from the merge base of HEAD and this ref.")
  var base: String

  @OptionGroup var output: OutputOptions

  func run() async throws {
    let root = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    let settings: (sensitive: [String], judge: JudgeConfig)
    switch JudgeDiffRiskRun.settings(root: root) {
    case .success(let found): settings = found
    case .failure(let failure):
      Console.write(JudgeDiffRiskRun.render(.noAnswer(failure.reason), json: output.json).text)
      throw ExitCode(2)
    }
    let git = LiveGit(runner: LiveProcessRunner(), repositoryRoot: root.path)
    let outcome = await JudgeDiffRiskRun.run(
      base: base, git: git, diff: git, sensitive: settings.sensitive,
      judge: BrownfieldJudge.live(settings.judge, root: root))
    let (text, status) = JudgeDiffRiskRun.render(outcome, json: output.json)
    Console.write(text)
    if status != 0 { throw ExitCode(status) }
  }
}
