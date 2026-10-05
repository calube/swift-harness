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
      ("cd /wt && echo x > a", "cd /wt && sh -c 'echo x > a'"),
      ("cd /wt && echo x > a", "f() { cd /main; }; cd /wt && f && echo x > a"),
      ("cd /wt && echo x > a", "trap 'cd /main' DEBUG; cd /wt && echo x > a"),
      ("cd /wt && echo x > a", "cd /wt && eval cd /main && echo x > a"),
      ("cd /wt\necho x > a", "cd /missing\necho x > a"),
      ("cd /wt\necho x > a", "cd /wt\nif true; then\ncd /main\nfi\necho x > a"),
      ("cd /wt\necho x > a", "cd /wt\nfor d in a; do cd /main; done\necho x > a"),
      ("cd /wt; echo x > a", "cd /wt; (cd /main; echo x > a)"),
      ("C=/wt; cd $C && echo x > a", "C=$(pwd); cd $C && echo x > a"),
      ("C=/wt; cd $C && echo x > a", "C=`pwd`; cd $C && echo x > a"),
      ("C=/wt; cd $C && echo x > a", "C=/wt cd $C && echo x > a"),
      ("C=/wt; cd $C && echo x > a", "C=/wt; cd $D && echo x > a"),
      ("C=/wt; cd $C && echo x > a", "C=/wt; cd ${C:-/main} && echo x > a"),
      ("C=/wt; cd $C && echo x > a", "C='/w t'; cd $C && echo x > a"),
      ("C=/wt; cd $C && echo x > a", "true || C=/wt; cd $C && echo x > a"),
      ("C=/wt; cd $C && echo x > a", "C=/wt | cat; cd $C && echo x > a"),
      ("C=/wt; cd $C && echo x > a", "C=/wt; read C; cd $C && echo x > a"),
      ("C=/wt; cd $C && echo x > a", "C=/wt; unset C; cd $C && echo x > a"),
      ("C=/wt; cd $C && echo x > a", "C=/wt\nif true; then C=/main; fi\ncd $C && echo x > a"),
      ("C=/wt; cd $C && echo x > a", "C=/wt; for C in /main; do true; done; cd $C && echo x > a"),
    ])
  func uncertainCdKeepsTheStartingDirectory(certain: String, uncertain: String) {
    #expect(Self.paths(certain) == ["/wt/a"], "\(certain)")
    #expect(Self.paths(uncertain).contains("a"), "\(uncertain)")
  }

  /// A Bash call `guard.run-user-checkout` denied in a brownfield trial: a heredoc written on a
  /// later line than the `cd`s that moved the shell into a plan slot's `.harness/qa/spec`.
  struct RefusedCall: Decodable {
    let cwd: String
    let command: String
    let denial: String
  }

  @Test(
    "the trial's heredoc written after `cd <slot> && mkdir -p rel && cd rel &&` and a newline is named only under the slot, never under the session's starting directory — catches the guard refusing a write it resolved against the wrong directory"
  )
  func capturedHeredocAfterRelativeCdFollowsIt() throws {
    let call = try JSONDecoder().decode(
      RefusedCall.self, from: Fixture.data("Hooks/relative-heredoc-after-cd-bash.json"))
    let slot = "/CLONE-spec.slot-6"
    let paths = ShellSyntax.writeTargets(in: call.command, directoryExists: { $0 == slot })
      .map(\.path)
    let denied = try #require(call.denial.split(separator: "`").dropFirst().first)
    #expect(denied == "\(call.cwd)/launch-list.flow.json")
    #expect(paths == [slot + "/.harness/qa/spec/launch-list.flow.json"], "\(paths)")
  }

  @Test(
    "the trial's heredoc written on the line after `mkdir -p <slot dir> && cd <slot dir> && NAME=value` is named only under that directory — catches the guard refusing a write after a cd into a directory the same command makes"
  )
  func capturedHeredocAfterMkdirCdAndAssignmentFollowsIt() throws {
    let call = try JSONDecoder().decode(
      RefusedCall.self, from: Fixture.data("Hooks/mkdir-cd-assignment-heredoc-bash.json"))
    let slot = "/CLONE-spec.slot-6"
    let paths = ShellSyntax.writeTargets(in: call.command, directoryExists: { $0 == slot })
      .map(\.path)
    let denied = try #require(call.denial.split(separator: "`").dropFirst().first)
    #expect(denied == "\(call.cwd)/launch.flow.json")
    #expect(paths == [slot + "/.harness/qa/spec/launch.flow.json"], "\(paths)")
  }

  @Test(
    "the trial's heredocs written after `cd <slot> && mkdir -p rel && cd rel &&`, a shell function definition and newlines are named only under the slot, never under the session's starting directory — catches a function definition making the guard stop following the cd"
  )
  func capturedHeredocAfterFunctionDefinitionFollowsIt() throws {
    let call = try JSONDecoder().decode(
      RefusedCall.self, from: Fixture.data("Hooks/function-definition-after-cd-bash.json"))
    let slot = "/CLONE-spec.slot-4"
    let paths = ShellSyntax.writeTargets(in: call.command, directoryExists: { $0 == slot })
      .map(\.path)
    let denied = try #require(call.denial.split(separator: "`").dropFirst().first)
    #expect(denied == "\(call.cwd)/launch.flow.json")
    let flows = ["launch"] + (2...6).map { "flow-\($0)" }
    #expect(
      paths == flows.map { "\(slot)/.harness/qa/spec/\($0).flow.json" } + ["/dev/null"],
      "\(paths)")
  }

  @Test(
    "a shell function definition moves nothing when it is defined, so a write after it follows the line's cd, as it does after a call to a function whose body moves nothing or to none at all — catches a definition making the guard stop following the cd",
    arguments: [
      "cd /wt; f() { echo x; }; echo x > a",
      "cd /wt && f() { echo x; }\necho x > a",
      "cd /wt && f () { echo x; } && echo x > a",
      "cd /wt\nf() {\n  echo x\n}\nf\necho x > a",
      "cd /wt\nf()\n{\n  if true; then echo x; fi\n}\nf && echo x > a",
      "cd /wt && function f { echo x; }; f && echo x > a",
      "cd /wt && function f() { echo x; }; f; echo x > a",
      "cd /wt; f() { echo x; }; g() { f; }; g; echo x > a",
      "f() { cd /main; }; cd /wt && echo x > a",
      "cd /wt && f() { cd /main; }\ncat > a <<EOF\n$(f)\nEOF\n",
    ])
  func functionDefinitionKeepsTheCd(command: String) {
    #expect(Self.paths(command) == ["/wt/a"], "\(command)")
  }

  @Test(
    "a call to a function whose body may move or end the shell, one made through an expansion, and a definition the reading can't follow keep the starting directory in play — catches a called function's cd hiding a write from the starting directory",
    arguments: [
      "cd /wt && f() { cd /main; }; f; echo x > a",
      "cd /wt && f() { cd /main; }\nf\necho x > a",
      "cd /wt && function f { pushd /main; }; f && echo x > a",
      "cd /wt; f() { g; }; g() { cd /main; }; f; echo x > a",
      "cd /wt; f() { if true; then cd /main; fi; }; f; echo x > a",
      "cd /wt; f() { eval cd /main; }; f; echo x > a",
      "cd /wt; f() { exit; }; f || echo x > a",
      "cd /wt; f() { cd /main; }; if true; then f; fi; echo x > a",
      "cd /wt; f() { cd /main; }; $F; echo x > a",
      "cd /wt; f() { cd /main; }; command f; echo x > a",
      "cd /wt; f() ( cd /main ); echo x > a",
      "cd /wt; f() { cd /main; } > log; echo x > a",
      "cd /wt; function f() ( cd /main ); echo x > a",
    ])
  func calledFunctionThatMovesKeepsTheStart(command: String) {
    #expect(Self.paths(command).contains("a"), "\(command)")
  }

  @Test(
    "a write inside a function body is named under every cd of the line, since it runs wherever the function is called — catches a body write named only under the directory the definition sits in"
  )
  func writeInAFunctionBodyIsNamedUnderEveryCd() {
    let paths = Self.paths("cd /wt; f() { echo x > a; }; cd /main; f")
    #expect(paths.contains("/main/a"), "\(paths)")
    #expect(paths.contains("a"), "\(paths)")
  }

  @Test(
    "a cd into a directory an earlier `mkdir -p` of the line made is as certain as one into a directory that exists, through trailing assignments and a newline, while a write after the same chain into the main checkout stays there — catches a made directory leaving the starting directory in play",
    arguments: [
      ("mkdir -p /wt/s && cd /wt/s && B=x\ncat > a <<EOF\nEOF\n", ["/wt/s/a"]),
      ("mkdir -p /wt/s /wt/t && cd /wt/t && B=x && C=y\necho x > a", ["/wt/t/a"]),
      ("cd /wt && mkdir -p -m 755 s && cd s && B=x\necho x > a", ["/wt/s/a"]),
      ("cd /wt && B=x\necho x > a", ["/wt/a"]),
      ("mkdir -p /main/s && cd /main/s && B=x\necho x > a", ["/main/s/a"]),
    ])
  func cdIntoAMadeDirectoryIsCertain(command: String, expected: [String]) {
    #expect(Self.paths(command) == expected, "\(command)")
  }

  @Test(
    "a cd into a directory only a `mkdir` without -p, a mkdir to an expansion, or a mkdir behind `||` made keeps the starting directory in play — catches a mkdir that can fail being read as certain",
    arguments: [
      "mkdir /wt/s && cd /wt/s\necho x > a",
      "mkdir -p $D && cd /wt/s\necho x > a",
      "true || mkdir -p /wt/s && cd /wt/s\necho x > a",
      "mkdir -p /wt/s | cat && cd /wt/s\necho x > a",
    ])
  func cdIntoAnUncertainlyMadeDirectoryKeepsTheStart(command: String) {
    #expect(Self.paths(command).contains("a"), "\(command)")
  }

  @Test(
    "a relative cd moves on from the directory the shell is in, and a later line runs where the earlier lines may have left the shell — catches a write after a relative cd or a newline named under the wrong directory",
    arguments: [
      ("cd /wt && cd sub && echo x > a", ["/wt/sub/a"]),
      ("cd /wt && cd ./sub && cd .. && echo x > a", ["/wt/./sub/../a"]),
      ("cd /wt && mkdir -p s && cd s && \nO=1\ncat > a <<EOF\nEOF\n", ["/wt/s/a"]),
      ("cd /wt\ncd sub\necho x > a", ["/wt/sub/a", "/wt/a"]),
      ("cd sub && echo x > a", ["sub/a"]),
      ("cd /wt &&\necho x > a", ["/wt/a"]),
      ("ls; cd /wt\necho x > a", ["/wt/a"]),
      ("cd /wt || exit\necho x > a", ["/wt/a"]),
      ("cd /missing || exit 1\necho x > a", ["/missing/a"]),
      ("cd /wt; cd /missing; echo x > a", ["/missing/a", "/wt/a"]),
      ("cd /wt && ls | cat > a", ["/wt/a"]),
    ])
  func relativeCdAndLaterLinesFollowTheShell(command: String, expected: [String]) {
    #expect(Set(Self.paths(command)) == Set(expected), "\(command)")
  }

  @Test(
    "the trial's `sed -i` of a relative glob after `C=<plan checkout>; cd $C &&` is named only under the plan checkout, never under the session's starting directory — catches the guard refusing a write after a cd to a variable the same command assigned"
  )
  func capturedCdToAnAssignedVariableFollowsIt() throws {
    let call = try JSONDecoder().decode(
      RefusedCall.self, from: Fixture.data("Hooks/assigned-variable-cd-bash.json"))
    let plan = "/CLONE-spec"
    try #require(call.command.hasPrefix("C=\(plan); cd $C && "))
    let paths = ShellSyntax.writeTargets(in: call.command, directoryExists: { $0 == plan })
      .map(\.path)
    let denied = try #require(call.denial.split(separator: "`").dropFirst().first)
    let glob = "Packages/AppFeature/Sources/AppUI/*.swift"
    #expect(denied == "\(call.cwd)/\(glob)")
    #expect(paths == [plan + "/" + glob], "\(paths)")
  }

  @Test(
    "a cd to a variable an earlier command of the line assigned a literal path moves the shell there, however the variable is spelled — catches a write after `cd $VAR` named under the starting directory",
    arguments: [
      ("C=/wt; cd $C && echo x > a", ["/wt/a"]),
      ("C=\"/wt\"; cd \"$C\" && echo x > a", ["/wt/a"]),
      ("C=/wt\ncd ${C} && echo x > a", ["/wt/a"]),
      ("C=/wt; cd $C/sub && echo x > a", ["/wt/sub/a"]),
      ("export C=/wt; cd $C && echo x > a", ["/wt/a"]),
      ("C=/main; C=/wt; cd $C && echo x > a", ["/wt/a"]),
      ("R=/w; C=${R}t; cd $C && echo x > a", ["/wt/a"]),
      ("C=sub; cd /wt && cd $C && echo x > a", ["/wt/sub/a"]),
    ])
  func cdToAnAssignedVariableFollowsIt(command: String, expected: [String]) {
    #expect(Self.paths(command) == expected, "\(command)")
  }

  @Test(
    "a write into the main checkout after a relative cd and a newline is still named there — catches the carried directory hiding a main-checkout write"
  )
  func relativeCdIntoTheMainCheckoutStaysThere() {
    let paths = Self.paths("cd /main && mkdir -p s && cd s && \nO=1\ncat > a <<EOF\nEOF\n")
    #expect(paths.contains("/main/s/a"), "\(paths)")
    #expect(paths.allSatisfy { $0.hasPrefix("/main/") }, "\(paths)")
  }

  @Test(
    "a write after cd into the main checkout is named under it however the cd is joined, and a cd elsewhere names only that directory — catches a cd hiding a main-checkout write",
    arguments: [
      "cd /main && echo x > a", "cd /main\necho x > a", "cd /main; echo x > a",
      "pushd /main && echo x > a", "cd -P /main && cat a | tee a",
      "cd /wt && cd /main && echo x > a", "M=/main; cd $M && echo x > a",
      "M=\"/main\"\ncd \"${M}\" && echo x > a", "cd /main; f() { echo x; }; f; echo x > a",
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
