import Foundation
import SwiftGateDomain

/// Adapter IO for `design-lint`: reading `claims.jsonl` and running `mmdc` (spec §5.3, §6.2).
/// Every classification decision — which fence belongs to which rule, which failure becomes which
/// finding — stays in `SwiftGateDomain`; this file only reads bytes and runs processes.

/// Loads a design's `claims.jsonl` (spec §5.2). `DesignLintClaims.load` never guesses a claim from
/// a missing or corrupt file: the caller sees exactly what was found, so it can tell "no evidence
/// file yet" from "an empty one" from "some lines wouldn't parse."
public enum DesignLintClaims {
  public struct Loaded: Sendable, Equatable {
    /// `nil` when `claims.jsonl` doesn't exist at all — distinct from an existing, empty file.
    public let claims: [Claim]?
    /// Lines present in the file that failed to decode as a ``Claim`` (``ClaimJSON/decode(_:)``
    /// counts them rather than failing the whole read).
    public let invalidLineCount: Int

    public init(claims: [Claim]?, invalidLineCount: Int) {
      self.claims = claims
      self.invalidLineCount = invalidLineCount
    }
  }

  public static func load(claimsFileURL: URL) -> Loaded {
    guard let data = FileManager.default.contents(atPath: claimsFileURL.path) else {
      return Loaded(claims: nil, invalidLineCount: 0)
    }
    let decoded = ClaimJSON.decode(data)
    return Loaded(claims: decoded.claims, invalidLineCount: decoded.invalidLines)
  }
}

/// Whether `mmdc` (the Mermaid CLI) is reachable, and full Mermaid syntax validation through it.
/// `design-lint`'s own diagram rules (``DesignLintDiagrams``) only check that a fence declares a
/// known diagram type; this runs the real parser when it's available, and otherwise reports its
/// absence as one visible, non-gating note rather than staying silent about the gap (spec §5.3).
public enum MermaidValidation {
  /// One fence that failed `mmdc` validation. `index` is this fence's position among the mermaid
  /// fences under `heading`, so a message can locate it without a byte offset.
  public struct FenceFailure: Sendable, Equatable {
    public let heading: String
    public let index: Int
    public let diagnostic: String

    public init(heading: String, index: Int, diagnostic: String) {
      self.heading = heading
      self.index = index
      self.diagnostic = diagnostic
    }
  }

  public enum Outcome: Sendable, Equatable {
    /// `mmdc` isn't reachable on `PATH`; nothing was validated.
    case notOnPath
    /// `mmdc` ran against every fence; empty when all of them parsed.
    case validated([FenceFailure])
  }

  public static let defaultTimeout: Duration = .seconds(20)

  public static func validate(
    fences: [(heading: String, index: Int, source: String)], runner: any ProcessRunner,
    timeout: Duration = defaultTimeout
  ) async -> Outcome {
    guard await isOnPath(runner: runner, timeout: timeout) else { return .notOnPath }
    var failures: [FenceFailure] = []
    for fence in fences {
      guard let diagnostic = await validateOne(fence.source, runner: runner, timeout: timeout)
      else { continue }
      failures.append(
        FenceFailure(heading: fence.heading, index: fence.index, diagnostic: diagnostic))
    }
    return .validated(failures)
  }

  /// A launch failure means the executable couldn't be resolved on `PATH` at all — the one
  /// condition spec §5.3 calls "not on PATH." Any other outcome (it ran, even if `--version`
  /// itself failed; it timed out; it was cancelled) means something named `mmdc` is reachable, so
  /// per-fence validation proceeds and reports its own diagnostics.
  private static func isOnPath(runner: any ProcessRunner, timeout: Duration) async -> Bool {
    do throws(ProcessRunnerError) {
      _ = try await runner.run(
        ProcessInvocation(executable: "mmdc", arguments: ["--version"], timeout: timeout))
      return true
    } catch {
      switch error {
      case .launchFailed: return false
      case .timedOut, .cancelled: return true
      }
    }
  }

  /// `nil` on success; the diagnostic text otherwise. Each fence gets its own scratch directory,
  /// removed after the run, so parallel fences never race on the same input/output pair.
  private static func validateOne(_ source: String, runner: any ProcessRunner, timeout: Duration)
    async -> String?
  {
    let token = UUID().uuidString  // swiftgate:allow det.uuid-init — unique scratch directory
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "swiftgate-mmdc-\(token)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let input = directory.appending(path: "diagram.mmd", directoryHint: .notDirectory)
      let output = directory.appending(path: "diagram.svg", directoryHint: .notDirectory)
      try Data(source.utf8).write(to: input)
      let result = try await runner.run(
        ProcessInvocation(
          executable: "mmdc", arguments: ["-i", input.path, "-o", output.path],
          workingDirectory: directory.path, timeout: timeout))
      guard result.status.isSuccess else {
        let stderr = result.stderr.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return stderr.isEmpty ? "mmdc exited \(describe(result.status))" : stderr
      }
      return nil
    } catch {
      return "mmdc could not run: \(error)"
    }
  }

  private static func describe(_ status: ExitStatus) -> String {
    switch status {
    case .exited(let code): return "\(code)"
    case .signaled(let signal): return "signal \(signal)"
    }
  }
}
