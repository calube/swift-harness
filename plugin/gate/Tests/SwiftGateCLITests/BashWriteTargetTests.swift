import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

/// Replays the recorded live Bash payload with its command swapped, from the probe repository's
/// root, against `Package.resolved`: a guarded path any session is denied, so each shell
/// construct is judged without plan state.
private struct ResolvedWrite {
  static let recordedCommand = "\"swiftgate check --tier fast 2>&1 | tail -25\""
  static let resolved = "Packages/Feed/Package.resolved"

  let harness: HookHarness

  init() throws {
    harness = try HookHarness()
    try harness.repository.write(Self.resolved, "{}\n")
  }

  func remove() { harness.repository.remove() }

  /// `command` with `@R` standing for the guarded `Package.resolved`.
  func decision(_ command: String) async throws -> String? {
    let spelled = command.replacingOccurrences(of: "@R", with: Self.resolved)
    let quoted = String(decoding: try JSONEncoder().encode(spelled), as: UTF8.self)
    let (result, _) = try await harness.run(
      .preToolUse, "pre-tool-use-bash-allowed", replacing: [Self.recordedCommand: quoted])
    guard result.stdout != nil else { return nil }
    let output = try harness.json(result)["hookSpecificOutput"] as? [String: String]
    return output?["permissionDecision"]
  }
}

@Suite("PreToolUse Bash write targets")
struct BashWriteTargetTests {
  @Test(
    "redirections, tee, cp/mv/install/ln destinations, what mv moves away, rm/rmdir/unlink/truncate/touch operands, dd of=, sed -i and perl -i files are judged as writes, anywhere in a compound command — catches `echo {} > Package.resolved` and its shell variants passing",
    arguments: [
      "echo {} > @R", "echo {} >> @R", "echo {} >| @R", "make &> @R", "make &>> @R", "make 2> @R",
      "make 2>>@R", "cat <> @R", "make >& @R", "> @R",
      "cat /tmp/x | tee @R", "tee -a /tmp/one @R < /tmp/in",
      "cp -f /tmp/x @R", "cp /tmp/Package.resolved Packages/Feed/",
      "cp /tmp/Package.resolved Packages/Feed", "cp -t Packages/Feed /tmp/Package.resolved",
      "cp --target-directory=Packages/Feed /tmp/Package.resolved",
      "mv /tmp/x @R", "mv @R /tmp/x", "install -m 644 /tmp/x @R", "install -d @R",
      "ln -sf /tmp/x @R",
      "ln -s /tmp/Package.resolved",
      "rm -rf @R", "rm -- @R", "rmdir @R", "unlink @R", "truncate -s 0 @R", "truncate --size=0 @R",
      "touch -t 202601010000 @R", "dd if=/dev/zero of=@R count=0",
      "sed -i '' s/a/b/ @R", "sed -i s/a/b/ /tmp/f @R", "sed -i.bak -e s/a/b/ @R",
      "sed -E -i '' -e s/a/b/ -e s/c/d/ @R", "sed --in-place s/a/b/ @R", "sed -ni '' p @R",
      "perl -pi -e 's/a/b/' @R", "perl -i.bak -pe 's/a/b/' /tmp/f @R", "perl -i script.pl @R",
      "ls; echo > /tmp/a && echo x > @R", "false || tee @R", "cat /tmp/x | tee /tmp/y | tee @R",
      "(rm @R)", "echo $(echo > @R)", "echo `touch @R`", "bash -c 'echo > @R'", "sudo cp /tmp/x @R",
      "cd Packages && echo {} > Feed/Package.resolved",
      "git checkout -- @R", "git checkout HEAD @R", "git restore --source HEAD @R", "git rm -q @R",
      "git mv @R /tmp/x", "git -C Packages/Feed restore Package.resolved",
    ])
  func writesDenied(command: String) async throws {
    let scenario = try ResolvedWrite()
    defer { scenario.remove() }

    #expect(try await scenario.decision(command) == "deny", "\(command)")
  }

  @Test(
    "a command that only reads, quotes, sources, discards to /dev/null or writes elsewhere passes, while its writing twin is denied — catches the guard denying commits, greps, backups and builds that mention a guarded file",
    arguments: [
      ("echo {} > @R", "git commit -m \"note: echo {} > @R\""),
      ("grep x /tmp/f > @R", "grep '>' @R"),
      ("sed -i '' s/a/b/ @R", "sed s/a/b/ @R"),
      ("sed -i '' s/a/b/ @R", "sed -n '/>/p' @R"),
      ("perl -pi -e 's/a/b/' @R", "perl -pe 's/a/b/' @R"),
      ("cp /tmp/x @R", "cp @R /tmp/swiftgate-backup-that-does-not-exist"),
      ("cp /tmp/x @R", "cp @R /tmp/swiftgate-backup-that-does-not-exist > /tmp/cp.log 2>&1"),
      ("truncate -s 0 @R", "truncate -r @R /tmp/x"),
      ("touch @R", "touch -r @R /tmp/x"),
      ("dd of=@R", "dd if=@R of=/tmp/x"),
      ("make > @R", "make > /dev/null 2>&1"),
      ("make 2> @R", "make 2>&1 >&2"),
      ("swift build 2>&1 | tee @R", "swift build 2>&1 | tee build.log"),
      ("echo hi > @R", "echo hi > /tmp/x"),
      ("rm @R", "cat @R"),
      ("git checkout -- @R", "git checkout main"),
      ("git restore @R", "git diff -- @R"),
      ("git rm @R", "git rm -r --cached Sources"),
      ("echo {} > @R", "cat <<< '> @R'"),
      (
        "cat > @R <<'EOF'\nx\nEOF",
        "cat > notes.md <<'EOF'\necho {} > @R\nrm -rf __Snapshots__\nEOF"
      ),
      ("cat <<-EOF > @R\n\tx\n\tEOF", "cat <<-EOF > out.txt\n\techo > @R\n\tEOF"),
      (
        "cat <<-EOF > out.txt\n\tx\n\tEOF\necho {} > @R",
        "cat <<EOF > out.txt\n\tEOF\necho {} > @R\nEOF"
      ),
    ])
  func lookAlikesPass(denied: String, allowed: String) async throws {
    let scenario = try ResolvedWrite()
    defer { scenario.remove() }

    #expect(try await scenario.decision(denied) == "deny", "\(denied)")
    #expect(try await scenario.decision(allowed) == nil, "\(allowed)")
  }
}
