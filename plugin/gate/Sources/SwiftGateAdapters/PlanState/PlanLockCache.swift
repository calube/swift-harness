import Darwin
import Foundation
import SwiftGateDomain

/// One session's memory of what the PreToolUse guard reads slowly in one checkout: the git common
/// dir, which costs a `git` spawn per call. Lock files, the plans listing and every `plan.json`
/// are never cached, so a claim, release or design change is seen on the very next call.
///
/// An entry is trusted only while everything git's answer depends on is unchanged: the checkout's
/// canonical path, the `.git` entry git discovers from it (a linked worktree's `.git` file is
/// rewritten when the worktree is re-added), and the common dir itself. Anything else is a miss
/// that asks git again and rewrites the entry. The file is replaced by atomic rename, so a racing
/// hook reads either the old entry or the new one, and each is checked against the disk before
/// it is used.
public struct PlanLockCache: Sendable {
  /// The common dir and the note a cache fault leaves, for the caller to surface.
  public struct Answer: Sendable, Equatable {
    public let commonDirectory: String
    /// Set when the cache file existed but couldn't be read or decoded, or couldn't be written.
    public let note: String?

    public init(commonDirectory: String, note: String?) {
      self.commonDirectory = commonDirectory
      self.note = note
    }
  }

  public static let fileNamePrefix = "plan-lock-cache-"
  static let schemaVersion = 1
  /// Variables that point git at a repository other than the one it discovers from the checkout.
  static let repositoryOverrides = ["GIT_DIR", "GIT_COMMON_DIR"]

  public let worktreeRoot: URL
  public let sessionID: String

  /// `nil` when `sessionID` isn't one safe path component: letters, digits, `-`, `_` and `.`,
  /// not starting with `.`, at most 128 characters.
  public init?(worktreeRoot: URL, sessionID: String) {
    guard Self.isSafeComponent(sessionID) else { return nil }
    self.worktreeRoot = worktreeRoot
    self.sessionID = sessionID
  }

  static func isSafeComponent(_ value: String) -> Bool {
    guard !value.isEmpty, value.utf8.count <= 128, value.first != "." else { return false }
    return value.unicodeScalars.allSatisfy { scalar in
      scalar.isASCII
        && (CharacterSet.alphanumerics.contains(scalar) || "-_.".unicodeScalars.contains(scalar))
    }
  }

  public var file: URL {
    HookStateStore(worktreeRoot: worktreeRoot).directoryURL
      .appending(path: Self.fileNamePrefix + sessionID + ".json")
  }

  /// The common dir of the checkout at `worktreeRoot`. `read` asks git; its error is never cached.
  public func commonDirectory(
    environment: [String: String], read: () async throws(GitError) -> String
  ) async throws(GitError) -> Answer {
    if Self.repositoryOverrides.contains(where: { environment[$0] != nil }) {
      return Answer(commonDirectory: try await read(), note: nil)
    }
    let checkout = CanonicalPath.of(worktreeRoot)
    var notes: [String] = []
    switch load() {
    case .entry(let entry):
      if let hit = entry.commonDirectoryIfCurrent(checkout: checkout) {
        return Answer(commonDirectory: hit, note: nil)
      }
    case .missing:
      break
    case .unusable(let reason):
      notes.append(
        "swiftgate: the plan-lock cache \(file.path) was unusable (\(reason)); plan state was "
          + "read fresh and the cache rebuilt.")
    }
    let before = GitEntry.discover(from: checkout)
    let common = try await read()
    if let before, before == GitEntry.discover(from: checkout),
      let commonStamp = FileStamp.of(common)
    {
      let entry = Entry(
        schemaVersion: Self.schemaVersion, checkout: checkout, gitEntry: before,
        commonDirectory: common, commonDirectoryStamp: commonStamp)
      if let failure = save(entry) {
        notes.append(
          "swiftgate: the plan-lock cache \(file.path) couldn't be written (\(failure)); the "
            + "next call reads plan state fresh again.")
      }
    }
    return Answer(
      commonDirectory: common, note: notes.isEmpty ? nil : notes.joined(separator: "\n"))
  }

  private enum Loaded {
    case missing
    case entry(Entry)
    case unusable(String)
  }

  private func load() -> Loaded {
    let data: Data
    do {
      data = try Data(contentsOf: file)
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      return .missing
    } catch {
      return .unusable(error.localizedDescription)
    }
    let entry: Entry
    do {
      entry = try JSONDecoder().decode(Entry.self, from: data)
    } catch {
      return .unusable("it doesn't decode: \(error)")
    }
    guard entry.schemaVersion == Self.schemaVersion else {
      return .unusable("unknown schemaVersion \(entry.schemaVersion)")
    }
    return .entry(entry)
  }

  /// A failure's description, or `nil` once the entry is in place.
  private func save(_ entry: Entry) -> String? {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    do throws(HookStateError) {
      let data: Data
      do {
        data = try encoder.encode(entry)
      } catch {
        return "\(error)"
      }
      try HookStateStore(worktreeRoot: worktreeRoot).cache(data, as: file.lastPathComponent)
      return nil
    } catch {
      return "\(error)"
    }
  }
}

extension PlanLockCache {
  /// The file's one entry. Every field is what a later call checks against the disk.
  struct Entry: Codable, Equatable {
    let schemaVersion: Int
    /// The checkout's canonical path, which a moved checkout no longer matches.
    let checkout: String
    let gitEntry: GitEntry
    let commonDirectory: String
    let commonDirectoryStamp: FileStamp

    func commonDirectoryIfCurrent(checkout current: String) -> String? {
      guard checkout == current, GitEntry.discover(from: current) == gitEntry,
        FileStamp.of(commonDirectory) == commonDirectoryStamp
      else { return nil }
      return commonDirectory
    }
  }

  /// The `.git` git finds first walking up from the checkout, and its stamp.
  struct GitEntry: Codable, Equatable {
    let path: String
    let stamp: FileStamp

    static func discover(from checkout: String) -> GitEntry? {
      var directory = checkout
      while true {
        let candidate = (directory == "/" ? "" : directory) + "/.git"
        if let stamp = FileStamp.of(candidate) { return GitEntry(path: candidate, stamp: stamp) }
        guard directory != "/" else { return nil }
        directory = (directory as NSString).deletingLastPathComponent
      }
    }
  }

  /// A file's identity and content stamp. A directory is compared by identity only: git touches
  /// the common dir's own mtime on every index write, which changes nothing a lookup depends on.
  enum FileStamp: Codable, Equatable {
    case directory(device: Int64, inode: UInt64)
    case file(device: Int64, inode: UInt64, size: Int64, modified: Int64, changed: Int64)

    /// Follows symlinks, as git does. `nil` when nothing is there.
    static func of(_ path: String) -> FileStamp? {
      var info = stat()
      guard stat(path, &info) == 0 else { return nil }
      let device = Int64(info.st_dev)
      if info.st_mode & S_IFMT == S_IFDIR {
        return .directory(device: device, inode: info.st_ino)
      }
      return .file(
        device: device, inode: info.st_ino, size: info.st_size,
        modified: nanoseconds(info.st_mtimespec), changed: nanoseconds(info.st_ctimespec))
    }

    private static func nanoseconds(_ time: timespec) -> Int64 {
      Int64(time.tv_sec) * 1_000_000_000 + Int64(time.tv_nsec)
    }
  }
}
