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
    nil
  }

  public func unregister(_ record: URL) {}

  /// Every recorded gate whose process still runs. A record whose process ended is removed.
  public func running() -> [RunningGate] { [] }

  /// Ends every running gate checking one of `toplevels`, and returns them.
  public func stop(in toplevels: [String]) async -> [RunningGate] { [] }
}

/// ``GateProcesses`` over `sysctl` and signals.
public struct LiveGateProcesses: GateProcesses {
  public init() {}

  public func startTime(of pid: Int32) -> Double? { nil }

  public func terminate(_ pid: Int32) async {}
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

  public func stopGates(in worktrees: [String]) async -> [RunningGate] { [] }

  public func pruneScratchTrees() async -> ScratchWorktreeSweep { ScratchWorktreeSweep() }
}
