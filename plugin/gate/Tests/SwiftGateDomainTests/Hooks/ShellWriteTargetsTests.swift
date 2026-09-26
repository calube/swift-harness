import SwiftGateDomain
import Testing

@Suite("Shell write targets")
struct ShellWriteTargetsTests {
  @Test(
    "output redirections name their target, and a descriptor duplication names none — catches `> ledger.json` slipping past the file guards",
    arguments: [
      ("echo '{}' > p/ledger.json", ["p/ledger.json"]),
      ("echo x >> docs/designs/d.md", ["docs/designs/d.md"]),
      ("echo x >| f", ["f"]),
      ("make &> build.log", ["build.log"]),
      ("make &>> build.log", ["build.log"]),
      ("make 2> err.log", ["err.log"]),
      ("make 2>>err.log", ["err.log"]),
      ("cat <> f", ["f"]),
      ("make >& all.log", ["all.log"]),
      ("> empty.txt", ["empty.txt"]),
      ("make 2>&1", []),
      ("make >&2", []),
      ("make 1>&-", []),
      ("sort < in.txt", []),
      ("cat <<< '> x'", []),
    ])
  func redirections(command: String, expected: [String]) {
    #expect(ShellSyntax.writeTargets(in: command) == expected)
  }

  @Test(
    "tee, the destinations of cp, mv, install and ln, and the operands of rm, truncate, touch and dd are write targets; sources and option values are not — catches `cp x Package.resolved` and `rm -rf __Snapshots__` passing",
    arguments: [
      ("cat x | tee p/ledger.json", ["p/ledger.json"]),
      ("tee -a one two < in", ["one", "two"]),
      ("cp -f /tmp/x pkg/Package.resolved", ["pkg/Package.resolved", "pkg/Package.resolved/x"]),
      ("cp a b dir/", ["dir/", "dir/a", "dir/b"]),
      ("cp -t dir a", ["dir", "dir/a"]),
      ("cp --target-directory=dir a", ["dir", "dir/a"]),
      ("mv old.json new.json", ["new.json", "new.json/old.json", "old.json"]),
      ("install -m 644 src dst", ["dst", "dst/src"]),
      ("install -d a b", ["a", "b"]),
      ("ln -sf target link", ["link", "link/target"]),
      ("ln -s /abs/target", ["target"]),
      ("rm -rf a b", ["a", "b"]),
      ("rm -- -odd", ["-odd"]),
      ("rmdir d", ["d"]),
      ("unlink f", ["f"]),
      ("truncate -s 0 f", ["f"]),
      ("truncate --size=0 f", ["f"]),
      ("touch -t 202601010000 f", ["f"]),
      ("dd if=/dev/zero of=out bs=1 count=1", ["out"]),
    ])
  func writingCommands(command: String, expected: [String]) {
    #expect(ShellSyntax.writeTargets(in: command) == expected)
  }

  @Test(
    "sed -i and perl -i name the files they rewrite, and without -i they name nothing — catches in-place edits bypassing the guards, or every sed read being denied",
    arguments: [
      ("sed -i '' s/a/b/ f", ["f"]),
      ("sed -i s/a/b/ f g", ["f", "g"]),
      ("sed -i.bak -e s/a/b/ f", ["f"]),
      ("sed -E -i '' -e s/a/b/ -e s/c/d/ f", ["f"]),
      ("sed --in-place s/a/b/ f", ["f"]),
      ("sed -ni '' p f", ["f"]),
      ("sed s/a/b/ f", []),
      ("sed -n '/>/p' f", []),
      ("perl -pi -e 's/a/b/' f", ["f"]),
      ("perl -i.bak -pe 's/a/b/' f g", ["f", "g"]),
      ("perl -i script.pl f", ["f"]),
      ("perl -pe 's/a/b/' f", []),
      ("perl -e 'open(F, \">x\")'", []),
    ])
  func inPlaceEditors(command: String, expected: [String]) {
    #expect(ShellSyntax.writeTargets(in: command) == expected)
  }

  @Test(
    "targets are found across ;, &&, ||, pipes, subshells, command substitutions, backticks, sh -c and wrappers — catches a write hidden behind an ordinary first command"
  )
  func compoundCommands() {
    let targets = ShellSyntax.writeTargets(
      in:
        "ls; echo > a && echo >> b || cat | tee c; (rm d) && echo $(echo > e) `touch f` "
        + "&& bash -c 'echo > g' && sudo cp x h")
    #expect(targets.sorted() == ["a", "b", "c", "d", "e", "f", "g", "h", "h/x"])
  }

  @Test(
    "a relative target after a literal cd is also named under that directory — catches `cd plans/demo && echo > ledger.json` judged only at the starting directory"
  )
  func changedDirectory() {
    #expect(
      ShellSyntax.writeTargets(in: "cd /c/plans/demo && echo {} > ledger.json && echo > /tmp/x")
        == ["ledger.json", "/c/plans/demo/ledger.json", "/tmp/x"])
  }

  @Test(
    "quoted angle brackets, reads, command sources and heredoc text are not writes — catches the guard denying commits, greps and backups that only mention a guarded file",
    arguments: [
      ("git commit -m \"note: echo {} > ledger.json\"", [String]()),
      ("grep '>' file", []),
      ("grep -r \"> Package.resolved\" docs", []),
      ("cat plan.json", []),
      ("cp ledger.json /tmp/backup", ["/tmp/backup", "/tmp/backup/ledger.json"]),
      ("swift build 2>&1 | tee build.log", ["build.log"]),
      ("echo hi > /tmp/x", ["/tmp/x"]),
      ("make > /dev/null 2>&1", ["/dev/null"]),
      (
        "cat > notes.md <<'EOF'\necho {} > Package.resolved\nrm -rf __Snapshots__\nEOF\necho done",
        ["notes.md"]
      ),
      ("cat <<-EOF > out\n\techo > x\n\tEOF", ["out"]),
    ])
  func notWrites(command: String, expected: [String]) {
    #expect(ShellSyntax.writeTargets(in: command) == expected)
  }

  @Test(
    "interpreter one-liners, heredoc scripts, and variable or substituted targets yield no target rather than a wrong one — catches a guess at a path the shell hasn't expanded",
    arguments: [
      "python3 -c 'open(\"p/ledger.json\",\"w\").write(\"{}\")'",
      "node -e 'fs.writeFileSync(\"p/ledger.json\", \"{}\")'",
      "echo {} > $LEDGER",
      "echo {} > \"$(git rev-parse --git-common-dir)/ledger.json\"",
      "echo {} > `pwd`/ledger.json",
      "python3 <<EOF\nopen('p/ledger.json', 'w')\nEOF",
    ])
  func unresolvable(command: String) {
    #expect(ShellSyntax.writeTargets(in: command) == [])
  }

  @Test(
    "a redirect target is not an argument of the command — catches `cp a b > log` judged as copying into log"
  )
  func redirectsLeaveArguments() {
    let commands = ShellSyntax.simpleCommands(in: "cp a b > log 2>&1")
    #expect(commands.map(\.arguments) == [["a", "b"]])
    #expect(commands.map(\.redirectTargets) == [["log"]])
  }

  @Test(
    "heredoc bodies are still checked as commands by the Bash guard — catches `bash <<EOF` hiding a raw xcodebuild"
  )
  func heredocBodyStillGuarded() {
    #expect(
      BashGuard.evaluate("bash <<'EOF'\nxcodebuild -scheme App build\nEOF")?.ruleID
        == BashGuard.rawXcodebuildRuleID)
  }
}
