import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain

extension BuildHaltReason: ExpressibleByArgument {}
extension BuildResumeAnswer: ExpressibleByArgument {}

/// `build halt` and `build resume` against 1 checkout's store, with the config already read.
enum BuildHaltRun {
  /// What a halt or resume prints and exits with.
  struct Output: Equatable {
    let stdout: String
    let stderr: String
    let status: Int32
  }

  /// - Parameters:
  ///   - enabled: `.swiftgate.toml`'s `[telemetry] enabled`; `false` records nothing.
  static func halt(
    log: BuildHaltLog, enabled: Bool, buildRun: String, task: String?, reason: BuildHaltReason,
    json: Bool
  ) -> Output {
    let command = "build halt"
    if let refusal = refusal(command, buildRun: buildRun, task: task, enabled: enabled) {
      return refusal
    }
    do throws(BuildHaltLogError) {
      let event = try log.halt(buildRun: buildRun, task: task, reason: reason)
      return recorded(
        event, json: json,
        message: "\(command): recorded \(reason.rawValue) for \(scope(buildRun, task)), halt "
          + event.eventID)
    } catch {
      return failed(command, error)
    }
  }

  static func resume(
    log: BuildHaltLog, enabled: Bool, buildRun: String, task: String?,
    answer: BuildResumeAnswer, json: Bool
  ) -> Output {
    let command = "build resume"
    if let refusal = refusal(command, buildRun: buildRun, task: task, enabled: enabled) {
      return refusal
    }
    do throws(BuildHaltLogError) {
      let event = try log.resume(buildRun: buildRun, task: task, answer: answer)
      let waited: String =
        switch event.payload {
        case .buildResume(let resume): " after \(resume.waitMilliseconds) ms"
        default: ""
        }
      return recorded(
        event, json: json,
        message: "\(command): recorded \(answer.rawValue) for \(scope(buildRun, task))\(waited), "
          + "answering halt \(event.parentID ?? "none")")
    } catch {
      return failed(command, error)
    }
  }

  private static func scope(_ buildRun: String, _ task: String?) -> String {
    "build run \(buildRun)" + (task.map { ", task \($0)" } ?? "")
  }

  /// Ids land in the payload, so each must be a plain id: no path, space or newline.
  private static func refusal(_ command: String, buildRun: String, task: String?, enabled: Bool)
    -> Output?
  {
    if !RunID.isValid(buildRun) {
      return Output(
        stdout: "", stderr: "swiftgate \(command): --run \(buildRun) is not a build run id\n",
        status: 2)
    }
    if let task, !RunID.isValid(task) {
      return Output(
        stdout: "", stderr: "swiftgate \(command): --task \(task) is not a task id\n", status: 2)
    }
    if !enabled {
      return Output(
        stdout: "",
        stderr: "swiftgate \(command): telemetry is off in .swiftgate.toml; nothing recorded\n",
        status: 0)
    }
    return nil
  }

  private static func recorded(_ event: HarnessEvent, json: Bool, message: String) -> Output {
    guard json else { return Output(stdout: message, stderr: "", status: 0) }
    do {
      let line = try HarnessEventJSON.encodeLine(event)
      return Output(stdout: String(decoding: line.dropLast(), as: UTF8.self), stderr: "", status: 0)
    } catch {
      // The event is already written; only its echo failed.
      return Output(
        stdout: message, stderr: "swiftgate: could not print the event as JSON: \(error)\n",
        status: 0)
    }
  }

  private static func failed(_ command: String, _ error: BuildHaltLogError) -> Output {
    switch error {
    case .noOpenHalt:
      Output(stdout: "", stderr: "swiftgate \(command): \(error); nothing recorded\n", status: 1)
    case .unreadable, .unwritten:
      Output(stdout: "", stderr: "swiftgate \(command): not recorded: \(error)\n", status: 2)
    }
  }

  /// The main checkout's root and whether its config keeps events: halts are written where the
  /// orchestrator runs, whichever worktree the command starts in.
  enum Store {
    case found(root: URL, enabled: Bool)
    case refused(Output)
  }

  /// - Parameter directory: any checkout of the repository; the command's own by default.
  static func store(
    command: String, directory: String = FileManager.default.currentDirectoryPath
  ) async -> Store {
    func refused(_ why: String) -> Output {
      Output(stdout: "", stderr: "swiftgate \(command): \(why)\n", status: 2)
    }
    let root: URL
    do {
      let common = try await LiveGit(runner: LiveProcessRunner(), repositoryRoot: directory)
        .commonDirectory()
      root = URL(
        filePath: try TaskWorktree.mainCheckout(commonDirectory: common),
        directoryHint: .isDirectory)
    } catch {
      return .refused(refused("can't find the main checkout: \(error)"))
    }
    do throws(ConfigLoadError) {
      // No `.swiftgate.toml` is a repo the harness doesn't run in: nothing to record.
      let config = try ConfigLoader().load(repositoryRoot: root)
      return .found(root: root, enabled: config?.telemetry.enabled ?? false)
    } catch {
      return .refused(refused("reading \(ConfigLoader.fileName): \(error)"))
    }
  }

  static func finish(_ output: Output) throws {
    if !output.stderr.isEmpty { FileHandle.standardError.write(Data(output.stderr.utf8)) }
    if !output.stdout.isEmpty { Console.write(output.stdout) }
    if output.status != 0 { throw ExitCode(output.status) }
  }
}

struct BuildHaltCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "halt",
    abstract: "Record that a build run stopped to ask a person, and why.",
    discussion:
      "Writes build.halt to the main checkout's .harness/events/build.jsonl: the build run, the "
      + "task and the reason, never the question's text. A halt no resume answers stays open. "
      + "Exit 0 recorded, or nothing to record with [telemetry] enabled = false; 2 for a --run "
      + "or --task that isn't an id, or a store that can't be read or written; 64 for an "
      + "unknown --reason.")

  @Option(name: .customLong("run"), help: "The build run id that `build start` printed.")
  var buildRun: String

  @Option(help: "The task the halt is about; leave it out for a halt of the whole run.")
  var task: String?

  @Option(help: "Why the build stopped.")
  var reason: BuildHaltReason

  @OptionGroup var output: OutputOptions

  func run() async throws {
    switch await BuildHaltRun.store(command: "build halt") {
    case .refused(let refused): try BuildHaltRun.finish(refused)
    case .found(let root, let enabled):
      try BuildHaltRun.finish(
        BuildHaltRun.halt(
          log: BuildHaltLog(root: root), enabled: enabled, buildRun: buildRun,
          task: task, reason: reason, json: output.json))
    }
  }
}

struct BuildResumeCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "resume",
    abstract: "Record the answer to a build run's newest open halt and how long it waited.",
    discussion:
      "Finds the newest halt of the same build run and task that no resume answered, and writes "
      + "build.resume with that halt as its parent and waitMs from the halt's time to now. Halts "
      + "and resumes hold 1 lock, so 2 resumes never answer 1 halt. Exit 0 recorded, or nothing "
      + "to record with [telemetry] enabled = false; 1 when no halt is open for the run and task, "
      + "writing nothing; 2 for a --run or --task that isn't an id, or a store that can't be read "
      + "or written; 64 for an unknown --answer.")

  @Option(name: .customLong("run"), help: "The build run id the halt named.")
  var buildRun: String

  @Option(help: "The task the halt named; leave it out for a halt of the whole run.")
  var task: String?

  @Option(help: "What the person answered.")
  var answer: BuildResumeAnswer

  @OptionGroup var output: OutputOptions

  func run() async throws {
    switch await BuildHaltRun.store(command: "build resume") {
    case .refused(let refused): try BuildHaltRun.finish(refused)
    case .found(let root, let enabled):
      try BuildHaltRun.finish(
        BuildHaltRun.resume(
          log: BuildHaltLog(root: root), enabled: enabled, buildRun: buildRun,
          task: task, answer: answer, json: output.json))
    }
  }
}
