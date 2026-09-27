import SwiftGateDomain
import Testing

@Suite("review-input numbered diff")
struct NumberedDiffTests {
  static let diff = """
    diff --git a/Sources/A.swift b/Sources/A.swift
    index 1111111..2222222 100644
    --- a/Sources/A.swift
    +++ b/Sources/A.swift
    @@ -3,4 +3,5 @@ struct A {
       let one = 1
    -  let two = 2
    +  let two = 20
    +++ tricky = 3
       let four = 4
       let five = 5
    @@ -40,2 +41,3 @@ func tail() {
       x()
    +  y()
       z()
    diff --git a/Sources/Gone.swift b/Sources/Gone.swift
    deleted file mode 100644
    --- a/Sources/Gone.swift
    +++ /dev/null
    @@ -1,2 +0,0 @@
    -let gone = 1
    -let also = 2

    """

  @Test(
    "context and added lines carry their new-file line number, removed lines none — catches reviewers citing a diff.patch line"
  )
  func numbersNewLines() throws {
    let rendered = try NumberedDiff.render(Self.diff)
    let body = rendered.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    #expect(body.contains("     3     let one = 1"))
    #expect(body.contains("       -   let two = 2"))
    #expect(body.contains("     4 +   let two = 20"))
    #expect(body.contains("     5 + ++ tricky = 3"))
    #expect(body.contains("     7     let five = 5"))
    #expect(body.contains("    42 +   y()"))
    #expect(body.contains("    43     z()"))
    #expect(body.contains("       - let also = 2"))
    #expect(body.contains("+++ b/Sources/A.swift"))
    #expect(body.contains("@@ -40,2 +41,3 @@ func tail() {"))
  }

  @Test(
    "the numbered diff opens by saying which number to cite — catches a reviewer reading the left column as a patch line"
  )
  func explainsTheColumn() throws {
    let first = try NumberedDiff.render(Self.diff).split(separator: "\n").first
    #expect(first == Substring(NumberedDiff.legend))
    #expect(NumberedDiff.legend.contains("line in the new file"))
  }

  @Test(
    "a malformed hunk header is an error, not a guess — catches silently wrong line numbers"
  )
  func malformedHeader() {
    #expect(throws: NumberedDiff.Malformed.self) {
      try NumberedDiff.render("diff --git a/A b/A\n--- a/A\n+++ b/A\n@@ -1 +x @@\n+a\n")
    }
  }
}
