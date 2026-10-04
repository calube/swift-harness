import SwiftGateDomain
import Testing

@Suite("DirtyFileGuard")
struct DirtyFileGuardTests {
  static let root = "/work/clone"
  static let dirty = DirtyFileList(paths: ["src/wip.py", "notes.txt"])

  func verdict(_ command: String, cwd: String = root, dirty: DirtyFileList = dirty)
    -> GuardViolation?
  {
    DirtyFileGuard.evaluate(command, cwd: cwd, repositoryRoot: Self.root, dirty: dirty)
  }

  @Test(
    "git add of a dirty path is denied naming it, and of another path passes — catches the guard denying every add, or none"
  )
  func addNamesTheDirtyPath() throws {
    let denied = try #require(verdict("git add src/wip.py"))
    #expect(denied.ruleID == DirtyFileGuard.ruleID)
    #expect(denied.reason.contains("src/wip.py"))
    #expect(verdict("git add src/other.py") == nil)
    #expect(verdict("git add src/wip.python") == nil)
  }

  @Test(
    "a directory, an all-files form or a relative path that covers a dirty file is denied — catches staging it by another spelling",
    arguments: [
      ("git add src", root), ("git add .", root), ("git add -A", root),
      ("git add --all", root), ("git add -u", root), ("git stage src/wip.py", root),
      ("git add wip.py", root + "/src"), ("git add ../notes.txt", root + "/src"),
      ("git -C src add wip.py", root), ("git add ./src/../src/wip.py", root),
      ("git add -- src/wip.py", root), ("make && git add src", root),
      ("git add \(root)/src/wip.py", "/elsewhere"),
    ])
  func otherSpellingsDenied(_ command: String, _ cwd: String) {
    #expect(verdict(command, cwd: cwd)?.ruleID == DirtyFileGuard.ruleID, "\(command) in \(cwd)")
  }

  @Test(
    "a path outside every dirty file passes — catches a directory prefix matched by string",
    arguments: [
      ("git add docs", root), ("git add .", root + "/docs"), ("git add sr", root),
      ("git status", root), ("git add -n src/other.py", root),
    ])
  func unrelatedPasses(_ command: String, _ cwd: String) {
    #expect(verdict(command, cwd: cwd) == nil, "\(command) in \(cwd)")
    #expect(verdict("git add src", cwd: Self.root) != nil, "the dirty control")
  }

  @Test(
    "git commit -a or with a dirty pathspec is denied, a plain commit passes — catches commit staging around the add guard"
  )
  func commitForms() {
    #expect(verdict("git commit -am 'wip'")?.ruleID == DirtyFileGuard.ruleID)
    #expect(verdict("git commit --all -m wip")?.ruleID == DirtyFileGuard.ruleID)
    #expect(verdict("git commit -m wip src/wip.py")?.ruleID == DirtyFileGuard.ruleID)
    #expect(verdict("git commit -m wip") == nil)
    #expect(verdict("git commit -m 'add src/wip.py later'") == nil)
    #expect(verdict("git commit -m wip src/other.py") == nil)
  }

  @Test("an empty dirty list allows staging everything — catches a guard with nothing to protect")
  func emptyListAllows() {
    #expect(verdict("git add -A") != nil)
    #expect(verdict("git add -A", dirty: DirtyFileList(paths: [])) == nil)
    #expect(verdict("git commit -am wip", dirty: DirtyFileList(paths: [])) == nil)
  }
}
