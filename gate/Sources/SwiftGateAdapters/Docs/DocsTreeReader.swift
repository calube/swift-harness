import Foundation
import SwiftGateDomain

/// `docs-lint`'s one reader of the docs tree (interfaces note, wave 8): builds the whole corpus —
/// every `.md` file under `docs/` plus root `AGENTS.md` — into `DocsLintPolicy.ScannedDocument`,
/// the single type both ``DocsLintPolicy`` and ``DocsLintReferences`` read, and separately lists
/// every file `git` tracks for ``DocsLintReferences``' relative-link resolution. Nothing else in
/// `docs-lint-command` walks the filesystem or shells out to `git` for this input.
public struct DocsTreeReader: Sendable {
  /// What `docs-lint` needs from disk and from git, read once.
  public struct Corpus: Sendable, Equatable {
    public let documents: [DocsLintPolicy.ScannedDocument]
    public let repoPaths: Set<String>

    public init(documents: [DocsLintPolicy.ScannedDocument], repoPaths: Set<String>) {
      self.documents = documents
      self.repoPaths = repoPaths
    }
  }

  /// Every case is an environment or input problem, never evidence about the docs themselves:
  /// `docs-lint` reports this as a blocked run (exit 2), not a finding.
  public enum ReadFailure: Error, Sendable, Equatable, CustomStringConvertible {
    case unreadable(path: String, reason: String)
    case git(reason: String)

    public var verdict: Verdict { .blocked }

    public var description: String {
      switch self {
      case .unreadable(let path, let reason): "\(path): cannot read (\(reason))"
      case .git(let reason): "git ls-files failed: \(reason)"
      }
    }
  }

  private static let docsDirectoryName = "docs"
  private static let agentsFileName = "AGENTS.md"

  private let runner: any ProcessRunner
  private let gitExecutable: String
  private let timeout: Duration

  public init(
    runner: any ProcessRunner, gitExecutable: String = "git", timeout: Duration = .seconds(30)
  ) {
    self.runner = runner
    self.gitExecutable = gitExecutable
    self.timeout = timeout
  }

  /// - Parameter repositoryRoot: the worktree root `docs/` and `AGENTS.md` are read relative to,
  ///   and the working directory `git ls-files` runs in.
  public func read(repositoryRoot: URL) async throws(ReadFailure) -> Corpus {
    var documents = try scanDocsDirectory(repositoryRoot: repositoryRoot)
    if let agents = try readAgentsFile(repositoryRoot: repositoryRoot) {
      documents.append(agents)
    }
    let repoPaths = try await trackedFiles(repositoryRoot: repositoryRoot)
    return Corpus(documents: documents.sorted { $0.path < $1.path }, repoPaths: repoPaths)
  }

  // MARK: - Filesystem: docs/ and AGENTS.md

  /// Absent entirely, `docs/` scans as empty rather than an error — a repository that hasn't
  /// written any docs yet is a normal (if uninteresting) input, not a malformed one.
  private func scanDocsDirectory(repositoryRoot: URL) throws(ReadFailure)
    -> [DocsLintPolicy.ScannedDocument]
  {
    let docsRoot = repositoryRoot.appending(
      path: Self.docsDirectoryName, directoryHint: .isDirectory)
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: docsRoot.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else { return [] }
    var documents: [DocsLintPolicy.ScannedDocument] = []
    try walk(docsRoot, repoPath: Self.docsDirectoryName, into: &documents)
    return documents
  }

  /// Recurses into real directories; a symlinked directory is never entered, so a symlink cycle
  /// (including one pointing back at an ancestor) can never loop — it simply isn't a doc. A
  /// symlinked file is read like any other, at its own path (never the target's), which is also
  /// what keeps a repo-root `CLAUDE.md -> AGENTS.md` symlink from ever reaching this scan at all:
  /// it lives outside `docs/` and isn't spelled `AGENTS.md`, so nothing here ever visits it —
  /// `AGENTS.md` is counted exactly once, by ``readAgentsFile``.
  private func walk(
    _ directory: URL, repoPath: String, into documents: inout [DocsLintPolicy.ScannedDocument]
  ) throws(ReadFailure) {
    let entries: [URL]
    do {
      entries = try FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey],
        options: [.skipsHiddenFiles])
    } catch {
      throw .unreadable(path: repoPath, reason: error.localizedDescription)
    }
    for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
      let childPath = "\(repoPath)/\(entry.lastPathComponent)"
      // `URLResourceValues.isDirectory` answers about the symlink itself, not its target (a
      // symlink is never reported as a directory, even one pointing at a real directory) — so
      // whether to recurse has to ask `FileManager` directly, which resolves the link.
      let isSymbolicLink =
        (try? entry.resourceValues(forKeys: [.isSymbolicLinkKey]))?
        .isSymbolicLink ?? false
      var targetIsDirectory: ObjCBool = false
      FileManager.default.fileExists(atPath: entry.path, isDirectory: &targetIsDirectory)
      if targetIsDirectory.boolValue {
        if isSymbolicLink { continue }
        try walk(entry, repoPath: childPath, into: &documents)
        continue
      }
      guard entry.lastPathComponent.hasSuffix(".md") else { continue }
      documents.append(try readDocument(at: entry, path: childPath))
    }
  }

  private func readAgentsFile(repositoryRoot: URL) throws(ReadFailure)
    -> DocsLintPolicy.ScannedDocument?
  {
    let url = repositoryRoot.appending(path: Self.agentsFileName, directoryHint: .notDirectory)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return try readDocument(at: url, path: Self.agentsFileName)
  }

  private func readDocument(at url: URL, path: String) throws(ReadFailure)
    -> DocsLintPolicy.ScannedDocument
  {
    let data: Data
    do {
      data = try Data(contentsOf: url)
    } catch {
      throw .unreadable(path: path, reason: error.localizedDescription)
    }
    guard let text = String(data: data, encoding: .utf8) else {
      throw .unreadable(path: path, reason: "not valid UTF-8")
    }
    return DocsLintPolicy.ScannedDocument(path: path, rawText: text, markdown: .parse(text))
  }

  // MARK: - Git: every tracked file

  /// `-z` makes git emit NUL-terminated, always-unquoted paths regardless of `core.quotePath`;
  /// `--full-name` keeps them repo-root-relative even if a future caller runs this from a
  /// subdirectory.
  private func trackedFiles(repositoryRoot: URL) async throws(ReadFailure) -> Set<String> {
    let invocation = ProcessInvocation(
      executable: gitExecutable, arguments: ["ls-files", "-z", "--full-name"],
      workingDirectory: repositoryRoot.path, timeout: timeout)
    let output: ProcessOutput
    do {
      output = try await runner.run(invocation)
    } catch {
      throw .git(reason: "\(error)")
    }
    guard output.status.isSuccess else {
      let stderr = output.stderr.text.trimmingCharacters(in: .whitespacesAndNewlines)
      throw .git(reason: stderr.isEmpty ? "exit \(output.status)" : stderr)
    }
    guard !output.stdout.truncated else {
      throw .git(reason: "output exceeded the capture cap")
    }
    let paths = output.stdout.text.split(separator: "\0", omittingEmptySubsequences: true)
    return Set(paths.map(String.init))
  }
}
