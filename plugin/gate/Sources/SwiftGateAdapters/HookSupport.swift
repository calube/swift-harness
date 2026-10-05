import CryptoKit
import Foundation
import SwiftGateDomain

/// Finds the swiftgate project a hook fires in. Hooks are no-ops outside one (spec §8).
public enum ProjectRoot {
  /// The nearest directory at or above `directory` holding `.swiftgate.toml`. The search stops at
  /// the enclosing git worktree's root (a directory containing `.git`), so a parent repository's
  /// config never governs a nested one.
  public static func locate(from directory: URL) -> URL? {
    var path = directory.standardizedFileURL.path
    while true {
      let current = URL(filePath: path, directoryHint: .isDirectory)
      if FileManager.default.fileExists(atPath: current.appending(path: Config.fileName).path) {
        return current
      }
      let parent = (path as NSString).deletingLastPathComponent
      if FileManager.default.fileExists(atPath: current.appending(path: ".git").path)
        || parent == path || parent.isEmpty
      {
        return nil
      }
      path = parent
    }
  }
}

/// The project a hook fires in, by profile.
public enum HookProject: Sendable, Equatable {
  /// The directory holding `.swiftgate.toml`.
  case owned(URL)
  /// A worktree of a clone whose git common dir holds the brownfield `config.toml`.
  case brownfield(root: URL, layout: BrownfieldStateLayout)

  public var root: URL {
    switch self {
    case .owned(let root), .brownfield(let root, _): root
    }
  }
}

extension ProjectRoot {
  /// ``locate(from:)``'s owned project, or else the enclosing worktree when its clone runs the
  /// brownfield profile. A clone that set its committed config aside runs the brownfield profile.
  public static func locateProfile(from directory: URL) -> HookProject? {
    if let owned = locate(from: directory),
      !(ConfigLoader.commonDirectory(enclosing: owned)
        .map(StateRootResolver.setsAsideCommittedConfig(commonDir:)) ?? false)
    {
      return .owned(owned)
    }
    guard let worktree = worktreeRoot(from: directory),
      let gitDir = StateRootResolver.gitDirectory(enclosing: worktree)
    else { return nil }
    let common = StateRootResolver.commonDirectory(of: gitDir)
    guard
      FileManager.default.fileExists(
        atPath: common.appending(path: StateRootResolver.commonConfigFile).path)
    else { return nil }
    return .brownfield(
      root: worktree, layout: BrownfieldStateLayout(commonDir: common, gitDir: gitDir))
  }

  /// The nearest directory at or above `directory` holding `.git`.
  private static func worktreeRoot(from directory: URL) -> URL? {
    var current = directory.standardizedFileURL
    while true {
      if FileManager.default.fileExists(atPath: current.appending(path: ".git").path) {
        return current
      }
      let parent = current.deletingLastPathComponent().standardizedFileURL
      if parent.path == current.path { return nil }
      current = parent
    }
  }
}

/// What reading `discover/dirty.json` gave.
public enum DirtyFileRead: Sendable, Equatable {
  /// Discovery hasn't written one.
  case absent
  case listed(DirtyFileList)
  case unreadable(path: String, reason: String)

  public static func read(_ file: URL) -> DirtyFileRead {
    let data: Data
    do {
      data = try Data(contentsOf: file)
    } catch CocoaError.fileReadNoSuchFile {
      return .absent
    } catch {
      return .unreadable(path: file.path, reason: error.localizedDescription)
    }
    do {
      return .listed(try JSONDecoder().decode(DirtyFileList.self, from: data))
    } catch {
      return .unreadable(path: file.path, reason: "\(error)")
    }
  }
}

public enum HookStateError: Error, Sendable, Equatable {
  case unwritable(path: String, reason: String)

  public var verdict: Verdict { .blocked }
}

/// Per-worktree hook memory under the state root's `hook-state/`, which ignores itself in git. Reads never
/// fail: missing or unreadable state is the empty state, since it only saves work.
public struct HookStateStore: Sendable {
  static let lastGreenFile = "last-green"

  public let worktreeRoot: URL
  public let state: StateRoot

  public init(worktreeRoot: URL) {
    self.worktreeRoot = worktreeRoot
    self.state = StateRootResolver.resolve(worktree: worktreeRoot)
  }

  public var directoryURL: URL {
    state.url(RunLayout.hookStateDirectory, directoryHint: .isDirectory)
  }

  public func stopState(session: String) -> StopState {
    guard let data = read(Self.stopFile(session: session)),
      let state = try? JSONDecoder().decode(StopState.self, from: data)
    else { return StopState() }
    return state
  }

  public func saveStopState(_ state: StopState, session: String) throws(HookStateError) {
    let data: Data
    do {
      data = try JSONEncoder().encode(state)
    } catch {
      throw .unwritable(path: Self.stopFile(session: session), reason: "\(error)")
    }
    try write(data, to: Self.stopFile(session: session))
  }

  /// The content fingerprint that last passed the Stop hook's check, shared by every session in
  /// this worktree because it describes the content, not the session.
  public func lastGreen() -> String? {
    read(Self.lastGreenFile).map { String(decoding: $0, as: UTF8.self) }.flatMap {
      $0.isEmpty ? nil : $0
    }
  }

  public func saveLastGreen(_ fingerprint: String) throws(HookStateError) {
    try write(Data(fingerprint.utf8), to: Self.lastGreenFile)
  }

  public func cached(_ name: String) -> Data? { read(name) }

  public func cache(_ data: Data, as name: String) throws(HookStateError) {
    try write(data, to: name)
  }

  /// Session ids come from Claude Code, but are still input: the file name is a digest, never a
  /// path fragment.
  static func stopFile(session: String) -> String {
    let digest = SHA256.hash(data: Data(session.utf8)).prefix(12)
    return "stop-" + digest.map { String(format: "%02x", $0) }.joined() + ".json"
  }

  private func read(_ name: String) -> Data? {
    try? Data(contentsOf: directoryURL.appending(path: name))
  }

  private func write(_ data: Data, to name: String) throws(HookStateError) {
    let url = directoryURL.appending(path: name)
    do {
      try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
      let ignore = directoryURL.appending(path: ".gitignore")
      if !FileManager.default.fileExists(atPath: ignore.path) {
        try Data("*\n".utf8).write(to: ignore, options: .atomic)
      }
      try data.write(to: url, options: .atomic)
    } catch {
      throw .unwritable(path: url.path, reason: error.localizedDescription)
    }
  }
}

public struct SelectedXcode: Sendable, Equatable {
  public let developerDirectory: String
  public let version: String

  public init(developerDirectory: String, version: String) {
    self.developerDirectory = developerDirectory
    self.version = version
  }
}

public enum XcodeSelectionError: Error, Sendable, Equatable, CustomStringConvertible {
  case unavailable(String)

  public var description: String {
    switch self {
    case .unavailable(let reason): reason
    }
  }
}

/// The Xcode that `xcodebuild` would use right now.
public protocol XcodeSelection: Sendable {
  func selected() async throws(XcodeSelectionError) -> SelectedXcode
}

/// Reads the version from the selected Xcode's `Info.plist` rather than running
/// `xcodebuild -version`, which takes hundreds of milliseconds: SessionStart has a 1s budget.
public struct LiveXcodeSelection: XcodeSelection {
  private let runner: any ProcessRunner
  private let developerDirectoryOverride: String?

  /// - Parameter developerDirectoryOverride: `DEVELOPER_DIR`, which takes precedence over
  ///   `xcode-select`.
  public init(runner: any ProcessRunner, developerDirectoryOverride: String?) {
    self.runner = runner
    self.developerDirectoryOverride = developerDirectoryOverride.flatMap {
      $0.isEmpty ? nil : $0
    }
  }

  public func selected() async throws(XcodeSelectionError) -> SelectedXcode {
    let developer: String
    if let developerDirectoryOverride {
      developer = developerDirectoryOverride
    } else {
      let output: ProcessOutput
      do {
        output = try await runner.run(
          ProcessInvocation(
            executable: "/usr/bin/xcode-select", arguments: ["-p"], timeout: .seconds(5)))
      } catch {
        throw .unavailable("xcode-select: \(error)")
      }
      guard output.status.isSuccess else {
        throw .unavailable("xcode-select -p: \(output.stderr.text)")
      }
      developer = output.stdout.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    // `<Xcode>.app/Contents/Developer` → `<Xcode>.app/Contents/Info.plist`.
    let plist = URL(filePath: developer, directoryHint: .isDirectory).deletingLastPathComponent()
      .appending(path: "Info.plist")
    guard let data = try? Data(contentsOf: plist),
      let info = try? PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String: Any],
      let version = info["CFBundleShortVersionString"] as? String
    else {
      throw .unavailable("no Xcode version in \(plist.path) (Command Line Tools selected?)")
    }
    return SelectedXcode(developerDirectory: developer, version: version)
  }
}
