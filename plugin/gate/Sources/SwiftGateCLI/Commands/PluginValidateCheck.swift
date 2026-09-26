import Foundation
import SwiftGateAdapters
import SwiftGateDomain

/// The ready tier's plugin check for a repository that ships a Claude Code plugin under `plugin/`
/// (ADR 0002): `claude plugin validate --strict --json plugin`. Strict, because the warnings the
/// runtime tolerates (a `CLAUDE.md` that never loads, an unknown manifest field) are exactly what
/// ships unnoticed. Without `claude` on `PATH`, or when it can't run, the step is a note, never
/// BLOCKED: a machine without Claude Code can still run every other gate.
enum PluginValidateCheck {
  static let failedRuleID = "plugin-validate.failed"
  static let notRunRuleID = "plugin-validate.not-run"
  static let summaryRuleID = "plugin-validate.summary"

  static let pluginDirectory = "plugin"
  static let manifestPath = "\(pluginDirectory)/.claude-plugin/plugin.json"
  static let arguments = ["plugin", "validate", "--strict", "--json", pluginDirectory]

  struct Environment: Sendable {
    let runner: any ProcessRunner
    /// The `PATH` searched for `claude`.
    let path: String
  }

  /// `claude plugin validate --json`'s report. Only what the gate reports is decoded.
  private struct Report: Decodable {
    struct Issue: Decodable {
      let path: String?
      let message: String
    }

    struct Entry: Decodable {
      let file: String
      let errors: [Issue]
      let warnings: [Issue]
    }

    let success: Bool
    let manifest: Entry
    let contents: [Entry]
  }

  static func run(root: URL, runner: any ProcessRunner, path: String)
    async throws(ReportContractViolation) -> [Finding]
  {
    guard FileManager.default.fileExists(atPath: root.appending(path: manifestPath).path) else {
      return []
    }
    guard HarnessFiles.isOnPath("claude", path: path) else {
      return [
        try finding(
          notRunRuleID, .nit, file: manifestPath,
          "claude plugin validate not run: claude is not on PATH, so \(pluginDirectory)/ is "
            + "unvalidated on this machine.")
      ]
    }
    let output: ProcessOutput
    do {
      output = try await runner.run(
        ProcessInvocation(
          executable: "claude", arguments: arguments, workingDirectory: root.path,
          timeout: .seconds(120)))
    } catch {
      return [
        try finding(
          notRunRuleID, .nit, file: manifestPath,
          "claude plugin validate not run: \(describe(error))")
      ]
    }
    guard let report = try? JSONDecoder().decode(Report.self, from: output.stdout.bytes) else {
      let printed = (output.stdout.text + output.stderr.text).trimmingCharacters(
        in: .whitespacesAndNewlines)
      return [
        try finding(
          failedRuleID, .major, file: manifestPath,
          "claude plugin validate (exit \(describe(output.status))) printed no validation "
            + "report: \(printed.isEmpty ? "(nothing)" : String(printed.prefix(400)))")
      ]
    }
    var findings: [Finding] = []
    for entry in [report.manifest] + report.contents {
      let file = relative(entry.file, root: root)
      for (kind, issues) in [("error", entry.errors), ("warning", entry.warnings)] {
        for issue in issues {
          let location = issue.path.map { "\($0): " } ?? ""
          findings.append(
            try finding(
              failedRuleID, .major, file: file,
              "claude plugin validate --strict \(kind): \(location)\(issue.message)"))
        }
      }
    }
    if findings.isEmpty, !report.success || !output.status.isSuccess {
      findings.append(
        try finding(
          failedRuleID, .major, file: manifestPath,
          "claude plugin validate reported failure (exit \(describe(output.status))) without "
            + "naming an error or warning."))
    }
    guard findings.isEmpty else { return findings }
    return [
      try finding(
        summaryRuleID, .nit, file: manifestPath,
        "claude plugin validate --strict: \(pluginDirectory)/ passed with no errors or warnings.")
    ]
  }

  private static func relative(_ file: String, root: URL) -> String {
    let prefix = CanonicalPath.of(root) + "/"
    let canonical = CanonicalPath.of(URL(filePath: file))
    if canonical.hasPrefix(prefix) { return String(canonical.dropFirst(prefix.count)) }
    return file.hasPrefix(root.path + "/") ? String(file.dropFirst(root.path.count + 1)) : file
  }

  private static func describe(_ status: ExitStatus) -> String {
    switch status {
    case .exited(let code): "\(code)"
    case .signaled(let signal): "signal \(signal)"
    }
  }

  private static func describe(_ error: ProcessRunnerError) -> String {
    switch error {
    case .launchFailed(let executable, let reason): "\(executable) couldn't launch: \(reason)"
    case .timedOut(let executable, let after, _, _): "\(executable) timed out after \(after)"
    case .cancelled(let executable): "\(executable) was cancelled"
    }
  }

  private static func finding(
    _ rule: String, _ severity: Severity, file: String, _ message: String
  ) throws(ReportContractViolation) -> Finding {
    try Finding(
      ruleID: rule, severity: severity, file: file, line: nil, message: message,
      failureScenario: nil)
  }
}
