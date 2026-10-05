import Darwin
import Foundation
import SwiftGateDomain

/// The saved ``ViewServerRecord`` of 1 repository, in its git common dir.
public struct ViewServerRegistry: Sendable {
  public let file: URL

  /// Where the detached server's output goes.
  public let log: URL

  public init(commonDirectory: URL) {
    let directory = commonDirectory.appending(
      path: RunLayout.gitDirDirectory, directoryHint: .isDirectory)
    file = directory.appending(path: ViewServerRecord.fileName)
    log = directory.appending(path: ViewServerRecord.logName)
  }

  /// `nil` when there is none or it doesn't decode.
  public func read() -> ViewServerRecord? {
    guard let data = try? Data(contentsOf: file) else { return nil }
    return try? ViewServerRecord.decode(data)
  }

  /// Replaces the record through a temporary file, so a reader never sees half of it.
  public func write(_ record: ViewServerRecord) throws {
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try record.encoded().write(to: file, options: .atomic)
  }
}

/// Stops a repository's detached viewer server once its run is over: the final report is a
/// static page by then, so nothing needs the server.
public struct ViewServerShutdown: Sendable {
  public let registry: ViewServerRegistry
  public let probe: any ViewServerProbing
  /// Sends the server its stop signal; `false` when it couldn't be sent.
  public let signal: @Sendable (Int32) -> Bool

  public init(
    registry: ViewServerRegistry, probe: any ViewServerProbing,
    signal: @escaping @Sendable (Int32) -> Bool = { kill($0, SIGTERM) == 0 }
  ) {
    self.registry = registry
    self.probe = probe
    self.signal = signal
  }

  /// Stops the saved server when it still answers as itself; returns its record, or `nil` when
  /// no saved server answers or the signal couldn't be sent.
  public func stop() async -> ViewServerRecord? {
    nil
  }
}

/// Whether a saved server still answers as itself.
public protocol ViewServerProbing: Sendable {
  func answers(_ record: ViewServerRecord) async -> Bool
}

/// `view --ensure`: reuses the repository's viewer server when it still answers, or starts a
/// detached one and waits until it saves its record.
public struct ViewServerEnsurer: Sendable {
  public enum Outcome: Sendable, Equatable {
    case off
    case reused(ViewServerRecord)
    case started(ViewServerRecord)
  }

  public struct Failure: Error, Sendable, Equatable, CustomStringConvertible {
    public let description: String

    public init(_ description: String) { self.description = description }
  }

  public let registry: ViewServerRegistry
  public let probe: any ViewServerProbing
  public let launcher: any DetachedLaunching
  /// How long a started server has to save its record.
  public let startDeadline: Duration
  /// Stands in for the clock in a test; `nil` sleeps.
  public let wait: (@Sendable (Duration) async throws -> Void)?

  public init(
    registry: ViewServerRegistry, probe: any ViewServerProbing, launcher: any DetachedLaunching,
    startDeadline: Duration = .seconds(20),
    wait: (@Sendable (Duration) async throws -> Void)? = nil
  ) {
    self.registry = registry
    self.probe = probe
    self.launcher = launcher
    self.startDeadline = startDeadline
    self.wait = wait
  }

  /// - Parameters:
  ///   - switchValue: `SWIFTGATE_VIEW`'s value.
  ///   - serve: the arguments that run a detached server; the saved port follows as `--port`.
  /// - Throws: ``Failure`` when the server can't start or saves no record in time.
  public func ensure(
    switchValue: String?, executable: String, serve: [String], directory: String
  ) async throws -> Outcome {
    if ViewServerSwitch.isOff(switchValue) { return .off }
    let saved = registry.read()
    let answering: Bool
    if let saved { answering = await probe.answers(saved) } else { answering = false }
    switch ViewEnsureDecision.decide(switchValue: switchValue, record: saved, answering: answering)
    {
    case .off:
      return .off
    case .reuse(let record):
      return .reused(record)
    case .start(let preferredPort):
      let pid = try launch(
        executable: executable,
        arguments: serve + (preferredPort.map { ["--port", "\($0)"] } ?? []),
        directory: directory)
      guard let record = await savedRecord(of: pid) else {
        throw Failure(
          "the viewer server (pid \(pid)) saved no address within \(startDeadline); its output is in \(ViewServerRecord.logName) beside the plans directory"
        )
      }
      return .started(record)
    }
  }

  /// Starts the server with its output going to the registry's log; returns its pid.
  private func launch(executable: String, arguments: [String], directory: String) throws -> Int32
  {
    do {
      try FileManager.default.createDirectory(
        at: registry.log.deletingLastPathComponent(), withIntermediateDirectories: true)
    } catch {
      throw Failure("\(ViewServerRecord.logName)'s directory can't be made")
    }
    let launched = Result { () throws(DetachedLaunchError) -> Int32 in
      try launcher.launch(
        DetachedLaunch(
          executable: executable, arguments: arguments, workingDirectory: directory,
          logPath: registry.log.path))
    }
    switch launched {
    case .success(let pid): return pid
    case .failure(let error): throw Failure(error.message)
    }
  }

  /// The record `pid` saved, read every 100 ms until ``startDeadline``; `nil` when none came.
  private func savedRecord(of pid: Int32) async -> ViewServerRecord? {
    let step = Duration.milliseconds(100)
    var waited = Duration.zero
    while true {
      if let record = registry.read(), record.pid == pid { return record }
      if waited >= startDeadline { return nil }
      do {
        // A stored async closure that sleeps aborts the process with "freed pointer was not the
        // last allocation", so the real sleep is called here, not through a default closure.
        if let wait { try await wait(step) } else { try await Task.sleep(for: step) }
      } catch {
        return nil
      }
      waited += step
    }
  }
}

/// ``ViewServerProbing`` over a live pid and the server's `/server` answer.
public struct LiveViewServerProbe: ViewServerProbing {
  public init() {}

  public func answers(_ record: ViewServerRecord) async -> Bool {
    guard record.pid > 1, kill(record.pid, 0) == 0,
      let url = URL(string: "\(record.url)server")
    else { return false }
    var request = URLRequest(url: url)
    request.timeoutInterval = 2
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 2
    let session = URLSession(configuration: configuration)
    defer { session.finishTasksAndInvalidate() }
    guard let (body, response) = try? await session.data(for: request),
      (response as? HTTPURLResponse)?.statusCode == 200,
      let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    else { return false }
    return (object["pid"] as? Int) == Int(record.pid)
  }
}

