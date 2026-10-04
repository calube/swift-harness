import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@Suite("Shell write targets after a cd")
struct ShellWriteTargetsTests {
  /// A build worker's Bash call that `guard.build-agent-main-checkout` denied in the third memos
  /// trial, as its transcript recorded it.
  struct DeniedCall: Decodable {
    let cwd: String
    let command: String
    let denial: String
  }

  static func deniedCalls() throws -> [DeniedCall] {
    try JSONDecoder().decode(
      [DeniedCall].self, from: Fixture.data("Hooks/memos-3-worker-bash.json"))
  }

  static let directories: Set<String> = ["/wt", "/main"]

  static func paths(_ line: String) -> [String] {
    ShellSyntax.writeTargets(in: line, directoryExists: { directories.contains($0) }).map(\.path)
  }

  @Test(
    "each write a memos worker made after cd into its own worktree is named only under that worktree, never under the session's starting directory — catches the guard denying a worker's own worktree writes as main-checkout writes"
  )
  func capturedWorkerWritesFollowTheirCd() throws {
    let calls = try Self.deniedCalls()
    #expect(calls.count == 4)
    for call in calls {
      let worktrees = { (path: String) in path.hasPrefix("/CLONE-spec-share-view-limit-") }
      let paths = ShellSyntax.writeTargets(in: call.command, directoryExists: worktrees)
        .map(\.path)
      #expect(!paths.isEmpty, "\(call.command.prefix(80))")
      let denied = try #require(call.denial.split(separator: "`").dropFirst().first)
      #expect(!paths.contains { "\(call.cwd)/\($0)" == denied }, "\(denied)")
      #expect(paths.allSatisfy(worktrees), "\(paths)")
    }
  }

  @Test(
    "a relative write after a cd that may not have run, may have gone elsewhere or runs in a subshell keeps its starting-directory spelling, while the same write after `cd /wt &&` is named only under /wt — catches a cd making a main-checkout write look like it landed elsewhere",
    arguments: [
      ("cd /wt && echo x > a", "cd \"$X\" && echo x > a"),
      ("cd /wt && echo x > a", "cd $(git rev-parse --show-toplevel) && echo x > a"),
      ("cd /wt && echo x > a", "cd /w* && echo x > a"),
      ("cd /wt && echo x > a", "cd ~/wt && echo x > a"),
      ("cd /wt && echo x > a", "true || cd /wt && echo x > a"),
      ("cd /wt && echo x > a", "cd /wt || echo x > a"),
      ("cd /wt && echo x > a", "! cd /wt && echo x > a"),
      ("cd /wt && echo x > a", "env cd /wt && echo x > a"),
      ("cd /wt && echo x > a", "(cd /wt) && echo x > a"),
      ("cd /wt && echo x > a", "cd /wt | cat && echo x > a"),
      ("cd /wt && echo x > a", "cd /wt |& cat && echo x > a"),
      ("cd /wt && echo x > a", "cd /wt & echo x > a"),
      ("cd /wt && echo x > a", "cd /wt && pushd -n /main && popd && echo x > a"),
      ("cd /wt && echo x > a", "cd /wt && cd sub && echo x > a"),
      ("cd /wt && echo x > a", "cd /wt && sh -c 'echo x > a'"),
      ("cd /wt && echo x > a", "f() { cd /main; }; cd /wt && f && echo x > a"),
      ("cd /wt && echo x > a", "trap 'cd /main' DEBUG; cd /wt && echo x > a"),
      ("cd /wt && echo x > a", "cd /wt && eval cd /main && echo x > a"),
      ("cd /wt\necho x > a", "cd /missing\necho x > a"),
      ("cd /wt\necho x > a", "ls; cd /wt\necho x > a"),
      ("cd /wt\necho x > a", "cd /wt || exit\necho x > a"),
      ("cd /wt\necho x > a", "cd /wt\nif true; then\ncd /main\nfi\necho x > a"),
      ("cd /wt\necho x > a", "cd /wt\nfor d in a; do cd /main; done\necho x > a"),
      ("cd /wt; echo x > a", "cd /wt; (cd /main; echo x > a)"),
    ])
  func uncertainCdKeepsTheStartingDirectory(certain: String, uncertain: String) {
    #expect(Self.paths(certain) == ["/wt/a"], "\(certain)")
    #expect(Self.paths(uncertain).contains("a"), "\(uncertain)")
  }

  @Test(
    "a write after cd into the main checkout is named under it however the cd is joined, and a cd elsewhere names only that directory — catches a cd hiding a main-checkout write",
    arguments: [
      "cd /main && echo x > a", "cd /main\necho x > a", "cd /main; echo x > a",
      "pushd /main && echo x > a", "cd -P /main && cat a | tee a",
      "cd /wt && cd /main && echo x > a",
    ])
  func cdIntoTheMainCheckoutStaysThere(command: String) {
    let paths = Self.paths(command)
    #expect(paths.contains("/main/a"), "\(paths)")
    #expect(!paths.contains("/wt/a"), "\(paths)")
    let elsewhere = command.replacingOccurrences(of: "/main", with: "/wt")
      .replacingOccurrences(of: "cd /wt && cd /wt", with: "cd /wt")
    #expect(Self.paths(elsewhere).allSatisfy { $0.hasPrefix("/wt/") }, "\(elsewhere)")
  }
}
