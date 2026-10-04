import Foundation
import SwiftGateDomain

/// Gathers a `context-pack` role's raw inputs from disk into ``ContextSource`` values and other
/// domain inputs. Every slicing decision — which lines of a source end up in the pack — stays in
/// `ContextPack` (`SwiftGateDomain`); this type only reads files and hands their untouched
/// contents to the domain builders.
public enum ContextPackFiles {
  public enum Failure: Error, Sendable, Equatable {
    case unreadable(path: String)
  }

  /// Resolves `path` against `root` (repo-relative paths only; the CLI never accepts an absolute
  /// path so a pack can't cite the operator's own machine — worker-brief `docs-lint.local-path`).
  public static func resolve(_ path: String, root: URL) -> URL {
    root.appending(path: path)
  }

  /// `path` as the repository-relative path a pack cites: unchanged when relative, the part
  /// below `root` when absolute inside it (symlinks resolved on both sides), and `nil` when
  /// absolute outside it, since a pack citing it would carry the operator's machine path.
  public static func repositoryPath(_ path: String, root: URL) -> String? {
    guard path.hasPrefix("/") else { return path }
    let base = root.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
    let file = URL(filePath: path).standardizedFileURL.resolvingSymlinksInPath()
      .path(percentEncoded: false)
    let prefix = base.hasSuffix("/") ? base : base + "/"
    guard file.hasPrefix(prefix), file.count > prefix.count else { return nil }
    return String(file.dropFirst(prefix.count))
  }

  /// Reads a whole file verbatim as a labelled ``ContextSource``. `label` is what the pack's
  /// slices will cite as their source, so callers pass the same string a reader would expect to
  /// see next to a quoted line (usually `path` itself).
  public static func read(label: String, path: String, root: URL) -> Result<ContextSource, Failure>
  {
    guard let text = try? String(contentsOf: resolve(path, root: root), encoding: .utf8) else {
      return .failure(.unreadable(path: path))
    }
    return .success(ContextSource(label: label, rawText: text))
  }
}

/// Finds one claim's exact `claims.jsonl` line by id, so its raw text can travel into a pack
/// unmodified (never a re-serialization of the decoded value).
public enum ContextPackClaims {
  public static func rawLine(forID id: String, in claimsRawText: String) -> String? {
    let decoder = JSONDecoder()
    for line in claimsRawText.split(separator: "\n", omittingEmptySubsequences: true) {
      guard let data = line.data(using: .utf8),
        let claim = try? decoder.decode(Claim.self, from: data)
      else { continue }
      if claim.id == id { return String(line) }
    }
    return nil
  }
}

/// Reads the file a claim's citation points at, so a claim checker or evidence auditor pack can
/// carry the cited excerpt (`CitationExcerptSlicer` does the actual excerpting, in the domain
/// layer — this only locates and reads the right file for each citation kind).
public enum ContextPackCitationSource {
  public enum Failure: Error, Sendable, Equatable {
    case unreadable(path: String)
  }

  /// - Returns: the source's label (what the pack will cite) and its raw text.
  public static func resolve(
    _ citation: Citation, evidenceLayout: EvidenceLayout, repoRoot: URL
  ) -> Result<(label: String, rawText: String), Failure> {
    switch citation.kind {
    case .file:
      let path = filePath(fromLoc: citation.loc)
      guard
        let text = try? String(
          contentsOf: ContextPackFiles.resolve(path, root: repoRoot), encoding: .utf8)
      else { return .failure(.unreadable(path: path)) }
      return .success((label: path, rawText: text))
    case .snapshot, .capture, .probe:
      let path = "\(evidenceLayout.root)/\(citation.loc)"
      guard
        let text = try? String(
          contentsOf: ContextPackFiles.resolve(path, root: repoRoot), encoding: .utf8)
      else { return .failure(.unreadable(path: path)) }
      return .success((label: citation.loc, rawText: text))
    case .answer:
      let path = evidenceLayout.answersFile
      guard
        let text = try? String(
          contentsOf: ContextPackFiles.resolve(path, root: repoRoot), encoding: .utf8)
      else { return .failure(.unreadable(path: path)) }
      return .success((label: "answers.jsonl", rawText: text))
    }
  }

  /// `loc` for a `file` citation is `<path>:L<a>[-L<b>]`; the path is everything before `:L`.
  private static func filePath(fromLoc loc: String) -> String {
    guard let marker = loc.range(of: ":L") else { return loc }
    return String(loc[loc.startIndex..<marker.lowerBound])
  }
}

/// Loads `ledger.json`, whole or one task by id, for a worker pack.
public enum ContextPackLedger {
  public enum LoadFailure: Error, Sendable, Equatable {
    case unreadable(path: String)
    case malformed(path: String)
  }

  public enum Failure: Error, Sendable, Equatable {
    case unreadable(path: String)
    case malformed(path: String)
    case taskNotFound(id: String, ledgerPath: String)
  }

  /// The whole decoded ledger — for a worker pack's dependency-notes section, which needs
  /// ``Ledger/waves`` to order a task's `deps`, not just that one task's own entry.
  public static func load(ledgerPath: String, root: URL) -> Result<Ledger, LoadFailure> {
    guard let data = try? Data(contentsOf: ContextPackFiles.resolve(ledgerPath, root: root)) else {
      return .failure(.unreadable(path: ledgerPath))
    }
    guard let ledger = try? LedgerJSON.decode(data) else {
      return .failure(.malformed(path: ledgerPath))
    }
    return .success(ledger)
  }

  public static func task(id: String, ledgerPath: String, root: URL) -> Result<LedgerTask, Failure>
  {
    switch load(ledgerPath: ledgerPath, root: root) {
    case .failure(.unreadable(let path)): return .failure(.unreadable(path: path))
    case .failure(.malformed(let path)): return .failure(.malformed(path: path))
    case .success(let ledger):
      guard let task = ledger.tasks.first(where: { $0.id == id }) else {
        return .failure(.taskNotFound(id: id, ledgerPath: ledgerPath))
      }
      return .success(task)
    }
  }
}

/// Reads one dependency's task-return notes for a worker pack's dependency-notes section (spec
/// §5.3): `returns/<task>.json` under a build run's directory, which sits beside `ledger.json`
/// under the same plan directory (spec §4: `…/plans/<plan>/{ledger.json, build/<run>/}`) — derived
/// from `ledgerPath`'s own parent, never from a second, independently-supplied plan path that
/// could silently name a different plan than the ledger it was read from. The file decodes as a
/// whole ``TaskReturn``, the shape `build check-return` passed before the build skill stored it, so
/// a partial or hand-made return never feeds a dependent's pack.
public enum ContextPackTaskReturn {
  public enum Failure: Error, Sendable, Equatable {
    case unreadable(path: String)
    case malformed(path: String)
  }

  public static func notes(
    forTask taskID: String, buildRun runID: String, ledgerPath: String, root: URL
  ) -> Result<String, Failure> {
    let planDirectory = ledgerPath.lastIndex(of: "/").map { String(ledgerPath[..<$0]) } ?? ""
    let relativePath =
      (planDirectory.isEmpty ? "" : planDirectory + "/") + "build/\(runID)/returns/\(taskID).json"
    guard let data = try? Data(contentsOf: ContextPackFiles.resolve(relativePath, root: root))
    else {
      return .failure(.unreadable(path: relativePath))
    }
    guard let taskReturn = try? TaskReturnJSON.decode(data), taskReturn.task == taskID else {
      return .failure(.malformed(path: relativePath))
    }
    return .success(taskReturn.notes)
  }

  /// The same notes from a plan directory given whole, as a brownfield plan's lives under the git
  /// common dir rather than the repository.
  public static func notes(forTask taskID: String, buildRun runID: String, planDirectory: URL)
    -> Result<String, Failure>
  {
    .failure(.unreadable(path: planDirectory.path))
  }
}

/// Which `docs/standards.md` anchors are in scope for a set of module kinds (spec §5.10: drafter
/// and worker packs both carry "standards anchors for the module kinds in scope"). A gathering
/// decision, not a slicing one — `MarkdownAnchorSlicer` still does the actual cut.
public enum ContextPackModuleKindAnchors {
  /// Every kind's Core shape and use-when guidance lives in the standards doc's Architecture
  /// section; three kinds also have a dedicated section worth adding.
  public static func anchors(for kinds: [ModuleKind]) -> [String] {
    guard !kinds.isEmpty else { return [] }
    var anchors: [String] = ["2-architecture"]
    for kind in kinds {
      let extra: String?
      switch kind {
      case .engine: extra = "8-engine-modules"
      case .client: extra = "3-dependencies-and-clients"
      case .render: extra = "6-swiftui-performance"
      case .feature, .library, .testSupport: extra = nil
      }
      if let extra, !anchors.contains(extra) {
        anchors.append(extra)
      }
    }
    return anchors
  }
}
