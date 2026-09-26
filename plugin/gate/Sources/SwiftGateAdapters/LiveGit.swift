import Foundation
import SwiftGateDomain

/// ``Git`` over the `git` CLI via a ``ProcessRunner``.
public struct LiveGit: Git, DiffReading {
  private let runner: any ProcessRunner
  private let repositoryRoot: String
  private let executable: String
  private let timeout: Duration

  /// - Parameter repositoryRoot: the worktree's top-level directory.
  public init(
    runner: any ProcessRunner, repositoryRoot: String, executable: String = "git",
    timeout: Duration = .seconds(60)
  ) {
    self.runner = runner
    self.repositoryRoot = repositoryRoot
    self.executable = executable
    self.timeout = timeout
  }

  public func changedFiles(since ref: String) async throws(GitError) -> [String] {
    try Self.validate(ref: ref)
    let tracked = try await run(["diff", "--name-only", "-z", "--no-renames", ref, "--"])
    let untracked = try await run([
      "ls-files", "-z", "--full-name", "--others", "--exclude-standard",
    ])
    let paths = Self.nulSeparated(tracked) + Self.nulSeparated(untracked)
    return Array(Set(paths)).sorted()
  }

  public func addedLines(since ref: String) async throws(GitError) -> [AddedLines] {
    try Self.validate(ref: ref)
    let diff = try await run([
      "diff", "--unified=0", "--no-color", "--no-ext-diff", "--no-textconv", "--no-relative",
      "--find-renames", "--diff-filter=ACMR", "--src-prefix=a/", "--dst-prefix=b/", ref, "--",
    ])
    var added = try UnifiedDiff.addedLines(in: diff)
    let untracked = Self.nulSeparated(
      try await run(["ls-files", "-z", "--full-name", "--others", "--exclude-standard"]))
    if !untracked.isEmpty {
      // Untracked paths are toplevel-relative; read them relative to this adapter's root.
      let prefix = try await workingDirectoryPrefix()
      let root = URL(filePath: repositoryRoot, directoryHint: .isDirectory)
      for path in untracked where path.hasPrefix(prefix) {
        let url = root.appending(path: String(path.dropFirst(prefix.count)))
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { continue }
        let newlines = data.count { $0 == UInt8(ascii: "\n") }
        let lines = newlines + (data.last == UInt8(ascii: "\n") ? 0 : 1)
        added.append(AddedLines(path: path, ranges: [1...lines]))
      }
    }
    return added.sorted { $0.path < $1.path }
  }

  public func stagedAddedLines() async throws(GitError) -> [AddedLines] {
    let diff = try await run([
      "diff", "--cached", "--unified=0", "--no-color", "--no-ext-diff", "--no-textconv",
      "--no-relative", "--find-renames", "--diff-filter=ACMR", "--src-prefix=a/",
      "--dst-prefix=b/",
    ])
    return try UnifiedDiff.addedLines(in: diff)
  }

  public func stagedContents(of paths: [String]) async throws(GitError) -> [String: String] {
    // `:<path>` names the index entry, root-relative.
    let blobs = try await catFileBatch(paths.map { ":\($0)" })
    var contents: [String: String] = [:]
    for (path, blob) in zip(paths, blobs) {
      guard let blob else {
        throw .commandFailed(
          arguments: ["cat-file", "--batch", ":\(path)"], status: .exited(0),
          stderr: "\(path) is not in the index")
      }
      contents[path] = String(decoding: blob, as: UTF8.self)
    }
    return contents
  }

  public func contents(of paths: [String], at ref: String) async throws(GitError) -> [String:
    String]
  {
    try Self.validate(ref: ref)
    let blobs = try await catFileBatch(paths.map { "\(ref):\($0)" })
    var contents: [String: String] = [:]
    for (path, blob) in zip(paths, blobs) {
      if let blob { contents[path] = String(decoding: blob, as: UTF8.self) }
    }
    return contents
  }

  /// One `cat-file --batch` process for every object name; `nil` where git found no object.
  private func catFileBatch(_ names: [String]) async throws(GitError) -> [Data?] {
    guard !names.isEmpty else { return [] }
    // `cat-file --batch` reads one object name per line, so a name with a newline cannot be sent.
    if let bad = names.first(where: { $0.contains("\n") }) {
      throw .unparseableOutput(command: "cat-file", detail: "path contains a newline: \(bad)")
    }
    let request = names.map { "\($0)\n" }.joined()
    let arguments = ["cat-file", "--batch"]
    let output = try await execute(arguments, standardInput: Data(request.utf8))
    guard output.status.isSuccess else { throw Self.failure(arguments, output) }
    if output.stdout.truncated {
      throw .unparseableOutput(command: "cat-file", detail: "output exceeded the capture cap")
    }
    return try CatFileBatch.blobs(in: output.stdout.bytes, requested: names.count)
  }

  public func contentHashes(of paths: [String]) async throws(GitError) -> [String: String] {
    let root = URL(filePath: repositoryRoot, directoryHint: .isDirectory)
    let existing = paths.filter {
      var isDirectory: ObjCBool = false
      return FileManager.default.fileExists(
        atPath: root.appending(path: $0).path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }
    var hashes: [String: String] = [:]
    for start in stride(from: 0, to: existing.count, by: Self.hashBatchSize) {
      let batch = Array(existing[start..<min(start + Self.hashBatchSize, existing.count)])
      let output = try await run(["hash-object", "--"] + batch)
      let lines = output.split(separator: "\n").map(String.init)
      guard lines.count == batch.count else {
        throw .unparseableOutput(
          command: "hash-object", detail: "expected \(batch.count) hashes, got \(lines.count)")
      }
      for (path, hash) in zip(batch, lines) { hashes[path] = hash }
    }
    return hashes
  }

  public func workingDirectoryPrefix() async throws(GitError) -> String {
    try await run(["rev-parse", "--show-prefix"]).trimmingCharacters(in: .newlines)
  }

  public func revision(_ ref: String) async throws(GitError) -> String? {
    try Self.validate(ref: ref)
    let arguments = ["rev-parse", "--verify", "--quiet", "\(ref)^{commit}"]
    let output = try await execute(arguments)
    // `--quiet` makes an unresolvable name exit 1 with no diagnostics.
    if output.status == .exited(1), output.stderr.bytes.isEmpty { return nil }
    guard output.status.isSuccess else { throw Self.failure(arguments, output) }
    return output.stdout.text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public func mergeBase(_ first: String, _ second: String) async throws(GitError) -> String? {
    try Self.validate(ref: first)
    try Self.validate(ref: second)
    let arguments = ["merge-base", first, second]
    let output = try await execute(arguments)
    // Exit 1 with no diagnostics is git's answer "no common ancestor"; bad refs exit 128.
    if output.status == .exited(1), output.stderr.bytes.isEmpty { return nil }
    guard output.status.isSuccess else { throw Self.failure(arguments, output) }
    return output.stdout.text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public func commonDirectory() async throws(GitError) -> String {
    let output = try await run(["rev-parse", "--git-common-dir"])
      .trimmingCharacters(in: .newlines)
    guard !output.isEmpty else {
      throw .unparseableOutput(command: "rev-parse", detail: "empty --git-common-dir")
    }
    // A relative answer is relative to the working directory git ran in: this adapter's root.
    let url =
      output.hasPrefix("/")
      ? URL(filePath: output, directoryHint: .isDirectory)
      : URL(filePath: repositoryRoot, directoryHint: .isDirectory).appending(
        path: output, directoryHint: .isDirectory)
    return CanonicalPath.of(url)
  }

  public func blobContents(_ id: String) async throws(GitError) -> String? {
    let isHexObjectName =
      (4...64).contains(id.utf8.count)
      && id.utf8.allSatisfy {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0)
          || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0)
      }
    guard isHexObjectName else { throw .invalidRef(id) }
    return try await catFileBatch([id]).first.flatMap { $0 }.map {
      String(decoding: $0, as: UTF8.self)
    }
  }

  public func revisions(of path: String) async throws(GitError) -> [String] {
    if path.isEmpty || path.contains("\0") { throw .invalidPath(path) }
    // `top` keeps the path toplevel-relative from a nested root; `literal` stops glob expansion.
    // `log.showSignature` would print signature text between the ids.
    let output = try await run([
      "-c", "log.showSignature=false", "log", "--follow", "--format=%H", "--",
      ":(top,literal)\(path)",
    ])
    let ids = output.split(separator: "\n").map(String.init)
    if let bad = ids.first(where: { !Self.isObjectID($0) }) {
      throw .unparseableOutput(command: "log", detail: "not a commit id: \(bad)")
    }
    return ids
  }

  public func trackedFiles(matching pattern: String) async throws(GitError) -> [String] {
    // `:(top)` anchors the pathspec at the repository root rather than this adapter's (possibly
    // nested) working directory, matching the toplevel-relative paths `--full-name` reports.
    let output = try await run(["ls-files", "-z", "--full-name", "--", ":(top)\(pattern)"])
    return Self.nulSeparated(output).sorted()
  }

  private static func isObjectID(_ text: String) -> Bool {
    (text.utf8.count == 40 || text.utf8.count == 64)
      && text.utf8.allSatisfy {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0)
          || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0)
      }
  }

  public func unifiedDiff(since ref: String) async throws(GitError) -> String {
    try Self.validate(ref: ref)
    return try await run([
      "diff", "--unified=3", "--no-color", "--no-ext-diff", "--no-textconv", "--relative",
      "--find-renames", "--src-prefix=a/", "--dst-prefix=b/", ref, "--", ".",
    ])
  }

  /// Keeps each argv well under `ARG_MAX` for large change sets.
  private static let hashBatchSize = 256

  /// Pins behavior that user or repository config could otherwise change. `GIT_OPTIONAL_LOCKS=0`
  /// stops read-only commands from taking `index.lock`, which concurrent sessions would contend on.
  private static let environmentOverlay: [String: String?] = [
    "LC_ALL": "C",
    "GIT_OPTIONAL_LOCKS": "0",
    "GIT_TERMINAL_PROMPT": "0",
    "GIT_EXTERNAL_DIFF": nil,
    "GIT_DIFF_OPTS": nil,
  ]

  private static let configOverrides = [
    "-c", "core.quotePath=true", "-c", "color.ui=never", "-c", "diff.noprefix=false",
    "-c", "diff.mnemonicPrefix=false",
  ]

  private func execute(_ arguments: [String], standardInput: Data? = nil) async throws(GitError)
    -> ProcessOutput
  {
    do {
      return try await runner.run(
        ProcessInvocation(
          executable: executable, arguments: Self.configOverrides + arguments,
          environmentOverlay: Self.environmentOverlay, workingDirectory: repositoryRoot,
          standardInput: standardInput, timeout: timeout))
    } catch {
      throw .process(error)
    }
  }

  private func run(_ arguments: [String]) async throws(GitError) -> String {
    let output = try await execute(arguments)
    guard output.status.isSuccess else { throw Self.failure(arguments, output) }
    if output.stdout.truncated {
      throw .unparseableOutput(command: arguments[0], detail: "output exceeded the capture cap")
    }
    return output.stdout.text
  }

  private static func failure(_ arguments: [String], _ output: ProcessOutput) -> GitError {
    .commandFailed(arguments: arguments, status: output.status, stderr: output.stderr.text)
  }

  private static func validate(ref: String) throws(GitError) {
    if ref.isEmpty || ref.hasPrefix("-") { throw .invalidRef(ref) }
  }

  private static func nulSeparated(_ text: String) -> [String] {
    text.split(separator: "\0").map(String.init)
  }
}

/// Parses `git cat-file --batch` output: per request, `<oid> <type> <size>\n<bytes>\n`, or
/// `<name> missing\n` / `<name> ambiguous\n` when the name resolves to no single object.
enum CatFileBatch {
  /// One entry per request, in order; `nil` where git found no object.
  static func blobs(in output: Data, requested: Int) throws(GitError) -> [Data?] {
    let bytes = [UInt8](output)
    var index = 0
    var blobs: [Data?] = []
    while blobs.count < requested {
      guard let newline = bytes[index...].firstIndex(of: UInt8(ascii: "\n")) else {
        throw .unparseableOutput(command: "cat-file", detail: "truncated header")
      }
      let header = String(decoding: bytes[index..<newline], as: UTF8.self)
      index = newline + 1
      if header.hasSuffix(" missing") || header.hasSuffix(" ambiguous") {
        blobs.append(nil)
        continue
      }
      let fields = header.split(separator: " ")
      guard fields.count == 3, let size = Int(fields[2]), size >= 0,
        index + size + 1 <= bytes.count
      else {
        throw .unparseableOutput(command: "cat-file", detail: "bad header: \(header)")
      }
      guard fields[1] == "blob" else {
        throw .unparseableOutput(command: "cat-file", detail: "not a blob: \(header)")
      }
      blobs.append(Data(bytes[index..<(index + size)]))
      index += size + 1
    }
    return blobs
  }
}

/// Parses `git diff --unified=0` output with fixed `a/`/`b/` prefixes.
enum UnifiedDiff {
  static func addedLines(in diff: String) throws(GitError) -> [AddedLines] {
    var result: [AddedLines] = []
    var currentPath: String?
    var ranges: [ClosedRange<Int>] = []

    func flush() {
      if let currentPath, !ranges.isEmpty {
        result.append(AddedLines(path: currentPath, ranges: ranges))
      }
      currentPath = nil
      ranges = []
    }

    // `+++ ` is a header only before a file's first hunk; after that it is an added content line
    // that happens to start with `++ `.
    var inFileHeader = false
    for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
      if line.hasPrefix("diff --git ") {
        flush()
        inFileHeader = true
      } else if inFileHeader, line.hasPrefix("+++ ") {
        let target = String(line.dropFirst(4))
        currentPath = target == "/dev/null" ? nil : try pathAfterPrefix(target)
      } else if line.hasPrefix("@@ ") {
        inFileHeader = false
        if currentPath != nil, let range = try addedRange(inHunkHeader: line) {
          ranges.append(range)
        }
      }
    }
    flush()
    return result
  }

  /// `@@ -a[,b] +c[,d] @@`: added lines are `c ..< c + d`; `d` defaults to 1 and 0 means none.
  private static func addedRange(inHunkHeader header: Substring) throws(GitError)
    -> ClosedRange<Int>?
  {
    let fields = header.split(separator: " ")
    guard fields.count >= 3, fields[2].hasPrefix("+") else {
      throw .unparseableOutput(command: "diff", detail: "bad hunk header: \(header)")
    }
    let parts = fields[2].dropFirst().split(separator: ",", omittingEmptySubsequences: false)
    guard let start = Int(parts[0]), parts.count <= 2 else {
      throw .unparseableOutput(command: "diff", detail: "bad hunk header: \(header)")
    }
    let count: Int
    if parts.count == 2 {
      guard let parsed = Int(parts[1]) else {
        throw .unparseableOutput(command: "diff", detail: "bad hunk header: \(header)")
      }
      count = parsed
    } else {
      count = 1
    }
    return count == 0 ? nil : start...(start + count - 1)
  }

  private static func pathAfterPrefix(_ target: String) throws(GitError) -> String {
    let unquoted = target.hasPrefix("\"") ? try unquote(target) : target
    guard unquoted.hasPrefix("b/") else {
      throw .unparseableOutput(command: "diff", detail: "unexpected path: \(target)")
    }
    return String(unquoted.dropFirst(2))
  }

  /// Reverses git's C-style path quoting, including octal-escaped UTF-8 bytes.
  static func unquote(_ quoted: String) throws(GitError) -> String {
    let bytes = Array(quoted.utf8)
    guard bytes.count >= 2, bytes.first == UInt8(ascii: "\""), bytes.last == UInt8(ascii: "\"")
    else {
      throw .unparseableOutput(command: "diff", detail: "bad quoted path: \(quoted)")
    }
    var output: [UInt8] = []
    var index = 1
    let end = bytes.count - 1
    while index < end {
      let byte = bytes[index]
      guard byte == UInt8(ascii: "\\") else {
        output.append(byte)
        index += 1
        continue
      }
      index += 1
      guard index < end else {
        throw .unparseableOutput(command: "diff", detail: "bad quoted path: \(quoted)")
      }
      let escaped = bytes[index]
      let simple: [UInt8: UInt8] = [
        UInt8(ascii: "a"): 0x07, UInt8(ascii: "b"): 0x08, UInt8(ascii: "t"): 0x09,
        UInt8(ascii: "n"): 0x0A, UInt8(ascii: "v"): 0x0B, UInt8(ascii: "f"): 0x0C,
        UInt8(ascii: "r"): 0x0D, UInt8(ascii: "\""): 0x22, UInt8(ascii: "\\"): 0x5C,
      ]
      if let mapped = simple[escaped] {
        output.append(mapped)
        index += 1
      } else if index + 2 < end,
        let octal = UInt8(String(decoding: bytes[index...(index + 2)], as: UTF8.self), radix: 8)
      {
        output.append(octal)
        index += 3
      } else {
        throw .unparseableOutput(command: "diff", detail: "bad escape in path: \(quoted)")
      }
    }
    return String(decoding: output, as: UTF8.self)
  }
}
