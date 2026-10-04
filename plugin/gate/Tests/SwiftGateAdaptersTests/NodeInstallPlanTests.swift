import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

private func nodeArea(_ name: String, root: String) -> BrownfieldArea {
  BrownfieldArea(
    name: name, root: root, language: .typescript, kind: .node, test: "npm run test",
    testFiles: nil, lint: nil, build: nil, e2e: nil, testGlobs: [], packs: [], xcode: nil)
}

/// A tree holding each captured `NodeInstall/<fixture>/` file under the directory it maps to.
private func tree(_ placed: [String: String]) throws -> TrackedTreeSnapshot {
  var files: [String: Data] = [:]
  for (directory, fixture) in placed {
    let source = Fixture.directory.appending(
      path: "NodeInstall/\(fixture)", directoryHint: .isDirectory)
    for name in try FileManager.default.contentsOfDirectory(atPath: source.path) {
      let path = directory == "." ? name : "\(directory)/\(name)"
      files[path] = try Data(contentsOf: source.appending(path: name))
    }
  }
  return TrackedTreeSnapshot(files: files)
}

@Suite("which node installs a new brownfield worktree runs")
struct NodeInstallPlanTests {
  @Test(
    "the captured memos clone gets 1 frozen pnpm install in web for the web area, and none for its Go area — catches a node area's worktree created without an install, or a non-node area getting one"
  )
  func memosInstallsWebOnly() throws {
    let directory = Fixture.directory.appending(
      path: "Discover/usememos-memos", directoryHint: .isDirectory)
    let listing = try String(
      contentsOf: directory.appending(path: "ls-files.txt"), encoding: .utf8)
    let files = directory.appending(path: "tree", directoryHint: .isDirectory)
    let snapshot = TrackedTreeSnapshot(
      paths: listing.split(separator: "\n").map(String.init),
      read: { try? Data(contentsOf: files.appending(path: $0)) })
    let config = try TOMLConfigDecoder().decodeBrownfield(
      try Fixture.text("BrownfieldTrial/memos-4-config.toml"))
    #expect(config.areas.map(\.kind) == [.node, .go])

    let plan = NodeInstallPlan.plan(areas: config.areas, tree: snapshot)

    #expect(
      plan.installs == [
        NodeInstall(
          directory: "web", manager: .pnpm, lockfile: "web/pnpm-lock.yaml",
          arguments: ["install", "--frozen-lockfile", "--prefer-offline"], areas: ["web"],
          cachePathArguments: ["store", "path"])
      ])
    #expect(plan.installs.allSatisfy { !$0.areas.contains("memos") })
    #expect(plan.notes == [])
  }

  @Test(
    "each manager's captured lockfile picks that manager's frozen install, and a yarn 4 lockfile picks --immutable — catches npm install or a lockfile-rewriting install run where the lockfile names another manager"
  )
  func eachManagersFrozenInstall() throws {
    let expected: [(String, NodePackageManager, String, [String], [String])] = [
      (
        "pnpm", .pnpm, "pnpm-lock.yaml", ["install", "--frozen-lockfile", "--prefer-offline"],
        ["store", "path"]
      ),
      (
        "npm", .npm, "package-lock.json", ["ci", "--prefer-offline", "--no-audit", "--no-fund"],
        ["config", "get", "cache"]
      ),
      (
        "yarn", .yarn, "yarn.lock", ["install", "--frozen-lockfile", "--prefer-offline"],
        ["cache", "dir"]
      ),
      (
        "yarn-berry", .yarn, "yarn.lock", ["install", "--immutable"],
        ["config", "get", "cacheFolder"]
      ),
      ("bun", .bun, "bun.lock", ["install", "--frozen-lockfile"], ["pm", "cache"]),
    ]
    for (fixture, manager, lockfile, arguments, cachePath) in expected {
      let plan = NodeInstallPlan.plan(
        areas: [nodeArea("app", root: "apps/app")], tree: try tree(["apps/app": fixture]))
      #expect(
        plan.installs == [
          NodeInstall(
            directory: "apps/app", manager: manager, lockfile: "apps/app/\(lockfile)",
            arguments: arguments, areas: ["app"], cachePathArguments: cachePath)
        ], "\(fixture)")
    }
  }

  @Test(
    "2 workspace packages under 1 root lockfile share 1 install at the root — catches an install per package that races on the same node_modules"
  )
  func workspacePackagesShareTheRootInstall() throws {
    let plan = NodeInstallPlan.plan(
      areas: [nodeArea("a", root: "packages/a"), nodeArea("b", root: "./packages/b/")],
      tree: try tree([".": "pnpm"]))

    #expect(plan.installs.map(\.directory) == ["."])
    #expect(plan.installs.map(\.lockfile) == ["pnpm-lock.yaml"])
    #expect(plan.installs.map(\.areas) == [["a", "b"]])
  }

  @Test(
    "a node area with no lockfile at or above it gets no install and a note naming it — catches a frozen install that fails on every worktree, or an area dropped without a word"
  )
  func noLockfileIsANote() throws {
    let plan = NodeInstallPlan.plan(
      areas: [nodeArea("site", root: "site")],
      tree: TrackedTreeSnapshot(files: ["site/package.json": Data("{}".utf8)]))

    #expect(plan.installs == [])
    #expect(plan.notes.count == 1)
    #expect(plan.notes.first?.contains("site") == true, "\(plan.notes)")
    #expect(plan.notes.first?.contains("no lockfile") == true, "\(plan.notes)")
  }
}
