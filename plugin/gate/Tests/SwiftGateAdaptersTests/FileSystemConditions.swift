import Foundation
import SwiftGateAdapters
import SwiftGateTestSupport

/// Real filesystem states for error-path tests: a scratch directory, permission changes that are
/// always undone, and a small FAT volume (no hard links, a fixed size that can be filled).
enum FileSystemConditions {
  /// `chmod` denies nothing to root, so a permission test run as root would pass vacuously.
  static let permissionsDeny = geteuid() != 0

  static let hasDiskImages = FileManager.default.isExecutableFile(atPath: "/usr/bin/hdiutil")

  static func scratchDirectory(_ label: String) throws -> URL {
    let url = TestTemporaryDirectory.root
      .appending(path: "swiftgate-\(label)-\(UUID().uuidString)", directoryHint: .isDirectory)
      .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  /// Every file and directory under `root`, relative to it, sorted.
  static func contents(of root: String) -> [String] {
    (FileManager.default.subpaths(atPath: root) ?? []).sorted()
  }

  static func setMode(_ mode: mode_t, _ path: String) throws {
    guard chmod(path, mode) == 0 else {
      throw ConditionError(
        "chmod \(String(mode, radix: 8)) \(path): \(String(cString: strerror(errno)))")
    }
  }
}

struct ConditionError: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) { self.description = description }
}

/// A 1 MB MS-DOS (FAT) disk image attached at a private mount point. FAT has no hard links, so
/// `link(2)` fails there with `ENOTSUP`, and its fixed size lets a test fill it to `ENOSPC`.
struct FATVolume {
  let image: URL
  let mountPoint: URL

  /// Attaches a fresh volume for `body` and detaches it afterwards, whether `body` throws or not.
  static func with<T>(_ body: (FATVolume) async throws -> T) async throws -> T {
    let volume = try await FATVolume()
    let result: Result<T, any Error>
    do {
      result = .success(try await body(volume))
    } catch {
      result = .failure(error)
    }
    await volume.detach()
    return try result.get()
  }

  private init() async throws {
    let base = try FileSystemConditions.scratchDirectory("fat")
    image = base.appending(path: "volume.dmg")
    mountPoint = base.appending(path: "mnt", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
    try await Self.hdiutil(
      "create", "-quiet", "-size", "1m", "-fs", "MS-DOS", "-volname", "SGTEST", "-layout", "NONE",
      "-o", image.path)
    try await Self.hdiutil(
      "attach", "-quiet", "-nobrowse", "-mountpoint", mountPoint.path, image.path)
  }

  private func detach() async {
    try? await Self.hdiutil("detach", "-quiet", "-force", mountPoint.path)
    TemporaryDirectories.remove(image.deletingLastPathComponent())
  }

  /// Grows a filler file to the largest size the volume accepts. FAT has no sparse files, so every
  /// cluster is then allocated. Growing by `ftruncate` rather than writing matters: a write that
  /// doesn't fit fails whole, and `statvfs` overstates what FAT can still allocate.
  func fill() throws {
    let path = mountPoint.appending(path: "filler").path
    let descriptor = open(path, O_WRONLY | O_CREAT, 0o644)
    guard descriptor >= 0 else { throw ConditionError("creating \(path)") }
    defer { close(descriptor) }
    var fits: off_t = 0
    var tooBig: off_t = 4 * 1024 * 1024
    while tooBig - fits > 1 {
      let size = (fits + tooBig) / 2
      if ftruncate(descriptor, size) == 0 { fits = size } else { tooBig = size }
    }
    guard ftruncate(descriptor, fits) == 0 else { throw ConditionError("sizing \(path)") }
  }

  /// Through the process runner, which waits on a thread of its own: `hdiutil` can take seconds
  /// under load, and a test waiting in `Process.waitUntilExit()` holds a pool thread for all of it.
  private static func hdiutil(_ arguments: String...) async throws {
    let output = try await LiveProcessRunner().run(
      ProcessInvocation(
        executable: "/usr/bin/hdiutil", arguments: arguments, timeout: .seconds(120)))
    guard output.status.isSuccess else {
      throw ConditionError(
        "hdiutil \(arguments.joined(separator: " ")) exited \(output.status): \(output.stderr.text)"
      )
    }
  }
}
