import Foundation

/// What every file a run view reads held at 1 moment: each stream file's byte length and the
/// ledger log's, plus the files a run rewrites in place. 2 equal snapshots build the same view.
public struct RunViewSnapshot: Sendable, Equatable {
  /// 1 file's length and modification time.
  public struct Stamp: Sendable, Equatable, Hashable {
    public var bytes: Int
    /// Catches a file rewritten in place to the same length.
    public var modifiedNanoseconds: Int

    public init(bytes: Int, modifiedNanoseconds: Int = 0) {
      self.bytes = bytes
      self.modifiedNanoseconds = modifiedNanoseconds
    }
  }

  /// By path, as the reader names it.
  public var files: [String: Stamp]

  public init(files: [String: Stamp] = [:]) {
    self.files = files
  }

  /// The opaque token a live page polls with: a digest of every path and stamp, since the
  /// offsets themselves outgrow the payload guard's string cap once a run has a few stores.
  public var cursor: String {
    // FNV-1a over a canonical listing: stable across processes, unlike `Hasher`.
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for path in files.keys.sorted() {
      let stamp = files[path] ?? Stamp(bytes: 0)
      for byte in "\(path)\t\(stamp.bytes)\t\(stamp.modifiedNanoseconds)\n".utf8 {
        hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3
      }
    }
    let hex = String(hash, radix: 16)
    return "c1-" + String(repeating: "0", count: 16 - hex.count) + hex
  }
}
