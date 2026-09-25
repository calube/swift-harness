import CryptoKit
import Foundation
import SwiftGateDomain

/// Runs one command as a real process, argv only (spec §6.1 `evidence capture -- <cmd>`): the
/// executable and arguments reach `posix_spawn` verbatim through ``ProcessRunner``, so nothing in
/// them is ever interpreted by a shell. Stores stdout, stderr and the exit status under
/// `captures/`, named by their own content hash, and hands back the `capture` citation (spec
/// §5.2) that points at the stored file.
public enum EvidenceCapture {
  public struct Outcome: Sendable, Equatable {
    public let citation: Citation
    /// Repo-relative path to the stored capture file (`<layout.capturesDirectory>/<sha256>.txt`).
    public let capturePath: String
    /// The captured command's real process status: `.exited(code)` or `.signaled(signal)`. A
    /// capture always has one once it succeeds, so it's never a placeholder value.
    public let status: ExitStatus
    public let stdout: String
    public let stderr: String
  }

  public enum Failure: Sendable, Equatable, Error {
    case emptyCommand
    case process(String)
    case io(String)
  }

  /// - Parameters:
  ///   - argv: the exact argv, executable first. Passed straight to ``ProcessRunner``.
  ///   - evidenceRoot: the on-disk directory the capture file is written into.
  ///   - repoRelativeCapturesDirectory: the same directory, repo-relative, used only for
  ///     ``Outcome/capturePath`` (printed for a human, never used as the citation's `loc`).
  ///   - workingDirectory: the captured command's own working directory, or `nil` to inherit the
  ///     runner's.
  public static func run(
    argv: [String], evidenceRoot: URL, repoRelativeCapturesDirectory: String,
    workingDirectory: String? = nil, runner: any ProcessRunner, timeout: Duration = .seconds(300)
  ) async -> Result<Outcome, Failure> {
    guard let executable = argv.first, !executable.isEmpty else { return .failure(.emptyCommand) }

    let output: ProcessOutput
    do {
      output = try await runner.run(
        ProcessInvocation(
          executable: executable, arguments: Array(argv.dropFirst()),
          workingDirectory: workingDirectory, timeout: timeout))
    } catch {
      return .failure(.process(describe(error)))
    }

    let stdout = output.stdout.text
    let stderr = output.stderr.text
    let bytes = serialize(argv: argv, status: output.status, stdout: stdout, stderr: stderr)
    let hash = hex(bytes)
    let fileName = "\(hash).txt"

    do {
      try FileManager.default.createDirectory(at: evidenceRoot, withIntermediateDirectories: true)
      try bytes.write(to: evidenceRoot.appending(path: fileName), options: .atomic)
    } catch {
      return .failure(.io("can't write `\(fileName)`: \(error.localizedDescription)"))
    }

    // The citation's loc is evidence-root-relative (spec §5.2: the checker resolves
    // snapshot/capture/probe/answer locs against <slug>.evidence/), never the repo-relative path
    // — the capture directory is always named `captures` directly under that root.
    let citation = Citation(kind: .capture, loc: "captures/" + fileName, pin: "sha256:\(hash)")
    let capturePath = repoRelativeCapturesDirectory + "/" + fileName
    return .success(
      Outcome(
        citation: citation, capturePath: capturePath, status: output.status, stdout: stdout,
        stderr: stderr))
  }

  /// A deterministic, human-readable rendering of one run. Hashed verbatim, so the same argv,
  /// exit and streams always produce the same file — the mechanical `capture` check (spec §5.2)
  /// re-hashes exactly these bytes.
  private static func serialize(
    argv: [String], status: ExitStatus, stdout: String, stderr: String
  ) -> Data {
    var text = "$ " + argv.joined(separator: " ") + "\n"
    text += "exit: \(describe(status))\n"
    text += "\n--- stdout ---\n" + stdout
    if !stdout.isEmpty, !stdout.hasSuffix("\n") { text += "\n" }
    text += "\n--- stderr ---\n" + stderr
    if !stderr.isEmpty, !stderr.hasSuffix("\n") { text += "\n" }
    return Data(text.utf8)
  }

  private static func describe(_ status: ExitStatus) -> String {
    switch status {
    case .exited(let code): "exited \(code)"
    case .signaled(let signal): "signaled \(signal)"
    }
  }

  private static func describe(_ error: ProcessRunnerError) -> String {
    switch error {
    case .launchFailed(let executable, let reason): "`\(executable)` failed to launch: \(reason)"
    case .timedOut(let executable, let after, _, _):
      "`\(executable)` timed out after \(after)"
    case .cancelled(let executable): "`\(executable)` was cancelled"
    }
  }

  private static func hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
