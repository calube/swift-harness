import Foundation
import SwiftGateDomain

/// The device a final-pass flow ran on, as the logs name it.
public struct QAEvidenceDevice: Sendable, Equatable {
  public var target: AgentDeviceTarget
  public var bundleID: String
  /// When `sim up` started the run; the unified log is read from here on.
  public var since: Date

  public init(target: AgentDeviceTarget, bundleID: String, since: Date) {
    self.target = target
    self.bundleID = bundleID
    self.since = since
  }
}

/// What 1 flow's logs left: run-relative paths, and why any kind wasn't saved.
public struct QAEvidenceCollection: Sendable, Equatable {
  public var files: [String]
  public var gaps: [QAEvidenceKind: String]

  public init(files: [String] = [], gaps: [QAEvidenceKind: String] = [:]) {
    self.files = files
    self.gaps = gaps
  }
}

/// Saves a final-pass flow's logs under `qa/logs/<flow>/`: the session app log and the network
/// dump parsed from it, the `agent-device` trace, the unified log for the app's subsystem, and the
/// app's data container.
public struct EvidenceCollector: Sendable {
  /// The `qa/` folder's subfolder for logs.
  public static let directory = "logs"
  public static let networkLimit = 25
  public static let appLogFileName = "app.log"
  public static let networkFileName = "network.json"
  public static let traceFileName = "trace.log"
  public static let osLogFileName = "os.log"
  public static let containerDirectory = "container"

  private let agentDevice: any AgentDevice
  private let runner: any ProcessRunner

  public init(agentDevice: any AgentDevice, runner: any ProcessRunner) {
    self.agentDevice = agentDevice
    self.runner = runner
  }

  /// Starts the app log stream and the trace, runs `flow`, then saves every kind.
  ///
  /// - Parameters:
  ///   - directory: this flow's logs folder.
  ///   - relativeDirectory: `directory` relative to the run directory.
  public func collect<Outcome: Sendable>(
    on device: QAEvidenceDevice, directory: URL, relativeDirectory: String,
    _ flow: @Sendable () async -> Outcome
  ) async -> (outcome: Outcome, collection: QAEvidenceCollection) {
    let target = device.target
    var gaps: [QAEvidenceKind: String] = [:]
    var saved: Set<QAEvidenceKind> = []
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    } catch {
      let outcome = await flow()
      let reason = "making \(relativeDirectory): \(error)"
      return (
        outcome,
        QAEvidenceCollection(
          gaps: Dictionary(uniqueKeysWithValues: Self.logKinds.map { ($0, reason) }))
      )
    }

    var streaming = true
    do {
      try await agentDevice.logStream(.start, on: target)
    } catch {
      streaming = false
      gaps[.appLog] = "logs start: \(error.message)"
      gaps[.network] = "logs start: \(error.message)"
    }
    let trace = directory.appending(path: Self.traceFileName)
    var tracing = true
    do {
      try await agentDevice.trace(.start, path: trace.path, on: target)
    } catch {
      tracing = false
      gaps[.trace] = "trace start: \(error.message)"
    }

    let outcome = await flow()

    if tracing {
      do {
        try await agentDevice.trace(.stop, path: trace.path, on: target)
        if FileManager.default.fileExists(atPath: trace.path) {
          saved.insert(.trace)
        } else {
          gaps[.trace] = "trace stop wrote no \(Self.traceFileName)"
        }
      } catch {
        gaps[.trace] = "trace stop: \(error.message)"
      }
    }
    if streaming {
      do {
        try await agentDevice.logStream(.stop, on: target)
        let log = try await agentDevice.logs(on: target)
        try Self.copy(URL(filePath: log), to: directory.appending(path: Self.appLogFileName))
        saved.insert(.appLog)
      } catch let error as AgentDeviceError {
        gaps[.appLog] = "logs: \(error.message)"
      } catch {
        gaps[.appLog] = "copying the app log: \(error)"
      }
      do {
        let dump = try await agentDevice.networkDump(limit: Self.networkLimit, on: target)
        try QAFiles.write(dump, to: directory.appending(path: Self.networkFileName))
        saved.insert(.network)
      } catch let error as AgentDeviceError {
        gaps[.network] = "network dump: \(error.message)"
      } catch {
        gaps[.network] = "writing the network dump: \(error)"
      }
    }
    switch await osLog(device) {
    case .success(let text):
      do {
        try QAFiles.write(text, to: directory.appending(path: Self.osLogFileName))
        saved.insert(.osLog)
      } catch {
        gaps[.osLog] = "writing the unified log: \(error)"
      }
    case .failure(let why):
      gaps[.osLog] = why.reason
    }
    switch await container(device) {
    case .success(let path):
      do {
        try Self.copy(
          URL(filePath: path, directoryHint: .isDirectory),
          to: directory.appending(path: Self.containerDirectory, directoryHint: .isDirectory))
        saved.insert(.container)
      } catch {
        gaps[.container] = "copying the data container: \(error)"
      }
    case .failure(let why):
      gaps[.container] = why.reason
    }

    let files = Self.logKinds.filter(saved.contains).map {
      "\(relativeDirectory)/\(Self.fileName($0))"
    }
    return (outcome, QAEvidenceCollection(files: files, gaps: gaps))
  }

  /// The kinds this collector saves, in the order their paths are listed.
  static let logKinds: [QAEvidenceKind] = [.appLog, .network, .trace, .osLog, .container]

  static func fileName(_ kind: QAEvidenceKind) -> String {
    switch kind {
    case .appLog: appLogFileName
    case .network: networkFileName
    case .trace: traceFileName
    case .osLog: osLogFileName
    case .container: containerDirectory
    case .video: FinalPassRecorder.videoFileName
    case .sheet: FinalPassRecorder.sheetFileName
    }
  }

  struct Unsaved: Error {
    let reason: String
  }

  /// `log show` for the app's subsystem, which apps name after their bundle id, since `sim up`.
  private func osLog(_ device: QAEvidenceDevice) async -> Result<Data, Unsaved> {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let arguments = [
      "simctl", "spawn", device.target.udid, "log", "show", "--style", "compact", "--info",
      "--debug", "--predicate", "subsystem == \"\(device.bundleID)\"", "--start",
      formatter.string(from: device.since),
    ]
    switch await xcrun(arguments) {
    case .success(let output): return .success(output.stdout.bytes)
    case .failure(let why): return .failure(Unsaved(reason: "log show: \(why.reason)"))
    }
  }

  private func container(_ device: QAEvidenceDevice) async -> Result<String, Unsaved> {
    let arguments = ["simctl", "get_app_container", device.target.udid, device.bundleID, "data"]
    switch await xcrun(arguments) {
    case .success(let output):
      let path = output.stdout.text.trimmingCharacters(in: .whitespacesAndNewlines)
      return path.isEmpty
        ? .failure(Unsaved(reason: "get_app_container printed no path")) : .success(path)
    case .failure(let why): return .failure(Unsaved(reason: "get_app_container: \(why.reason)"))
    }
  }

  private func xcrun(_ arguments: [String]) async -> Result<ProcessOutput, Unsaved> {
    let output: ProcessOutput
    do {
      output = try await runner.run(
        ProcessInvocation(executable: "xcrun", arguments: arguments, timeout: .seconds(120)))
    } catch {
      return .failure(Unsaved(reason: "\(error)"))
    }
    guard output.status.isSuccess else {
      let stderr = output.stderr.text.split(whereSeparator: \.isNewline).prefix(2)
      return .failure(Unsaved(reason: "\(output.status): \(stderr.joined(separator: " "))"))
    }
    return .success(output)
  }

  /// Copies a file or a folder, replacing what is there.
  private static func copy(_ source: URL, to destination: URL) throws {
    let files = FileManager.default
    if files.fileExists(atPath: destination.path) { try files.removeItem(at: destination) }
    try files.copyItem(at: source, to: destination)
  }
}
