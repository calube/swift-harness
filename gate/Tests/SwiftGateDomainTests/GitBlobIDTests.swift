import SwiftGateDomain
import Testing

@Suite("GitBlobID")
struct GitBlobIDTests {
  /// Expected ids captured with `printf '<content>' | git hash-object --stdin` (git 2.50.1).
  @Test(
    "blob id matches git hash-object — catches a designSha that never matches any revision",
    arguments: [
      ("hello world\n", "3b18e512dba79e4c8300dd08aeb37f8e728b8dad"),
      ("café — 日本\n", "3e0bcbb412b5fbf869c5091cb12b04a744fccca4"),
      ("", "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391"),
    ])
  func matchesGit(content: String, expected: String) {
    #expect(GitBlobID.of(content) == expected)
  }
}
