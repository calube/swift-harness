import Darwin
import Foundation
import SwiftGateDomain

/// 1 brownfield gate in flight, as `<clone root>/gates/<pid>.json` records it while it runs.
public struct RunningGate: Sendable, Equatable, Codable {
  public let pid: Int32
  /// When the process started, in seconds since 1970, so a pid the system reused for another
  /// process is never taken for the gate.
  public let processStart: Double
  /// Absolute: the worktree the gate checks.
  public let toplevel: String
  public let tier: String
  public let startedAt: Date

  public init(pid: Int32, processStart: Double, toplevel: String, tier: String, startedAt: Date) {
    self.pid = pid
    self.processStart = processStart
    self.toplevel = toplevel
    self.tier = tier
    self.startedAt = startedAt
  }
}

/// The process table, behind a seam so a test's gate is a record and never a real process.
public protocol GateProcesses: Sendable {
  /// `pid`'s start time in seconds since 1970; `nil` when no such process runs.
  func startTime(of pid: Int32) -> Double?
  /// Ends `pid`, which as a swiftgate process ends every child's process tree on its way out.
  func terminate(_ pid: Int32) async
}

/// The brownfield gates in flight in a clone, 1 file per gate process.
public struct RunningGateRegistry: Sendable {
  public static let directoryName = "gates"

  public let directory: URL
  private let processes: any GateProcesses

  public init(directory: URL, processes: any GateProcesses = LiveGateProcesses()) {
    self.directory = directory
    self.processes = processes
  }

  /// `<clone root>/gates/`.
  public init(layout: BrownfieldStateLayout, processes: any GateProcesses = LiveGateProcesses()) {
    self.init(
      directory: layout.cloneRoot.appending(path: Self.directoryName, directoryHint: .isDirectory),
      processes: processes)
  }

  /// Records this process as a gate checking `toplevel`; `nil` when it can't, and the gate runs
  /// unrecorded.
  public func register(pid: Int32, toplevel: String, tier: CheckTier, now: Date) -> URL? {
    guard let start = processes.startTime(of: pid) else { return nil }
    let gate = RunningGate(
      pid: pid, processStart: start, toplevel: Self.canonical(toplevel), tier: tier.rawValue,
      startedAt: now)
    let record = directory.appending(path: "\(pid).json")
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try Self.encoder.encode(gate).write(to: record, options: .atomic)
    } catch {
      return nil
    }
    return record
  }

  public func unregister(_ record: URL) {
    try? FileManager.default.removeItem(at: record)
  }

  /// Every recorded gate whose process still runs, by pid. A record whose process ended, or
  /// whose pid now names a process that started at another time, is removed.
  public func running() -> [RunningGate] {
    let records =
      (try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil)) ?? []
    var gates: [RunningGate] = []
    for record in records where record.pathExtension == "json" {
      guard let data = try? Data(contentsOf: record),
        let gate = try? Self.decoder.decode(RunningGate.self, from: data),
        processes.startTime(of: gate.pid) == gate.processStart
      else {
        unregister(record)
        continue
      }
      gates.append(gate)
    }
    return gates.sorted { $0.pid < $1.pid }
  }

  /// Ends every running gate checking one of `toplevels`, and returns them.
  public func stop(in toplevels: [String]) async -> [RunningGate] {
    let wanted = Set(toplevels.map(Self.canonical))
    var stopped: [RunningGate] = []
    for gate in running() where wanted.contains(gate.toplevel) {
      await processes.terminate(gate.pid)
      unregister(directory.appending(path: "\(gate.pid).json"))
      stopped.append(gate)
    }
    return stopped
  }

  /// Symlinks resolved and no trailing slash, so `/var/…` and `/private/var/…` name 1 worktree.
  static func canonical(_ path: String) -> String {
    URL(filePath: path, directoryHint: .isDirectory).resolvingSymlinksInPath()
      .path(percentEncoded: false).trimmingSuffix("/")
  }

  private static var encoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }

  private static var decoder: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}

extension String {
  fileprivate func trimmingSuffix(_ suffix: String) -> String {
    count > suffix.count && hasSuffix(suffix) ? String(dropLast(suffix.count)) : self
  }
}

/// ``GateProcesses`` over `sysctl` and signals.
public struct LiveGateProcesses: GateProcesses {
  public init() {}

  /// How long a terminated gate gets to end its children and exit before it is killed.
  static let grace: Duration = .seconds(10)

  public func startTime(of pid: Int32) -> Double? {
    guard pid > 0 else { return nil }
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0,
      info.kp_proc.p_pid == pid
    else { return nil }
    let start = info.kp_proc.p_un.__p_starttime
    return Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000
  }

  /// SIGTERM, which a swiftgate process forwards to every child's process tree before it exits;
  /// SIGKILL if it hasn't exited within ``grace``.
  public func terminate(_ pid: Int32) async {
    guard let start = startTime(of: pid) else { return }
    kill(pid, SIGTERM)
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: Self.grace)
    while clock.now < deadline {
      guard startTime(of: pid) == start else { return }
      try? await Task.sleep(for: .milliseconds(200))
    }
    if startTime(of: pid) == start { kill(pid, SIGKILL) }
  }
}

/// What a run leaves behind once it cuts or undoes a task: gates still running in the task's
/// worktree, and scratch trees whose gate died before it could remove them.
public protocol RunLeftovers: Sendable {
  /// Ends every gate running in one of `worktrees`.
  func stopGates(in worktrees: [String]) async -> [RunningGate]
  /// Removes every scratch tree whose owning process has ended.
  func pruneScratchTrees() async -> ScratchWorktreeSweep
}

/// ``RunLeftovers`` for the clone holding `directory`.
public struct LiveRunLeftovers: RunLeftovers {
  private let directory: URL
  private let runner: any ProcessRunner

  public init(directory: URL, runner: any ProcessRunner = LiveProcessRunner()) {
    self.directory = directory
    self.runner = runner
  }

  public func stopGates(in worktrees: [String]) async -> [RunningGate] {
    guard let layout = try? await GitTrackedTree(runner: runner, directory: directory).stateLayout()
    else { return [] }
    let absolute = worktrees.map { worktree in
      worktree.hasPrefix("/")
        ? worktree : directory.appending(path: worktree).standardizedFileURL.path
    }
    return await RunningGateRegistry(layout: layout).stop(in: absolute)
  }

  /// A failure to list or remove is left in the sweep's failures: pruning never stops the caller.
  public func pruneScratchTrees() async -> ScratchWorktreeSweep {
    let scratch = LiveScratchWorktrees(runner: runner, repositoryRoot: directory.path)
    do {
      return try await scratch.sweepRegisteredOrphans()
    } catch {
      return ScratchWorktreeSweep(failures: ["\(error)"])
    }
  }
}
