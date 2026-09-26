import SwiftGateDomain
import Testing

@Suite("unified diff")
struct UnifiedDiffTests {
  @Test("identical text renders nothing — catches a no-op bootstrap printing empty hunks")
  func identical() {
    #expect(UnifiedDiff.render(path: "a.txt", old: "one\ntwo\n", new: "one\ntwo\n").isEmpty)
  }

  @Test(
    "a new file is diffed against /dev/null with every line added — catches a dry run hiding what a created file holds"
  )
  func created() {
    #expect(
      UnifiedDiff.render(path: "lefthook.yml", old: nil, new: "a\nb\n") == """
        --- /dev/null
        +++ b/lefthook.yml
        @@ -0,0 +1,2 @@
        +a
        +b

        """)
  }

  @Test(
    "a change keeps three lines of context and separate hunks for distant edits — catches a diff that shows the wrong lines or merges unrelated edits"
  )
  func hunks() {
    let old = (1...12).map { "l\($0)" }.joined(separator: "\n") + "\n"
    let new =
      old.replacingOccurrences(of: "l2\n", with: "L2\n")
      .replacingOccurrences(of: "l11\n", with: "l11\nadded\n")
    #expect(
      UnifiedDiff.render(path: "f", old: old, new: new) == """
        --- a/f
        +++ b/f
        @@ -1,5 +1,5 @@
         l1
        -l2
        +L2
         l3
         l4
         l5
        @@ -9,4 +9,5 @@
         l9
         l10
         l11
        +added
         l12

        """)
  }

  @Test(
    "edits closer than twice the context share one hunk — catches overlapping hunks that repeat lines"
  )
  func mergedHunks() {
    let diff = UnifiedDiff.render(path: "f", old: "a\nb\nc\nd\ne\n", new: "A\nb\nc\nd\nE\n")
    #expect(diff.components(separatedBy: "@@ -").count == 2)
    #expect(diff.contains("@@ -1,5 +1,5 @@"))
  }
}
