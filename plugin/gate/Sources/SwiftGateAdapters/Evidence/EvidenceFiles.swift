import Foundation
import SwiftGateDomain

/// ``EvidenceSources`` over one repository, for `evidence check`.
///
/// Under `--at <ref>`, cited repo files and `Package.resolved` come from the ref through ``Git``,
/// never a checkout. Two things still come from the working tree: `.build/…` files, which git
/// never tracks, so the ref has no copy of a package checkout to read; and everything under
/// `<slug>.evidence/`, which is the design's own record of what it relies on (a probe re-run or a
/// fresh capture must count before it's committed). Staleness is a property of the cited
/// sources, not of the record that cites them.
public struct EvidenceFiles: EvidenceSources, Sendable {
  public enum LoadError: Error, Sendable, Equatable {
    case claimsFileMissing(path: String)
    case claimsFileUnreadable(path: String, detail: String)
    /// `line` is 1-based.
    case malformedClaimLine(path: String, line: Int)
    case refNotFound(String)
    case git(GitError)
  }

  private let root: URL
  private let evidenceRoot: String
  /// The cited repo files at the ref, by repo-relative path; `nil` when reading the working tree.
  private let filesAtRef: [String: String]?
  public let packageResolved: Data?
  public let sdkVersion: String?

  public func repoFile(_ path: String) -> String? {
    if let filesAtRef, !Self.isUntrackedBuildPath(path) { return filesAtRef[path] }
    return Self.read(root.appending(path: path)).map { String(decoding: $0, as: UTF8.self) }
  }

  /// Read from the working tree in both modes: a link git tracks is a link on disk too.
  public func repoSymlink(_ path: String) -> String? {
    PathPrefixes.of(path).first { prefix in
      (try? FileManager.default.destinationOfSymbolicLink(
        atPath: root.appending(path: prefix).path)) != nil
    }
  }

  /// Every directory from the repo root down counts, the evidence root's own included.
  public func evidenceSymlink(_ path: String) -> String? {
    repoSymlink(evidenceRoot + "/" + path)
  }

  public func evidenceFile(_ path: String) -> Data? {
    Self.read(root.appending(path: evidenceRoot).appending(path: path))
  }

  /// Sources for a plain check: every file as it is on disk now.
  public static func workingTree(
    root: URL, layout: EvidenceLayout, packageResolvedPath: String, sdkVersion: String?
  ) -> EvidenceFiles {
    EvidenceFiles(
      root: root, evidenceRoot: layout.root, filesAtRef: nil,
      packageResolved: read(root.appending(path: packageResolvedPath)), sdkVersion: sdkVersion)
  }

  /// Sources for `--at <ref>`. The rules themselves decide which repo files a claim needs, so a
  /// first pass over `claims` records every path they ask for, and only those are read from git.
  public static func atRef(
    _ ref: String, claims: [Claim], root: URL, layout: EvidenceLayout,
    packageResolvedPath: String, sdkVersion: String?, git: some Git
  ) async throws(LoadError) -> EvidenceFiles {
    let found: String?
    let prefix: String
    do throws(GitError) {
      found = try await git.revision(ref)
      prefix = try await git.workingDirectoryPrefix()
    } catch {
      throw .git(error)
    }
    guard let revision = found else { throw .refNotFound(ref) }
    let resolved: [String: String]
    do throws(GitError) {
      resolved = try await git.contents(of: [prefix + packageResolvedPath], at: revision)
    } catch {
      throw .git(error)
    }
    let packageResolved = resolved[prefix + packageResolvedPath].map { Data($0.utf8) }

    let recorder = RequestedPaths(
      base: EvidenceFiles(
        root: root, evidenceRoot: layout.root, filesAtRef: [:], packageResolved: packageResolved,
        sdkVersion: sdkVersion))
    _ = EvidenceCheck.check(claims, sources: recorder, mode: .atRef)
    let paths = recorder.paths.filter { !isUntrackedBuildPath($0) }.sorted()

    let contents: [String: String]
    do throws(GitError) {
      contents = try await git.contents(of: paths.map { prefix + $0 }, at: revision)
    } catch {
      throw .git(error)
    }
    var filesAtRef: [String: String] = [:]
    for path in paths {
      if let text = contents[prefix + path] { filesAtRef[path] = text }
    }
    return EvidenceFiles(
      root: root, evidenceRoot: layout.root, filesAtRef: filesAtRef,
      packageResolved: packageResolved, sdkVersion: sdkVersion)
  }

  /// Every claim in `claims.jsonl`, read from the working tree. A line that isn't a claim is an
  /// error naming it: dropping it would report a design as fully checked when it isn't.
  public static func claims(root: URL, layout: EvidenceLayout) throws(LoadError) -> [Claim] {
    let path = layout.claimsFile
    let url = root.appending(path: path)
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw .claimsFileMissing(path: path)
    }
    let data: Data
    do {
      data = try Data(contentsOf: url)
    } catch {
      throw .claimsFileUnreadable(path: path, detail: error.localizedDescription)
    }
    let decoder = JSONDecoder()
    var claims: [Claim] = []
    for (index, line) in data.split(
      separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false
    ).enumerated() where !line.isEmpty {
      guard let claim = try? decoder.decode(Claim.self, from: Data(line)) else {
        throw .malformedClaimLine(path: path, line: index + 1)
      }
      claims.append(claim)
    }
    return claims
  }

  /// The iOS simulator SDK version `xcrun` reports, or `nil` when it can't say; the rules then
  /// fail each claim that needs one with `sdkVersionUnavailable`.
  public static func currentSDKVersion(runner: any ProcessRunner) async -> String? {
    let output = try? await runner.run(
      ProcessInvocation(
        executable: "xcrun", arguments: ["--sdk", "iphonesimulator", "--show-sdk-version"],
        timeout: .seconds(30)))
    guard let output, output.status.isSuccess else { return nil }
    let version = output.stdout.text.trimmingCharacters(in: .whitespacesAndNewlines)
    return version.isEmpty ? nil : version
  }

  /// Any project's `.build`, at the root or nested, spelled in any letter case.
  private static func isUntrackedBuildPath(_ path: String) -> Bool {
    path.split(separator: "/").contains { $0.lowercased() == ".build" }
  }

  private static func read(_ url: URL) -> Data? {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
      !isDirectory.boolValue
    else { return nil }
    return try? Data(contentsOf: url)
  }
}

/// Answers like the sources it wraps, with every repo file absent, and remembers which repo paths
/// the rules asked for.
private final class RequestedPaths: EvidenceSources {
  let base: EvidenceFiles
  private(set) var paths: Set<String> = []

  init(base: EvidenceFiles) { self.base = base }

  func repoFile(_ path: String) -> String? {
    paths.insert(path)
    return nil
  }

  func evidenceFile(_ path: String) -> Data? { base.evidenceFile(path) }
  var packageResolved: Data? { base.packageResolved }
  var sdkVersion: String? { base.sdkVersion }
  /// No link stops a rule before it asks for the file, so every path a claim could need at the
  /// ref is recorded; the real check still judges links.
  func repoSymlink(_ path: String) -> String? { nil }
  func evidenceSymlink(_ path: String) -> String? { nil }
}
