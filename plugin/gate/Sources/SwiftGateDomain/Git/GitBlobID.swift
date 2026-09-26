import CryptoKit

/// The object id git gives a blob: SHA-1 of `"blob <byte count>\0"` followed by the content's
/// UTF-8 bytes, in lowercase hex. Computed in-process so content git never stored (a design doc
/// with its `status:` line stripped) can be matched against revisions read from history.
public enum GitBlobID {
  public static func of(_ content: String) -> String {
    let body = Array(content.utf8)
    var hasher = Insecure.SHA1()
    hasher.update(data: Array("blob \(body.count)\0".utf8))
    hasher.update(data: body)
    return hasher.finalize().map { byte in
      let hex = String(byte, radix: 16)
      return byte < 0x10 ? "0" + hex : hex
    }.joined()
  }
}
