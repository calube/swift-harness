import Foundation
import Synchronization

/// 1 command an area runs, already expanded: no `{files}`, `{tests}` or `{junit}` remains.
public struct AreaCommandRequest: Sendable, Equatable {
  public let area: String
  public let step: AreaStep
  /// Run through `/bin/sh -c`.
  public let command: String
  /// Absolute: the area's root.
  public let workingDirectory: String
  public let deadline: Duration
  /// Added to the inherited environment, such as a shared package cache.
  public let environment: [String: String]
  /// Absolute path the command writes JUnit XML to, when `{junit}` was expanded.
  public let junitPath: String?
  /// Absolute path an `xcodebuild` test command writes its result bundle to, which the runner
  /// reads for the failing tests' ids since `xcodebuild` writes no JUnit.
  public let resultBundlePath: String?
  /// The DerivedData the runner seeds before the command runs, when the command builds into a
  /// worktree's own DerivedData.
  public let derivedDataSeed: DerivedDataSeedCopy?
  /// The build directory the command takes its turn in, and where the runner adds up how long it
  /// waited; `nil` leaves the command to the tool's own locking, untimed.
  public let buildLock: BuildDirectoryLock?

  public init(
    area: String, step: AreaStep, command: String, workingDirectory: String, deadline: Duration,
    environment: [String: String], junitPath: String?, resultBundlePath: String? = nil,
    derivedDataSeed: DerivedDataSeedCopy? = nil, buildLock: BuildDirectoryLock? = nil
  ) {
    self.area = area
    self.step = step
    self.command = command
    self.workingDirectory = workingDirectory
    self.deadline = deadline
    self.environment = environment
    self.junitPath = junitPath
    self.resultBundlePath = resultBundlePath
    self.derivedDataSeed = derivedDataSeed
    self.buildLock = buildLock
  }
}

/// A build directory that 1 command builds in at a time: SwiftPM locks a scratch path while it
/// builds, and `xcodebuild` fails a build whose build database another build holds. The runner
/// waits its turn on a lock beside the directory and adds the wait to ``waits``.
public struct BuildDirectoryLock: Sendable, Equatable {
  /// Absolute.
  public let directory: String
  public let waits: BuildLockWaits

  public init(directory: String, waits: BuildLockWaits) {
    self.directory = directory
    self.waits = waits
  }
}

/// How long the commands sharing it waited for their build directories, added up across them.
/// Equal only to itself, since commands add to 1 shared total.
public final class BuildLockWaits: Sendable, Equatable {
  private let total = Mutex<Int?>(nil)

  public init() {}

  /// Adds a wait of `milliseconds`; a wait of 0 still marks that a command took its turn.
  public func add(milliseconds: Int) {
    total.withLock { $0 = ($0 ?? 0) + max(0, milliseconds) }
  }

  /// The waits added up; `nil` when no command took a turn.
  public var milliseconds: Int? { total.withLock { $0 } }

  public static func == (lhs: BuildLockWaits, rhs: BuildLockWaits) -> Bool { lhs === rhs }
}

/// A worktree's DerivedData to start from the area's seed, which the warm-up builds at the base
/// tree. Both absolute.
public struct DerivedDataSeedCopy: Sendable, Equatable {
  public let seed: String
  public let destination: String

  public init(seed: String, destination: String) {
    self.seed = seed
    self.destination = destination
  }
}

/// How an area command ended. `tail` is the last 40 lines of its combined output.
public enum AreaCommandOutcome: Sendable, Equatable {
  case passed
  /// `junit` holds the report's bytes when the request named a path and the command wrote it.
  case failed(exit: Int32, tail: String, junit: Data?)
  /// The test process died rather than reporting a failure. `signal` is `nil` when the death was
  /// read from the runner's output, such as a forked JVM's `System.exit`, and no signal was named.
  case crashed(signal: Int32?, tail: String)
  case timedOut(tail: String)
}

extension AreaCommandOutcome {
  /// `/bin/sh` exits 127 when it can't find the command's tool.
  public var toolNotInstalled: Bool {
    if case .failed(127, _, _) = self { true } else { false }
  }
}
